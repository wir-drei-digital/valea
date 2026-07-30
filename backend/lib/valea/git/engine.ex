defmodule Valea.Git.Engine do
  @moduledoc """
  One per open workspace: keeps every git-backed ICM in step with its remote,
  and — this is the whole design — knows when to STOP.

  ## Held means held

  A repo whose local and remote histories have both moved (`diverged`), whose
  fast-forward is blocked by uncommitted edits (`blocked_local`), or that was
  left mid-merge or mid-rebase (`merge_in_progress`) is HELD: the pass reads
  its state locally and does nothing else. No fetch, no commit, no push — not
  even the "harmless" ones. A fetch cannot lose data, but a status row that
  keeps changing under a user who is trying to reason about a conflict can,
  and the moment Valea is allowed one network call on a held repo the next
  reader of this file has to argue about which one. So: held repos get local
  reads only, until a human (or a resolution session, `conflict_handoff/1`)
  converges them.

  Every held state is derived by `local_class/4` from ONE local read — the
  same function `conflict_handoff/1` re-derives with, fed the same inputs, so
  the pass and the handoff can never disagree about whether a repo is in
  conflict.

  `blocked_local` is the exception git has no marker for, and it is LEARNED
  rather than guessed: only a `merge --ff-only` that git actually refused
  enters it. It is deliberately not inferred from "behind and dirty", because
  most dirt blocks nothing — an untracked editor file, an edit to a file the
  incoming commit never touches — and git fast-forwards straight past it. A
  repo held on that guess would be held forever: held repos never fetch, so
  `behind` could never fall and the remote's work would never arrive.

  The hold then lasts exactly as long as the TREE GIT JUDGED. A refused
  fast-forward leaves the working tree byte-identical, so the fingerprint taken
  at refusal (the set of changed paths plus both shas — local reads only)
  describes the very thing git ruled on, and `local_class/4` holds while it
  matches: no network, no re-asking a question already answered. The moment the
  tree changes — the blocking file reverted, another added or removed, a commit
  made — the verdict has expired and the repo converges, where git decides
  again: a tree that still clobbers is refused again and re-learns the hold
  (one fetch, one refused fast-forward, both data-safe), and resolved dirt
  fast-forwards. So "the user cleaned up the file that was in the way" is a
  real exit even when unrelated dirt is left behind.

  `blocked_local` exists in `pull` mode only. In `full` mode the answer to a
  dirty tree is to commit it, which converts the situation into a divergence:
  held, self-limiting, and with the user's work preserved as a commit instead
  of sitting uncommitted behind a hold that would suspend full mode's whole
  contract.

  Valea's four sanctioned mutations live in `Valea.Git.Repo` and are the only
  ones reachable from here: `commit_all`, `fetch`, `ff_merge`, `push`. There is
  no non-ff merge, no rebase, no force-push, and no `reset --hard` — Valea
  never invents or rewrites history, and never discards a change it did not
  make.

  ## Passes

  Everything happens in a PASS: iterate the eligible ICM mounts, derive one
  `status()` row each, replace the map, broadcast. A pass runs in a single
  linked + monitored task (the mail Engine's pattern) so a git call wedged on
  a credential prompt can never block this loop, and so a Runtime teardown on
  a workspace switch takes the pass down with it rather than letting it write
  the old workspace's repos afterwards. A trigger that lands while a pass is
  running sets `pending_sync` and gets its own pass when that one finishes —
  never two at once over the same working trees.

  Passes are triggered by: activation, the poll timer, `sync_now/1`,
  `{:mounts_changed}` (eligibility or mode may have changed), and — in `full`
  mode only — a debounced `{:icm_changed}`, which is what turns "the user
  stopped typing" into a commit. That last one flushes through a LOCAL probe
  (`committable_work?/1`): a fetch writes `.git/FETCH_HEAD`, which the ICM
  watcher reports as a change under the ICM, so a flush that started a pass
  unconditionally would make the Engine trigger itself every debounce window
  forever.

  ## Activation gating

  Inert until `{:workspace_opened, _, generation}` matches the generation this
  Engine was started with, exactly like `Valea.Mail.Engine`. A Runtime for the
  previous workspace that is still shutting down therefore cannot be woken by
  the NEW workspace's open, and `{:workspace_closed}` cancels every timer and
  forgets every status — an Engine with no workspace has nothing true to say.

  ## Backoff

  A failed fetch (or push) sets `retry_at = now + min(60s * 2^(n-1), 30min)`
  for that repo alone. While that window is open, poll- and event-driven
  passes keep reporting the previous error and skip the network — a remote
  that is down must not be dialled every poll from every ICM. `sync_now/1`
  CLEARS the entry: an explicit request from a human is exactly the signal
  that the situation may have changed, and it is the only thing that overrides
  a backoff.

  ## Seams

    * `:git_cli` — the Cli module, pinned at `init/1` (default
      `Valea.Git.Cli`);
    * `:git_poll_interval_ms` (default 300_000) and `:git_poll_jitter`
      (ms, or `:random`, capped at 60s);
    * `:git_commit_quiet_ms` (default 120_000) — the `{:icm_changed}`
      debounce;
    * `:git_sync_probe` — a pid that receives `{:git_pass_finished, statuses}`
      after every pass (tests).
  """

  use GenServer

  require Logger

  alias Valea.Agents.SessionServer
  alias Valea.Git.Briefing
  alias Valea.Git.Repo
  alias Valea.Mounts

  @default_interval_ms 300_000
  @max_jitter_ms 60_000
  @commit_quiet_default_ms 120_000
  @backoff_base_ms 60_000
  @backoff_cap_ms 1_800_000
  # The states a resolution session can be handed off from — and the only ones
  # that carry a `conflict_session_id`.
  @conflict_states ~w(diverged blocked_local merge_in_progress)
  @subject_cap 10
  @changed_file_cap 20
  # Wider than the briefing's list: this one is a fingerprint, and a tree whose
  # 21st changed path is the one that stopped clobbering must still register as
  # a different tree.
  @fingerprint_file_cap 200
  @error_cap 2_000

  @type status :: %{
          mount_key: String.t(),
          icm_name: String.t(),
          mode: String.t(),
          state: String.t(),
          reason: String.t() | nil,
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          dirty: boolean(),
          # The pair that gives a notice its identity: `{mount_key, local_sha,
          # remote_sha}` is what tells "the same conflict, still there" from "a
          # new one" for a consumer that has already shown this row once. `nil`
          # wherever git could not answer (no upstream, unborn HEAD, a repo
          # never read because its mode is `off`).
          local_sha: String.t() | nil,
          remote_sha: String.t() | nil,
          last_sync_at: String.t() | nil,
          last_error: String.t() | nil,
          conflict_session_id: String.t() | nil,
          # INTERNAL bookkeeping, not part of what a UI should render: the
          # working tree git refused to fast-forward over, so `local_class/4`
          # can tell "the same obstruction" from "a different one". Travels on
          # the row because the row is what a pass hands the next pass as
          # `previous`. Consumers ignore it.
          block_fingerprint: integer() | nil
        }

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  @doc """
  Every git-backed ICM's current row, keyed by mount key. `%{}` when no
  Engine is running or it has not been activated — a caller asking about git
  in a workspace that has none gets an empty answer, never an error.
  """
  @spec statuses() :: %{String.t() => status()}
  def statuses do
    case Process.whereis(__MODULE__) do
      nil -> %{}
      pid -> GenServer.call(pid, :statuses)
    end
  catch
    :exit, _reason -> %{}
  end

  @doc """
  Runs a pass now for `mount_key`'s workspace, clearing that repo's backoff
  first — the one way past a retry window. Returns as soon as the pass is
  started or queued; the result arrives as a `"git"` broadcast.
  """
  @spec sync_now(String.t()) :: :ok | {:error, :not_found | :not_running}
  def sync_now(mount_key) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:sync_now, mount_key})
    end
  end

  @doc """
  The briefing for a resolution session over `mount_key`, plus the id of any
  session already recorded for it.

  Re-derives the repo's state LIVE rather than trusting the status row: the
  row can be minutes old, and a repo that has since converged must not get a
  session telling an agent to resolve a conflict that no longer exists
  (`{:error, :no_conflict}`, with the row refreshed on the way out).
  """
  @spec conflict_handoff(String.t()) ::
          {:ok,
           %{briefing: String.t(), existing_session_id: String.t() | nil, icm_name: String.t()}}
          | {:error, :no_conflict | :not_found | :not_running}
  def conflict_handoff(mount_key) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:conflict_handoff, mount_key}, 30_000)
    end
  end

  @doc """
  Remembers which session is working on `mount_key`'s conflict, so a second
  "resolve" click joins that session instead of starting a rival one. A cast:
  the caller has already started the session, and this must not be able to
  fail it.
  """
  @spec record_conflict_session(String.t(), String.t()) :: :ok
  def record_conflict_session(mount_key, session_id),
    do: GenServer.cast(__MODULE__, {:record_conflict_session, mount_key, session_id})

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(cfg) do
    # Trap exits so the pass task can be LINKED as well as monitored: the link
    # is what guarantees a wedged pass dies with this Engine on a workspace
    # switch, and trapping is what keeps a crashing pass a handled message
    # rather than a take-down. Same rationale as `Valea.Mail.Engine`.
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    Phoenix.PubSub.subscribe(Valea.PubSub, "mounts")

    state = %{
      root: cfg.root,
      generation: cfg.generation,
      # Pinned once: an in-flight pass must not have the git runner swapped
      # under it mid-repo.
      cli: Application.get_env(:valea, :git_cli, Valea.Git.Cli),
      active: false,
      repos: %{},
      retry: %{},
      # Mount keys a `sync_now/1` has demanded and no pass has served yet —
      # consumed by the next pass to start (see `handle_call({:sync_now, _})`).
      forced: MapSet.new(),
      poll_timer: nil,
      commit_timer: nil,
      sync_task: nil,
      pending_sync: false
    }

    if Map.get(cfg, :activate, false),
      do: {:ok, state, {:continue, :activate_now}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:activate_now, state), do: {:noreply, activate(state)}

  @impl true
  def handle_call(:statuses, _from, state), do: {:reply, state.repos, state}

  def handle_call({:sync_now, _key}, _from, %{active: false} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call({:sync_now, key}, _from, state) do
    if Enum.any?(eligible_mounts(state.root), &(&1.name == key)) do
      # Both halves matter. Dropping the retry entry is the override for the
      # pass that starts right now; the `forced` mark is the override for the
      # one that starts LATER — a `sync_now` landing mid-pass would otherwise
      # have its cleared entry overwritten by the retry map the in-flight pass
      # returns, and the user's explicit request would silently do nothing.
      new_state =
        %{state | retry: Map.delete(state.retry, key), forced: MapSet.put(state.forced, key)}
        |> start_pass_unless_busy()

      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  # Answered in the LOOP, not the pass task: these are local reads (a status,
  # two logs) over a repo that is by definition held, so there is nothing for
  # them to race with, and the caller wants the answer now.
  def handle_call({:conflict_handoff, key}, _from, state) do
    case Map.get(state.repos, key) do
      %{state: s} = row when s in @conflict_states -> handoff(state, row)
      nil -> {:reply, {:error, :not_found}, state}
      _not_conflicted -> {:reply, {:error, :no_conflict}, state}
    end
  end

  @impl true
  def handle_cast({:record_conflict_session, key, session_id}, state) do
    case Map.get(state.repos, key) do
      nil ->
        {:noreply, state}

      row ->
        repos = Map.put(state.repos, key, %{row | conflict_session_id: session_id})
        broadcast(repos)
        {:noreply, %{state | repos: repos}}
    end
  end

  @impl true
  def handle_info({:workspace_opened, _info, generation}, %{generation: generation} = state) do
    {:noreply, activate(state)}
  end

  def handle_info({:workspace_opened, _info, _other_generation}, state), do: {:noreply, state}

  def handle_info({:workspace_closed}, state), do: {:noreply, deactivate(state)}

  def handle_info(:poll, %{active: false} = state), do: {:noreply, %{state | poll_timer: nil}}

  def handle_info(:poll, state),
    do: {:noreply, state |> start_pass_unless_busy() |> schedule_poll()}

  # Every write under every ICM lands here. Only `full` mode has anything to
  # do with one, and only after the writing has STOPPED — otherwise a session
  # editing a page would commit it a dozen times mid-thought.
  def handle_info({:icm_changed}, state), do: {:noreply, arm_commit_timer(state)}

  # The debounce fires — but a flush only becomes a PASS if there is actually
  # something local to commit. Without that check the Engine feeds itself
  # forever: a pass fetches, the fetch rewrites `.git/FETCH_HEAD`, the ICM
  # watcher sees a write under the ICM and broadcasts `{:icm_changed}`, that
  # re-arms this timer, and the flush starts another pass with another fetch —
  # a permanent every-two-minutes network loop on a repo nobody touched. The
  # probe is LOCAL ONLY (`Repo.read_state/2`, no network), which is what makes
  # it safe to run here rather than in a pass.
  def handle_info(:commit_flush, state) do
    state = %{state | commit_timer: nil}

    if committable_work?(state),
      do: {:noreply, start_pass_unless_busy(state)},
      else: {:noreply, state}
  end

  # A mount was added/removed/enabled, or its sync mode changed: the set of
  # rows this Engine owns may be different now.
  def handle_info({:mounts_changed}, state), do: {:noreply, start_pass_unless_busy(state)}

  def handle_info({:git_pass_result, pid, result}, %{sync_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_pass(state, result)}
  end

  # The pass task died before reporting. Its work is idempotent and the last
  # statuses are still the best thing we know, so this keeps them and lets the
  # next trigger try again — a crashed pass must not blank the UI.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{sync_task: {pid, ref}} = state) do
    Logger.warning("git sync pass crashed: #{inspect(reason)}")
    {:noreply, %{state | sync_task: nil} |> drain_pending()}
  end

  # The linked task's ordinary exit — the monitor above is what this Engine
  # actually keys on, so the `{:EXIT, _, _}` is deliberately a no-op.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  # -- activation --------------------------------------------------------------

  defp activate(%{active: true} = state), do: state

  defp activate(state) do
    %{state | active: true} |> start_pass_unless_busy() |> schedule_poll()
  end

  # Forgets every row: the workspace they described is gone, and a stale row
  # is worse than no row. An in-flight pass is left to finish and discarded by
  # `finish_pass/2`'s inactive clause.
  defp deactivate(state) do
    cancel_timer(state.poll_timer)
    cancel_timer(state.commit_timer)

    %{
      state
      | active: false,
        repos: %{},
        retry: %{},
        forced: MapSet.new(),
        poll_timer: nil,
        commit_timer: nil,
        pending_sync: false
    }
  end

  # -- pass lifecycle ----------------------------------------------------------

  defp start_pass_unless_busy(%{active: false} = state), do: state
  defp start_pass_unless_busy(%{sync_task: nil} = state), do: start_pass(state)
  defp start_pass_unless_busy(state), do: %{state | pending_sync: true}

  defp start_pass(state) do
    parent = self()

    args = %{
      root: state.root,
      cli: state.cli,
      previous: state.repos,
      retry: state.retry,
      forced: state.forced
    }

    task = spawn_linked_task(fn -> send(parent, {:git_pass_result, self(), run_pass(args)}) end)

    %{state | sync_task: task, pending_sync: false, forced: MapSet.new()}
  end

  # Links first (so a task that dies before the monitor is set delivers its
  # exit to the trapping Engine rather than raising), then monitors.
  defp spawn_linked_task(fun) do
    pid = spawn_link(fun)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  # A pass that finished after the workspace closed is DISCARDED: it describes
  # repos this Engine no longer speaks for.
  defp finish_pass(%{active: false} = state, _result),
    do: %{state | sync_task: nil, pending_sync: false}

  defp finish_pass(state, {statuses, retry}) do
    statuses =
      statuses
      |> restore_recorded_sessions(state.repos)
      |> forget_dead_sessions()

    broadcast(statuses)
    probe(statuses)

    %{state | repos: statuses, retry: retry, sync_task: nil}
    |> drain_pending()
  end

  defp drain_pending(%{pending_sync: true} = state), do: start_pass(state)
  defp drain_pending(state), do: state

  # A `record_conflict_session/2` cast can land WHILE a pass is running, and
  # the pass's snapshot was taken before it — storing that snapshot verbatim
  # would drop the id, the row's button would revert to "resolve", and the next
  # click would start a RIVAL session against the same working tree. For a row
  # that is still conflict-class, the server's own view therefore wins over the
  # task's.
  defp restore_recorded_sessions(statuses, previous) do
    Map.new(statuses, fn
      {key, %{state: state, conflict_session_id: nil} = row} when state in @conflict_states ->
        case previous do
          %{^key => %{conflict_session_id: id}} when is_binary(id) ->
            {key, %{row | conflict_session_id: id}}

          _none_recorded ->
            {key, row}
        end

      {key, row} ->
        {key, row}
    end)
  end

  # A recorded session that is no longer running is a dead reference: the row
  # must offer "resolve" again rather than "open the session that fixed this".
  # `attach/1` is the liveness question the rest of the app asks, and it is
  # asked HERE, in the loop, because it is a call into another GenServer.
  defp forget_dead_sessions(statuses) do
    Map.new(statuses, fn
      {key, %{conflict_session_id: id} = row} when is_binary(id) ->
        if session_running?(id), do: {key, row}, else: {key, %{row | conflict_session_id: nil}}

      {key, row} ->
        {key, row}
    end)
  end

  defp session_running?(id) do
    match?({:ok, _reply}, SessionServer.attach(id))
  catch
    :exit, _reason -> false
  end

  # -- the pass itself (runs in the task) --------------------------------------

  defp run_pass(%{root: ws, cli: cli, previous: previous, retry: retry, forced: forced}) do
    now = System.monotonic_time(:millisecond)

    {statuses, retry} =
      ws
      |> eligible_mounts()
      |> Enum.reduce({%{}, retry}, fn mount, {acc, retry} ->
        key = mount.name
        previous_row = Map.get(previous, key)
        gate = if MapSet.member?(forced, key), do: nil, else: Map.get(retry, key)

        case sync_repo(mount, ws, cli, previous_row, gate, now) do
          {nil, _entry} -> {acc, Map.delete(retry, key)}
          {row, nil} -> {Map.put(acc, key, row), Map.delete(retry, key)}
          {row, entry} -> {Map.put(acc, key, row), Map.put(retry, key, entry)}
        end
      end)

    # A repo with no row (unmounted, disabled, no longer a repo) keeps no
    # backoff either — its next appearance starts clean.
    {statuses, Map.take(retry, Map.keys(statuses))}
  end

  # ICM mounts only, and only the ones this workspace actually composes: a
  # disabled or degraded mount is not something Valea should be committing to.
  defp eligible_mounts(ws) do
    ws
    |> Mounts.list()
    |> Enum.filter(&(&1.kind == :icm and &1.enabled and &1.degraded == nil))
  end

  defp sync_repo(mount, ws, cli, previous, retry_entry, now) do
    cfg = Mounts.git_config(ws, mount.name)
    base = base_row(mount, cfg, previous)

    case Repo.detect(mount.root) do
      :repo ->
        repo_pass(mount.root, base, previous, cfg, cli, retry_entry, now)

      {:unsupported, reason} ->
        {%{base | state: "unsupported", reason: reason}, nil}

      :none ->
        # A plain folder is the ordinary case and gets no row at all. But a
        # mount someone deliberately configured for git sync and that has no
        # repo needs to SAY so, or the setting silently does nothing forever.
        if configured_for_git?(cfg),
          do: {%{base | state: "unsupported", reason: "no git repository"}, nil},
          else: {nil, nil}
    end
  end

  # `Valea.Mounts.git_config/2` cannot distinguish an absent block from one
  # that spells out the default, so "configured" means "says something other
  # than the default" — the only reading available without a second config
  # reader, and the one that matches intent: a user who wrote `sync: full` or
  # left instructions meant something by it.
  defp configured_for_git?(%{sync: sync, instructions: instructions}),
    do: sync != :pull or instructions != nil

  defp base_row(mount, cfg, previous) do
    %{
      mount_key: mount.name,
      icm_name: icm_name(mount),
      mode: Atom.to_string(cfg.sync),
      state: "ok",
      reason: nil,
      branch: nil,
      ahead: 0,
      behind: 0,
      dirty: false,
      local_sha: nil,
      remote_sha: nil,
      # Carried: `last_sync_at` means "when this repo was last CONVERGED",
      # which a failed or held pass does not change.
      last_sync_at: previous && previous.last_sync_at,
      last_error: nil,
      conflict_session_id: previous && previous.conflict_session_id,
      # Deliberately NOT carried: a verdict about a working tree is only worth
      # keeping where it is re-affirmed (`classify/8`'s `blocked_local` branch,
      # `fast_forward/5`'s refusal). Any other outcome drops it, so a repo that
      # left the state re-learns it from git rather than from memory.
      block_fingerprint: nil
    }
  end

  defp icm_name(%{manifest: %{name: name}}) when is_binary(name), do: name
  defp icm_name(mount), do: mount.name

  defp repo_pass(_root, base, _previous, %{sync: :off}, _cli, _retry, _now),
    do: {finalize(%{base | state: "off"}), nil}

  defp repo_pass(root, base, previous, cfg, cli, retry_entry, now) do
    case Repo.read_state(root, cli) do
      {:ok, st} -> classify(root, base, previous, cfg, cli, retry_entry, now, st)
      {:error, reason} -> {error_row(base, reason), retry_entry}
    end
  end

  # Everything `local_class/4` can name is HELD or observe-only, and every one
  # of those carries `retry_entry` through untouched: only an actual network
  # attempt is allowed to move the backoff ledger, in either direction. `"ok"`
  # is the ONLY answer that earns a fetch.
  defp classify(root, base, previous, cfg, cli, retry_entry, now, st) do
    # Only a repo already holding at `blocked_local` has a verdict to re-check,
    # so that is the only one that pays for the extra local read.
    fingerprint =
      if previous && previous.state == "blocked_local", do: tree_fingerprint(root, st, cli)

    case local_class(st, cfg.sync, previous, fingerprint) do
      "ok" ->
        converge(root, base, previous, cfg, cli, retry_entry, now, st)

      "blocked_local" ->
        # Still the same obstruction git refused: keep both the fingerprint that
        # says so and the refusal text that explains it to the user.
        row = %{
          observed(base, st, "blocked_local")
          | block_fingerprint: fingerprint,
            last_error: previous.last_error
        }

        {row, retry_entry}

      held ->
        {observed(base, st, held), retry_entry}
    end
  end

  # What a repo IS, from a purely LOCAL read — the single classifier behind both
  # the pass and `conflict_handoff/1`. They MUST agree: a row the pass calls
  # `detached` that the handoff would call `merge_in_progress` is a conflict no
  # button can open, so the two derivations are one function rather than two
  # `cond`s that drifted.
  #
  # An unfinished merge/rebase comes FIRST, because a conflicted rebase also has
  # a detached HEAD — classified on `branch` first, every rebase-in-progress
  # would read `detached`, which is not conflict-class, and the resolution
  # session could never be handed off.
  defp local_class(st, mode, previous, fingerprint) do
    cond do
      st.in_progress != nil or st.conflicted -> "merge_in_progress"
      st.branch == nil -> "detached"
      st.upstream == nil -> "no_upstream"
      st.ahead > 0 and st.behind > 0 -> "diverged"
      still_blocked?(st, mode, previous, fingerprint) -> "blocked_local"
      true -> "ok"
    end
  end

  # `blocked_local` is the one state git has no marker for, so it is LEARNED —
  # from a `merge --ff-only` git actually refused (`fast_forward/5`) — and only
  # then held here. It is deliberately NOT inferred from "behind with a dirty
  # tree": most dirt blocks nothing (an untracked `.DS_Store`, an edit to a file
  # the incoming commit never touches), git fast-forwards straight past it, and
  # a repo held on that guess would be held FOREVER — held repos do not fetch,
  # so `behind` could never fall back to zero and the remote's work would never
  # arrive.
  #
  # The hold therefore lasts exactly as long as the TREE GIT JUDGED. A refused
  # fast-forward leaves the working tree byte-identical, so the fingerprint
  # taken at refusal describes the very thing git ruled on; while it matches,
  # re-asking would get the same answer and the repo stays held with no network
  # at all. The moment it changes — the blocking file reverted, another added or
  # removed, a commit made — the verdict has expired: the repo converges, and
  # git, not this function, decides again. A tree that still clobbers is simply
  # refused again and re-learns the hold (one fetch and one refused ff, both
  # data-safe); resolved dirt fast-forwards. This is what makes "the dirt
  # stopped clobbering" a real exit rather than a claim.
  #
  # Never in `full` mode: there the answer to a dirty tree is to COMMIT it (see
  # `maybe_commit/5`), which turns the situation into a divergence — held, and
  # with the user's work preserved as a commit rather than sitting uncommitted
  # behind a hold that suspends full mode's entire contract.
  defp still_blocked?(_st, :full, _previous, _fingerprint), do: false

  # The head-match is the whole rule: the row must ALREADY be `blocked_local`
  # (the verdict was learned, never guessed) and the tree must still fingerprint
  # to what git refused (`fingerprint` appears twice, so it must be equal).
  defp still_blocked?(
         st,
         _mode,
         %{state: "blocked_local", block_fingerprint: fingerprint},
         fingerprint
       )
       when fingerprint != nil,
       do: st.behind > 0 and st.dirty

  defp still_blocked?(_st, _mode, _previous, _fingerprint), do: false

  # What the working tree looked like when git refused to fast-forward over it.
  # Local reads only.
  #
  # Path-level, not content-level, and that is a decision rather than an
  # economy: the question this answers is "is this a DIFFERENT obstruction?".
  # Re-testing on every keystroke inside the blocking file would put a fetch and
  # a merge back under the very editor (or resolution session) the hold exists
  # to protect, and would ask git the same question it just answered. Reverting
  # the file, adding or removing one, or committing (which moves `local_sha`)
  # all change this; typing more into the same file does not.
  defp tree_fingerprint(root, st, cli) do
    paths = root |> Repo.changed_files(@fingerprint_file_cap, cli) |> Enum.sort()
    :erlang.phash2({paths, st.local_sha, st.remote_sha})
  end

  # Not held: commit what the user wrote (full mode only), then talk to the
  # remote — unless a backoff window says the remote is not answering.
  defp converge(root, base, previous, cfg, cli, retry_entry, now, st) do
    case maybe_commit(root, base, cfg, cli, st) do
      {:ok, base} -> fetch_phase(root, base, previous, cfg, cli, retry_entry, now, st)
      {:error, row} -> {row, retry_entry}
    end
  end

  defp maybe_commit(root, base, %{sync: :full}, cli, %{dirty: true} = st) do
    message =
      "valea sync: " <>
        (DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())

    case Repo.commit_all(root, message, cli) do
      :ok -> {:ok, base}
      {:error, {:commit_failed, out}} -> {:error, errored(base, st, out)}
    end
  end

  defp maybe_commit(_root, base, _cfg, _cli, _st), do: {:ok, base}

  defp fetch_phase(root, base, previous, cfg, cli, retry_entry, now, st) do
    if gated?(retry_entry, now) do
      # The remote is still in its penalty box: report what it reported last
      # time, over freshly-read local facts, and touch no network.
      {%{observed(base, st, "error") | last_error: previous && previous.last_error}, retry_entry}
    else
      case Repo.fetch(root, cli) do
        :ok -> after_fetch(root, base, cfg, cli, st)
        {:error, {:fetch_failed, out}} -> {errored(base, st, out), bump(retry_entry, now)}
      end
    end
  end

  defp after_fetch(root, base, cfg, cli, before) do
    case Repo.read_state(root, cli) do
      {:error, reason} ->
        {errored(base, before, reason), nil}

      {:ok, st} ->
        cond do
          st.ahead > 0 and st.behind > 0 -> {observed(base, st, "diverged"), nil}
          st.behind > 0 and st.ahead == 0 -> fast_forward(root, base, cli, st, cfg.sync)
          st.ahead > 0 and cfg.sync == :full -> push(root, base, cli, st)
          true -> {succeeded(base, st), nil}
        end
    end
  end

  # The ONLY place `blocked_local` is entered: git looked at this exact working
  # tree and refused to fast-forward over it. Everything else is `local_class/3`
  # holding that verdict until the tree stops blocking.
  defp fast_forward(root, base, cli, st, mode) do
    case Repo.ff_merge(root, cli) do
      :ok ->
        {succeeded(base, refresh(root, cli, st)), nil}

      {:error, {:ff_failed, out}} ->
        st = refresh(root, cli, st)

        cond do
          st.ahead > 0 and st.behind > 0 ->
            {observed(base, st, "diverged"), nil}

          # `full` mode has no `blocked_local`: it commits dirty trees, so a
          # refusal here is not "the user has uncommitted work" but something
          # `git add -A` could not take (an ignored file the merge would
          # clobber, a permissions problem). That is an error, and it says so
          # in git's own words rather than borrowing a state whose remedy —
          # "commit or revert your edits" — does not apply.
          mode == :full ->
            {errored(base, st, out), nil}

          true ->
            # The remote moved and something local is in the way — the working
            # tree is left EXACTLY as it was, which is the point, and which is
            # also what makes the fingerprint taken here describe the very tree
            # git just ruled on.
            row = %{
              observed(base, st, "blocked_local")
              | last_error: describe(out),
                block_fingerprint: tree_fingerprint(root, st, cli)
            }

            {row, nil}
        end
    end
  end

  defp push(root, base, cli, st) do
    case Repo.push(root, cli) do
      :ok ->
        {succeeded(base, refresh(root, cli, st)), nil}

      {:error, {:push_rejected, out}} ->
        # Someone pushed between this pass's fetch and its push. Re-fetch so
        # the row tells the truth about what that was; it is almost always a
        # divergence, and if it somehow isn't, the rejection is still an error
        # the user should see rather than an "ok".
        Repo.fetch(root, cli)
        st = refresh(root, cli, st)

        if st.ahead > 0 and st.behind > 0,
          do: {observed(base, st, "diverged"), nil},
          else: {%{observed(base, st, "error") | last_error: describe(out)}, nil}

      {:error, {:push_failed, out}} ->
        {errored(base, st, out), nil}
    end
  end

  # A second read after a mutation, so the row reports what the repo IS rather
  # than what it was before the merge/push. A read that fails leaves the
  # pre-mutation facts standing — stale beats invented.
  defp refresh(root, cli, fallback) do
    case Repo.read_state(root, cli) do
      {:ok, st} -> st
      {:error, _reason} -> fallback
    end
  end

  # -- rows --------------------------------------------------------------------

  defp observed(base, st, state) do
    finalize(%{
      base
      | state: state,
        branch: st.branch,
        ahead: st.ahead,
        behind: st.behind,
        dirty: st.dirty,
        local_sha: st.local_sha,
        remote_sha: st.remote_sha
    })
  end

  defp succeeded(base, st) do
    %{observed(base, st, "ok") | last_sync_at: now_iso()}
  end

  # An error is a thing that happened TO a repo, not a replacement for knowing
  # anything about it: wherever the state read succeeded, the row keeps the
  # branch, the counts, the dirty flag and the shas it just observed. Only a
  # failure to read the repo AT ALL (`error_row/2`) leaves them blank, because
  # then there is nothing true to put there.
  defp errored(base, st, message),
    do: %{observed(base, st, "error") | last_error: describe(message)}

  defp error_row(base, message), do: %{base | state: "error", last_error: describe(message)}

  # Only a conflict-class row carries a session reference; converging clears
  # it, which is what makes the button go back to "sync" on its own.
  defp finalize(%{state: state} = row) when state in @conflict_states, do: row
  defp finalize(%{state: "ok"} = row), do: %{row | conflict_session_id: nil}
  defp finalize(row), do: row

  # Capped because a status row is BROADCAST on every pass: `Valea.Git.Cli`
  # admits up to 256 KB of git output, and a push failing against a chatty
  # server should not put that on the wire (or in a tooltip) every five
  # minutes. `String.slice/3` counts graphemes, so it cannot sever a
  # multi-byte character the way a `binary_part/3` would.
  defp describe(message) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @error_cap)
    end
  end

  defp describe(reason), do: inspect(reason)

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # -- backoff -----------------------------------------------------------------

  defp gated?(nil, _now), do: false
  defp gated?(%{retry_at: retry_at}, now), do: retry_at > now

  defp bump(entry, now) do
    attempts = (entry && entry.attempts + 1) || 1
    delay = min(@backoff_base_ms * Integer.pow(2, min(attempts - 1, 16)), @backoff_cap_ms)
    %{attempts: attempts, retry_at: now + delay}
  end

  # -- conflict handoff --------------------------------------------------------

  defp handoff(state, row) do
    case Enum.find(eligible_mounts(state.root), &(&1.name == row.mount_key)) do
      nil -> {:reply, {:error, :not_found}, state}
      mount -> handoff_from(state, row, mount)
    end
  end

  defp handoff_from(state, row, mount) do
    cfg = Mounts.git_config(state.root, mount.name)

    case Repo.read_state(mount.root, state.cli) do
      {:error, reason} ->
        {:reply, {:error, :no_conflict}, put_row(state, error_row(row, reason))}

      {:ok, st} ->
        # The SAME classifier the pass uses, fed the SAME inputs — the row is
        # exactly what a pass would have seen as `previous`, so a repo holding
        # at `blocked_local` re-derives as `blocked_local` here rather than as
        # `ok`, and a row that says `merge_in_progress` can never meet a handoff
        # that disagrees. A tree that has changed since the refusal re-derives
        # as whatever it now IS, which is the point of asking live.
        fingerprint =
          if row.state == "blocked_local", do: tree_fingerprint(mount.root, st, state.cli)

        live = local_class(st, cfg.sync, row, fingerprint)

        if live in @conflict_states do
          {:reply, {:ok, brief(mount, row, cfg, st, live, state.cli)}, state}
        else
          {:reply, {:error, :no_conflict}, put_row(state, observed(row, st, live))}
        end
    end
  end

  defp brief(mount, row, cfg, st, live, cli) do
    details = %{
      icm_name: row.icm_name,
      branch: st.branch,
      mode: Atom.to_string(cfg.sync),
      state: live,
      ahead: st.ahead,
      behind: st.behind,
      local_subjects: Repo.log_subjects(mount.root, "@{u}..HEAD", @subject_cap, cli),
      remote_subjects: Repo.log_subjects(mount.root, "HEAD..@{u}", @subject_cap, cli),
      files: Repo.changed_files(mount.root, @changed_file_cap, cli)
    }

    %{
      briefing: Briefing.compose(details, cfg.instructions),
      existing_session_id: row.conflict_session_id,
      icm_name: row.icm_name
    }
  end

  defp put_row(state, row), do: %{state | repos: Map.put(state.repos, row.mount_key, row)}

  # -- timers ------------------------------------------------------------------

  defp schedule_poll(state) do
    cancel_timer(state.poll_timer)
    %{state | poll_timer: Process.send_after(self(), :poll, poll_delay_ms())}
  end

  defp poll_delay_ms do
    interval = Application.get_env(:valea, :git_poll_interval_ms, @default_interval_ms)
    interval + poll_jitter_ms(interval)
  end

  # Jitter for the same reason the mail Engine has it: every workspace's
  # Engines start within milliseconds of each other, and a bare interval would
  # have them all reach for the network at the same instant forever.
  defp poll_jitter_ms(interval) do
    case Application.get_env(:valea, :git_poll_jitter, :random) do
      fixed when is_integer(fixed) -> fixed
      _random -> :rand.uniform(min(@max_jitter_ms, div(interval, 4)) + 1) - 1
    end
  end

  # Only `full` mode has a commit to debounce, and only for a repo this Engine
  # has actually seen — before the first pass there is nothing to know that
  # from, and an fs event is not worth a config read.
  defp arm_commit_timer(%{active: false} = state), do: state

  defp arm_commit_timer(state) do
    if Enum.any?(state.repos, fn {_key, row} -> row.mode == "full" end) do
      cancel_timer(state.commit_timer)
      %{state | commit_timer: Process.send_after(self(), :commit_flush, commit_quiet_ms())}
    else
      state
    end
  end

  defp commit_quiet_ms,
    do: Application.get_env(:valea, :git_commit_quiet_ms, @commit_quiet_default_ms)

  # Is there a `full`-mode repo with uncommitted work that a pass could
  # actually commit? Local reads only. A HELD repo answers no: its dirty tree
  # is exactly what a resolution session is working on, and a pass would only
  # re-report the same hold.
  defp committable_work?(state) do
    state.root
    |> eligible_mounts()
    |> Enum.any?(fn mount ->
      Mounts.git_config(state.root, mount.name).sync == :full and
        Repo.detect(mount.root) == :repo and
        dirty_and_free?(mount.root, state.cli)
    end)
  end

  # Only reached for a `full`-mode mount, so the mode is known. A behind + dirty
  # repo answers YES here — that is exactly the commit the user is waiting for —
  # and the loop still terminates: the pass commits, which makes the repo
  # diverged, which is held, which is no longer `"ok"`; and the tree is clean
  # afterwards either way.
  defp dirty_and_free?(root, cli) do
    case Repo.read_state(root, cli) do
      {:ok, %{dirty: true} = st} -> local_class(st, :full, nil, nil) == "ok"
      _clean_or_unreadable -> false
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # -- fan-out -----------------------------------------------------------------

  defp broadcast(statuses),
    do: Phoenix.PubSub.broadcast(Valea.PubSub, "git", {:git_status_changed, statuses})

  defp probe(statuses) do
    case Application.get_env(:valea, :git_sync_probe) do
      pid when is_pid(pid) -> send(pid, {:git_pass_finished, statuses})
      _absent -> :ok
    end
  end
end
