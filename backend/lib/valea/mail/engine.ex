defmodule Valea.Mail.Engine do
  @moduledoc """
  Per-ACCOUNT mail sync GenServer (mail-as-maildir design spec E, §Engine).
  One instance per valid account in `config/mail.yaml`, supervised by
  `Valea.Mail.Supervisor` and registered under `{:via, Registry,
  {Valea.Mail.Registry, slug}}` (the Registry itself lives at the app level —
  see `Valea.Application`). State: the account's `Valea.Mail.Settings.t()`
  (handed in at `start_link/1`, not re-read from `config/mail.yaml` by this
  module), credential (RAM only), sync status, poll timer.

  ## Activation gating

  Two ways an Engine comes to life: as one of `Valea.Mail.Supervisor`'s BOOT
  children (started as part of `Valea.Workspace.Runtime`, before the
  workspace's own `:workspace_opened` broadcast fires), or LATER via
  `Valea.Mail.Supervisor.reload_settings_all/1` rehashing a newly-valid
  account into existence mid-session, well after that broadcast already
  fired for every sibling engine. `init/1` handles both without ever
  branching on which one it is at the call site: it always subscribes to the
  `"workspace"` PubSub topic and builds an inert state (`active: false`);
  only a rehash-started Engine additionally carries `activate: true` in its
  start args, which schedules a `{:continue, :activate_now}` that runs the
  EXACT SAME activation path a boot-time Engine reaches via its own
  generation's `{:workspace_opened, info, generation}` broadcast. A
  broadcast for any other generation (a stale open, or a switch that landed
  before this Engine's own open finished) is ignored; a rolled-back open
  just kills the still-inert Engine along with the rest of that `Runtime`.

  ## Identity binding

  Activation calls `Valea.Mail.Account.verify/3` against `sources/mail/
  <slug>/.account` before anything else: `:absent` claims the slug
  (`write_if_absent!/3`) and proceeds; `{:error, :identity_mismatch}` — the
  slug's local subtree was provisioned against a DIFFERENT host/username —
  leaves the Engine inert (`active: false`, `state: "identity_mismatch"`),
  never running `Index.rebuild/2` or a sync pass, but still answering
  `status/1` so the RPC/cockpit surface can show the operator what's wrong.
  Resolving it is a purge (Task 10's `purge_mail_account_files`), not
  `readopt/1` — a mismatched identity is a different account entirely, not
  the SAME account's mailbox getting replaced (see below).

  ## Credential handling

  The credential is process memory only — never written to disk, never
  logged, never part of the workspace. It is held as a **zero-arity
  closure** (`fn -> secret end`) rather than the raw string: `inspect/1` on
  a function value never renders its closed-over environment, so an
  operator inspecting this process's state (`:sys.get_state/1`, a crash
  dump, an ad hoc inspect of `state` while debugging) cannot see the secret
  by accident. Callers that need the raw value call the closure, not
  pattern-match into state.

  Two ways a credential arrives: the `set_mail_credential` RPC (via
  `set_credential/2`) or — dev-only, browser-mode fallback documented in the
  design spec's §Credentials — `Valea.Mail.Settings.env_credential/1`
  (`VALEA_MAIL_PASSWORD_<SLUG>`), read once at activation and only if no
  credential has already been supplied.

  ## Sync passes

  A pass (`Valea.Mail.SyncPass.run/1`) runs in a monitored `Task`, triggered
  by the poll timer or `sync_now/1` (its only two triggers). At most one
  runs at a time: the in-flight task's `{pid, ref}` is tracked in
  `state.sync_task`, so a second `sync_now` (or a poll tick) while syncing is
  a no-op that leaves the running pass untouched. Status shows `"syncing"`
  for the duration; the task's result flips it back to `"idle"` (or
  `"auth_failed"`/`"mailbox_replaced"`) and broadcasts `mail_sync_finished`.
  The credential closure is handed to the task and only ever called inside
  `SyncPass` at the `transport.connect/3` boundary.

  ## RPC declared ops (`apply_ops`)

  `mail_apply_ops` (the Mail UI's archive/move/flag actions) runs the SAME
  `Valea.Mail.OpsExecutor` core as the ops-file push phase, but it must never
  execute concurrently with a sync pass (or another ops batch) — they mutate
  the same mailbox/ledger/manifests, and a concurrent `recover()` or a
  duplicate-copy on a non-UIDPLUS server would corrupt state. So an ops batch
  runs in its OWN monitored+linked `Task` (exactly like a sync pass), and is
  STRICTLY SERIALIZED against passes: `sync_task` and `ops_current` are two
  faces of the one "background work in flight" slot — `busy?/1` gates both.

  An `apply_ops` arriving while a pass (or an earlier ops batch) is in flight
  is QUEUED (`ops_queue`) rather than run inline; its `GenServer.reply` is
  DEFERRED until its own task finishes (so `handle_call` never blocks the
  Engine loop — `status/1`, `sync_now/1`, `set_credential/2` and the poll tick
  keep answering instantly). Conversely, a `sync_now`/poll tick arriving while
  an ops task runs is a no-op (`start_pass_unless_running/1` sees `busy?`), so
  no pass ever runs alongside an ops batch. In the normal case the queued
  reply still lands within the caller's 60s call timeout. The per-op results
  array is always returned (a connect/executor failure degrades to per-op
  rejections, keeping `mail_apply_ops`'s frozen shape populated).

  ## `mailbox_replaced` stickiness + `readopt`

  A pass reporting `{:error, :mailbox_replaced}` (`Valea.Mail.Reconcile.
  detect_replacement/2` decided this pass's resets amount to a whole-mailbox
  replacement, not ordinary per-folder resets) is STICKY: `state` stays
  `"mailbox_replaced"` and polling pauses (same posture as `auth_failed`)
  until `readopt/1` — which writes the one-shot `sources/mail/<slug>/
  .readopt` marker (`Valea.Mail.Account.authorize_readopt!/2`), flips status
  back to `"idle"`, and re-arms polling. The NEXT pass reads that marker,
  threads `readopt_authorized: true` into `SyncPass.run/1` (which skips
  `detect_replacement` for that one pass and reconciles every reset folder
  individually via `Reconcile.folder_reset/2`), and — only once that pass
  reports success — this Engine clears the marker. A forced SECOND
  replacement after that re-blocks normally: the marker is gone, so the next
  reset pass runs `detect_replacement` again.

  ## Errors

  A pass returning `{:error, :auth_failed}` pauses the poll timer (no retry
  storm against a bad password) until `set_credential/2` supplies a new one,
  which clears the failure and re-arms polling. `set_credential/2` itself
  never starts a pass directly — it only re-arms the timer, and the next
  tick runs one.
  """
  use GenServer

  alias Valea.Mail.Account
  alias Valea.Mail.Doctor
  alias Valea.Mail.Index
  alias Valea.Mail.OpsExecutor
  alias Valea.Mail.Redact
  alias Valea.Mail.Store
  alias Valea.Mail.SyncPass

  @default_interval_minutes 5

  @typedoc """
  `credential` is `"present"` or `"missing"`; `state` is one of `"inactive"`,
  `"idle"`, `"syncing"`, `"auth_failed"`, `"identity_mismatch"`,
  `"mailbox_replaced"` — plain `String.t()` below because Elixir/Dialyzer
  typespecs don't support singleton-string (as opposed to singleton-atom)
  literal types.
  """
  @type status :: %{
          account: String.t(),
          configured: boolean(),
          credential: String.t(),
          state: String.t(),
          last_sync_at: String.t() | nil,
          last_error: String.t() | nil,
          username: String.t() | nil,
          workspace_id: String.t() | nil,
          pending_ops: non_neg_integer(),
          held_folders: [String.t()],
          backfill: %{String.t() => boolean()} | nil,
          notices: [String.t()]
        }

  @doc "The `{:via, Registry, ...}` name a slug's Engine is registered under."
  @spec via(String.t()) :: {:via, Registry, {Valea.Mail.Registry, String.t()}}
  def via(slug) when is_binary(slug), do: {:via, Registry, {Valea.Mail.Registry, slug}}

  def start_link(%{account: slug} = cfg),
    do: GenServer.start_link(__MODULE__, cfg, name: via(slug))

  @doc "Current status for `slug`, or `nil` when no Engine is running for it."
  @spec status(String.t()) :: status() | nil
  def status(slug) do
    case whereis(slug) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Every currently-running Engine's status, keyed by account slug."
  @spec statuses() :: %{String.t() => status()}
  def statuses do
    slugs_and_pids()
    |> Map.new(fn {slug, pid} -> {slug, GenServer.call(pid, :status)} end)
  end

  @doc """
  Stores `secret` as `slug`'s credential (RAM only, never logged) and
  broadcasts the updated status. If the Engine had paused on `auth_failed`,
  this clears it and re-arms polling — the next poll tick runs a pass; this
  call never starts one itself. `{:error, :not_found}` when no Engine is
  running for `slug`.
  """
  @spec set_credential(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_credential(slug, secret) when is_binary(slug) and is_binary(secret) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:set_credential, secret})
    end
  end

  @doc """
  Triggers a sync pass immediately (in a monitored `Task`). Refuses when the
  Engine hasn't activated yet, has no usable settings, has no credential, or
  is sticky-blocked on a `mailbox_replaced` reset. A no-op `:ok` when a pass
  is already running (single-flight).
  """
  @spec sync_now(String.t()) ::
          :ok | {:error, :not_configured | :no_credential | :inactive | :not_found | :blocked}
  def sync_now(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :sync_now)
    end
  end

  @doc """
  Authorizes exactly one reconciliation pass past a sticky `mailbox_replaced`
  block (see the moduledoc): writes the one-shot `.readopt` marker, clears
  the sticky state, and re-arms polling. `{:error, :not_blocked}` when `slug`
  isn't currently blocked; `{:error, :not_found}` when no Engine is running
  for it.
  """
  @spec readopt(String.t()) :: :ok | {:error, :not_found | :not_blocked}
  def readopt(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :readopt)
    end
  end

  @doc """
  Runs the mail connection doctor (mail design spec, §Account setup +
  doctor) — `Valea.Mail.Doctor.run/1` against a snapshot of `slug`'s
  settings/credential/transport. Never errors on the doctor's own account:
  an inactive/unconfigured/uncredentialed Engine, an unreachable server, or
  a bad password are all *reported* as checks, not raised. `{:error,
  :not_found}` when no Engine is running for `slug`. The snapshot is
  fetched via a fast `GenServer.call` (mirroring `status/1`); the actual
  network probing that follows runs in the calling process, never inside
  the Engine's own loop.
  """
  @spec doctor(String.t()) ::
          {:ok, %{checks: [Doctor.check()], ok: boolean}} | {:error, :not_found}
  def doctor(slug) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> Doctor.run(GenServer.call(pid, :doctor_ctx))
    end
  end

  @doc """
  Connects and creates whichever of the AI/Review and AI/Processed folders
  are currently missing on `slug`'s server — the doctor panel's "Create AI
  folders" action. Guarded exactly like `sync_now/1`. Same non-blocking
  shape as `doctor/1`.
  """
  @spec create_folders(String.t()) ::
          {:ok, [String.t()]}
          | {:error, :inactive | :not_configured | :no_credential | :not_found | term()}
  def create_folders(slug) do
    case whereis(slug) do
      nil ->
        {:error, :not_found}

      pid ->
        case GenServer.call(pid, :doctor_ctx_gated) do
          {:ok, ctx} -> Doctor.create_folders(ctx)
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Executes RPC-originated declared ops (the Mail UI's archive/move/flag
  actions), serialized through this account's Engine (spec §RPC surface —
  `mail_apply_ops`). Runs in a monitored `Task`, STRICTLY serialized against
  sync passes and other ops batches (see the moduledoc, §RPC declared ops): it
  connects, reconciles any in-flight ops, runs the same `Valea.Mail.OpsExecutor`
  core as the ops-file push phase (origin `"rpc"`), and returns the per-op
  results array. From the caller's view this is synchronous — the reply is
  deferred until the task finishes, but blocks nothing in the Engine loop
  meanwhile. Gated exactly like `sync_now/1`. `{:error, reason}` when the
  account can't run; `{:error, :not_found}` when no Engine is running for
  `slug`.
  """
  @spec apply_ops(String.t(), [map()]) ::
          {:ok, [map()]}
          | {:error, :inactive | :not_configured | :no_credential | :blocked | :not_found}
  def apply_ops(slug, ops) when is_binary(slug) and is_list(ops) do
    case whereis(slug) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:apply_ops, ops}, 60_000)
    end
  end

  defp whereis(slug), do: GenServer.whereis(via(slug))

  defp slugs_and_pids do
    Registry.select(Valea.Mail.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(cfg) do
    # Trap exits so the sync task can be LINKED (not just monitored):
    # linking makes it die with this Engine when Runtime tears it down on a
    # workspace switch — a monitored-only task blocked in :ssl.recv would
    # otherwise outlive the Engine and write the old workspace's rows into the
    # new one. Trapping turns a linked task's crash into a handled `{:EXIT, _,
    # _}` message rather than killing the Engine; the paired monitor still
    # drives result/cleanup (see `handle_info` below).
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")

    state = %{
      root: cfg.root,
      generation: cfg.generation,
      account: cfg.account,
      settings: Map.get(cfg, :settings),
      transport: Application.get_env(:valea, :mail_transport, Valea.Mail.ImapClient),
      connect_opts: Map.get(cfg, :connect_opts, []),
      active: false,
      credential: nil,
      status: "inactive",
      last_sync_at: nil,
      last_error: nil,
      workspace_id: nil,
      poll_timer: nil,
      sync_task: nil,
      # RPC ops execution — the single in-flight ops Task (`%{task: {pid, ref},
      # from:, ops:}`) plus a FIFO queue of deferred `apply_ops` callers waiting
      # behind whatever background work (a pass or an earlier ops batch) is
      # currently running. See the moduledoc, §RPC declared ops.
      ops_current: nil,
      ops_queue: [],
      pass_readopt_authorized: false,
      notices: []
    }

    if Map.get(cfg, :activate, false) do
      {:ok, state, {:continue, :activate_now}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:activate_now, state), do: {:noreply, activate(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  # Internal — `Valea.Mail.Supervisor.reload_settings_all/1`'s own rehash
  # diff, not part of this module's public interface.
  def handle_call(:current_settings, _from, state), do: {:reply, state.settings, state}

  def handle_call({:set_credential, secret}, _from, state) do
    new_state =
      state
      |> Map.put(:credential, fn -> secret end)
      |> clear_auth_failed()

    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:sync_now, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, :ok, start_pass_unless_running(state)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # RPC declared ops — strictly serialized against sync passes and other ops
  # batches (moduledoc §RPC declared ops). Gated like `sync_now`; on a gate
  # failure it replies immediately. Otherwise the reply is DEFERRED: the batch
  # either starts its own Task now (if no background work is in flight) or is
  # QUEUED behind the running pass/ops task — never run inline in the Engine
  # loop, so `status`/`sync_now`/`:poll` stay responsive throughout.
  def handle_call({:apply_ops, ops}, from, state) do
    case validate_sync(state) do
      :ok ->
        if busy?(state) do
          {:noreply, %{state | ops_queue: state.ops_queue ++ [%{from: from, ops: ops}]}}
        else
          {:noreply, start_ops_task(state, from, ops)}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:readopt, _from, %{status: "mailbox_replaced"} = state) do
    :ok = Account.authorize_readopt!(state.root, state.account)
    new_state = %{state | status: "idle"} |> schedule_poll()
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:readopt, _from, state), do: {:reply, {:error, :not_blocked}, state}

  # Doctor never gates: it must report on exactly why an inactive/
  # unconfigured/uncredentialed Engine can't connect, not refuse to run.
  def handle_call(:doctor_ctx, _from, state), do: {:reply, doctor_ctx(state), state}

  # create_folders DOES gate, same as sync_now — it needs a real connection
  # to create anything.
  def handle_call(:doctor_ctx_gated, _from, state) do
    case validate_sync(state) do
      :ok -> {:reply, {:ok, doctor_ctx(state)}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:workspace_opened, _info, generation}, %{generation: generation} = state) do
    {:noreply, activate(state)}
  end

  def handle_info({:workspace_opened, _info, _other_generation}, state), do: {:noreply, state}

  # `auth_failed`/`mailbox_replaced` pause polling: no re-arm until
  # `set_credential/2`/`readopt/1` clears them (see moduledoc §Errors /
  # §mailbox_replaced stickiness).
  def handle_info(:poll, %{status: status} = state)
      when status in ["auth_failed", "mailbox_replaced"] do
    {:noreply, %{state | poll_timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state |> maybe_start_pass() |> schedule_poll()}

  # A pass Task reported its result: flush the pending :DOWN, apply it, then
  # start any ops batch that queued behind the pass.
  def handle_info({:sync_result, pid, result}, %{sync_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish_pass(result) |> drain_ops()}
  end

  # The pass Task crashed before reporting (SyncPass returns tuples, so this
  # is an unexpected raise/exit) — treat it as a failed pass, not a wedge.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{sync_task: {pid, ref}} = state) do
    {:noreply, state |> finish_pass({:error, {:sync_task_down, reason}}) |> drain_ops()}
  end

  # An ops Task reported its per-op results: flush the pending :DOWN, reply to
  # the deferred caller, then start the next queued batch (if any).
  def handle_info(
        {:ops_result, pid, results},
        %{ops_current: %{task: {pid, ref}, from: from}} = state
      ) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, {:ok, results})
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # The ops Task died before reporting (its own core rescues, so this is an
  # unexpected raise/exit or a teardown kill) — reply with per-op rejections so
  # the deferred caller never hangs, then drain the queue.
  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{ops_current: %{task: {pid, ref}, from: from, ops: ops}} = state
      ) do
    GenServer.reply(from, {:ok, reject_all_ops(ops, "execution_error")})
    {:noreply, %{state | ops_current: nil} |> drain_ops()}
  end

  # Stale task chatter (already handled/superseded): ignore.
  def handle_info({:sync_result, _pid, _result}, state), do: {:noreply, state}
  def handle_info({:ops_result, _pid, _results}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # A LINKED sync task exited (normal completion or crash). Because the
  # Engine traps exits, the exit signal arrives here as a message; the paired
  # monitor's `:DOWN` (matched above) is what actually drives result handling
  # and single-flight cleanup, so the `{:EXIT, _, _}` is intentionally a no-op.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # -- RPC ops execution --------------------------------------------------

  # True whenever ANY background work is in flight (a sync pass OR an ops
  # batch) — the single mutual-exclusion gate that keeps passes and ops from
  # ever running concurrently against the same mailbox/ledger.
  defp busy?(state), do: state.sync_task != nil or state.ops_current != nil

  # Starts one ops batch in a LINKED + monitored Task (same lifecycle as a sync
  # pass — see `spawn_linked_task/1`), pinning `{from, ops}` so the result
  # handler can reply to the deferred caller. The credential closure travels
  # into the Task and is only ever called there, at `connect/3`.
  defp start_ops_task(state, from, ops) do
    parent = self()

    args = %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      transport: state.transport,
      connect_opts: state.connect_opts,
      credential: state.credential
    }

    task =
      spawn_linked_task(fn -> send(parent, {:ops_result, self(), run_rpc_ops(args, ops)}) end)

    %{state | ops_current: %{task: task, from: from, ops: ops}}
  end

  # After a pass or an ops batch finishes: if nothing is in flight and callers
  # are queued, start the next one. Re-validates each queued caller at drain
  # time (the account may have become blocked meanwhile) — a caller that no
  # longer passes the gate is replied with the error and skipped.
  defp drain_ops(state) do
    cond do
      busy?(state) ->
        state

      state.ops_queue == [] ->
        state

      true ->
        [%{from: from, ops: ops} | rest] = state.ops_queue
        state = %{state | ops_queue: rest}

        case validate_sync(state) do
          :ok ->
            start_ops_task(state, from, ops)

          {:error, _reason} = error ->
            GenServer.reply(from, error)
            drain_ops(state)
        end
    end
  end

  # Connects, reconciles in-flight ops, then runs the executor's per-op core
  # against the RPC-supplied raw ops. Always returns a per-op results list;
  # a connect failure maps every op to a `connect_failed` rejection so the
  # RPC's frozen results-array shape stays populated. Runs INSIDE the ops Task,
  # never in the Engine loop.
  defp run_rpc_ops(args, ops) do
    case args.transport.connect(
           args.settings.imap,
           resolve_secret(args.credential),
           args.connect_opts
         ) do
      {:ok, conn} ->
        try do
          ctx = %{
            root: args.root,
            account: args.account,
            settings: args.settings,
            transport: args.transport,
            conn: conn
          }

          OpsExecutor.recover(ctx)
          OpsExecutor.apply_raw_ops(ctx, ops, "rpc")
        after
          safe_logout(args.transport, conn)
        end

      {:error, _reason} ->
        reject_all_ops(ops, "connect_failed")
    end
  rescue
    # An executor/transport failure must never crash the Task and hang the
    # deferred caller: degrade to per-op rejections so the RPC's frozen
    # results-array shape is always returned.
    _ -> reject_all_ops(ops, "execution_error")
  catch
    :exit, _ -> reject_all_ops(ops, "execution_error")
  end

  defp resolve_secret(fun) when is_function(fun, 0), do: fun.()
  defp resolve_secret(_credential), do: nil

  defp reject_all_ops(ops, reason) do
    ops
    |> Enum.with_index()
    |> Enum.map(fn {_op, index} ->
      %{"op" => index, "result" => "rejected", "reason" => reason}
    end)
  end

  defp safe_logout(transport, conn) do
    transport.logout(conn)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- activation ---------------------------------------------------------

  # Defensive: an Engine started with no settings at all (never constructed
  # by `Valea.Mail.Supervisor`, which only ever hands a real `Settings.t()`
  # to a valid account's child) still activates — poll timer armed, status
  # "idle" — since there's no identity to verify and no maildir to index;
  # it just has nothing to sync against, which `validate_sync/1`'s
  # `not_configured` gate reports.
  defp activate(%{settings: nil} = state) do
    new_state =
      %{state | active: true, status: "idle", workspace_id: load_workspace_id(state.root)}
      |> schedule_poll()

    broadcast_status(new_state)
    new_state
  end

  defp activate(state) do
    identity = %{host: state.settings.imap.host, username: state.settings.imap.username}

    case Account.verify(state.root, state.account, identity) do
      :absent ->
        :ok = Account.write_if_absent!(state.root, state.account, identity)
        do_activate(state)

      :ok ->
        do_activate(state)

      {:error, :identity_mismatch} ->
        new_state = %{
          state
          | active: false,
            status: "identity_mismatch",
            workspace_id: load_workspace_id(state.root)
        }

        broadcast_status(new_state)
        new_state
    end
  end

  defp do_activate(state) do
    {:ok, _count} = Index.rebuild(state.root, state.account)

    new_state =
      %{
        state
        | active: true,
          credential: state.credential || env_credential(state.account),
          status: "idle",
          workspace_id: load_workspace_id(state.root)
      }
      |> schedule_poll()

    broadcast_status(new_state)
    new_state
  end

  # Snapshot of exactly the fields `Valea.Mail.Doctor` needs — the same
  # settings/credential/transport a sync pass would use, plus the account
  # slug (Doctor's `maildir_writable` check needs it to build the probe
  # path). Built inside a fast `handle_call` so the slow network probing
  # that consumes it always runs outside the Engine's own loop.
  defp doctor_ctx(state) do
    %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      credential: state.credential,
      transport: state.transport
    }
  end

  # `config/workspace.yaml`'s persistent id (mail design spec, §Credentials —
  # keychain entries key on it). Read once, at activation, into state rather
  # than on every `status/1` call: `Scaffold.create/3` writes it once and it
  # stays stable across opens, so it never changes for the lifetime of an
  # activated Engine. `nil` on any absent/malformed file.
  defp load_workspace_id(root) do
    case YamlElixir.read_from_file(Path.join(root, "config/workspace.yaml")) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp env_credential(slug) do
    case Valea.Mail.Settings.env_credential(slug) do
      nil -> nil
      secret -> fn -> secret end
    end
  end

  # -- sync gating ----------------------------------------------------------

  defp validate_sync(%{active: false}), do: {:error, :inactive}
  defp validate_sync(%{settings: nil}), do: {:error, :not_configured}
  defp validate_sync(%{status: "mailbox_replaced"}), do: {:error, :blocked}
  defp validate_sync(%{credential: nil}), do: {:error, :no_credential}
  defp validate_sync(_state), do: :ok

  defp maybe_start_pass(state) do
    case validate_sync(state) do
      :ok -> start_pass_unless_running(state)
      {:error, _reason} -> state
    end
  end

  # Single-flight: only start a pass when NO background work is in flight —
  # neither another pass NOR an ops batch (they'd contend for the same
  # mailbox/ledger). A `sync_now`/poll landing while an ops task runs is a
  # no-op, exactly like a second `sync_now` during a pass.
  defp start_pass_unless_running(state) do
    if busy?(state), do: state, else: start_pass(state)
  end

  # Runs `SyncPass.run/1` in a LINKED + monitored process. The link ties the
  # task's lifetime to the Engine's: a Runtime teardown on a workspace switch
  # kills the Engine, which kills this task, so a pass blocked in :ssl.recv
  # can never survive to write the old workspace's data into the new one. The
  # Engine traps exits, so the task crashing is a handled message, not a
  # take-down; the monitor still delivers the result/`:DOWN` used for
  # single-flight tracking. The credential closure travels into the task and
  # is only ever called inside `SyncPass`, at the `connect/3` boundary.
  #
  # `readopt_authorized` is read fresh (the `.readopt` marker's presence)
  # right before the pass starts and pinned into `state.pass_readopt_authorized`
  # for `finish_pass/2` to consult — see moduledoc §mailbox_replaced.
  defp start_pass(state) do
    readopt_authorized = Account.readopt_authorized?(state.root, state.account)
    broadcast_event({:mail_sync_started, state.account})

    parent = self()

    args = %{
      root: state.root,
      account: state.account,
      settings: state.settings,
      credential: state.credential,
      transport: state.transport,
      connect_opts: state.connect_opts,
      readopt_authorized: readopt_authorized
    }

    task = spawn_linked_task(fn -> send(parent, {:sync_result, self(), SyncPass.run(args)}) end)

    new_state = %{
      state
      | sync_task: task,
        status: "syncing",
        pass_readopt_authorized: readopt_authorized
    }

    broadcast_status(new_state)
    new_state
  end

  # Links first (so a task that dies before/at monitor time delivers its exit
  # to the trapping Engine, not a raise), then monitors — the `{pid, ref}`
  # pair the existing single-flight/`:DOWN` handling keys on.
  defp spawn_linked_task(fun) do
    pid = spawn_link(fun)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp finish_pass(state, {:ok, result}) do
    new_messages = Map.get(result, :new_messages, 0)
    errors = Map.get(result, :errors, [])
    notices = Map.get(result, :notices, [])

    # The marker's job was to authorize exactly ONE successful pass past the
    # sticky block — clear it now that this pass reported success. A pass
    # that DIDN'T carry the authorization leaves nothing to clear.
    if state.pass_readopt_authorized, do: Account.clear_readopt!(state.root, state.account)

    broadcast_event(
      {:mail_sync_finished, state.account, %{new_messages: new_messages, errors: errors}}
    )

    %{
      state
      | sync_task: nil,
        status: "idle",
        last_sync_at: now_iso(),
        last_error: nil,
        pass_readopt_authorized: false,
        notices: notices
    }
    |> tap_broadcast_status()
  end

  defp finish_pass(state, {:error, :auth_failed}) do
    cancel_timer(state.poll_timer)

    broadcast_event(
      {:mail_sync_finished, state.account, %{new_messages: 0, errors: ["authentication failed"]}}
    )

    %{
      state
      | sync_task: nil,
        status: "auth_failed",
        poll_timer: nil,
        last_error: "authentication failed",
        pass_readopt_authorized: false
    }
    |> tap_broadcast_status()
  end

  defp finish_pass(state, {:error, :mailbox_replaced}) do
    cancel_timer(state.poll_timer)

    message =
      "the server's mailbox no longer matches local history — readopt or purge to continue"

    broadcast_event({:mail_sync_finished, state.account, %{new_messages: 0, errors: [message]}})

    %{
      state
      | sync_task: nil,
        status: "mailbox_replaced",
        poll_timer: nil,
        last_error: message,
        pass_readopt_authorized: false
    }
    |> tap_broadcast_status()
  end

  # `reason` is a connect failure or a `{:sync_task_down, _}` crash reason.
  # It is broadcast in `mail_sync_finished` AND stored as `last_error` (pushed
  # to the UI in every mail_status), so the credential must never survive into
  # it. `Redact.text/2` scrubs the secret (and its inspect-escaped form) out of
  # the built string as defense-in-depth behind the literal-LOGIN fix.
  defp finish_pass(state, {:error, reason}) do
    message = Redact.text("sync failed: #{inspect(reason)}", current_secret(state))
    broadcast_event({:mail_sync_finished, state.account, %{new_messages: 0, errors: [message]}})

    %{
      state
      | sync_task: nil,
        status: "idle",
        last_error: message,
        pass_readopt_authorized: false
    }
    |> tap_broadcast_status()
  end

  # The raw secret, materialized only here (it already lives in this process's
  # state) and only to scrub it back out of an error string — never stored,
  # never returned.
  defp current_secret(%{credential: fun}) when is_function(fun, 0), do: fun.()
  defp current_secret(_state), do: nil

  defp tap_broadcast_status(state) do
    broadcast_status(state)
    state
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp clear_auth_failed(%{status: "auth_failed"} = state) do
    state |> Map.put(:status, "idle") |> schedule_poll()
  end

  defp clear_auth_failed(state), do: state

  # -- poll timer -----------------------------------------------------------

  defp schedule_poll(state) do
    cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, interval_minutes(state) * 60_000)
    %{state | poll_timer: timer}
  end

  defp interval_minutes(%{settings: %{sync: %{interval_minutes: minutes}}}), do: minutes
  defp interval_minutes(_state), do: @default_interval_minutes

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # -- status -----------------------------------------------------------

  defp build_status(%{settings: nil} = state) do
    %{
      account: state.account,
      configured: false,
      credential: if(state.credential, do: "present", else: "missing"),
      state: state.status,
      last_sync_at: state.last_sync_at,
      last_error: state.last_error,
      username: nil,
      workspace_id: state.workspace_id,
      pending_ops: 0,
      held_folders: [],
      backfill: nil,
      notices: state.notices
    }
  end

  defp build_status(state) do
    %{pending_ops: pending_ops, held_folders: held_folders, backfill: backfill} =
      store_snapshot(state.account)

    %{
      account: state.account,
      configured: true,
      credential: if(state.credential, do: "present", else: "missing"),
      state: state.status,
      last_sync_at: state.last_sync_at,
      last_error: state.last_error,
      # The IMAP login, distinct from `account` (the slug) — surfaced for
      # display and the setup form; the frontend's OS-keychain entries are
      # keyed `workspace_id` / `<slug>:imap` (spec §Credentials), not on
      # this value.
      username: state.settings.imap.username,
      workspace_id: state.workspace_id,
      pending_ops: pending_ops,
      held_folders: held_folders,
      backfill: backfill,
      notices: state.notices
    }
  end

  # `status/1` must NEVER crash this GenServer, whatever state `Valea.Repo`
  # is in — a `handle_call` that raises takes the WHOLE Engine down (and
  # with it, e.g., an in-RAM credential nothing else holds a copy of), not
  # just this one call. The Repo is not a `Valea.Workspace.Runtime` child
  # (see `Valea.Cockpit`'s moduledoc for the exact close-ordering race), so
  # a `status/1` call landing in that narrow window must degrade to empty/
  # zero rather than propagate the failure.
  defp store_snapshot(account) do
    folders = Store.folders(account)

    %{
      pending_ops: account |> Store.pending_ops() |> length(),
      held_folders: folders |> Enum.filter(& &1.held) |> Enum.map(& &1.folder),
      backfill: Map.new(folders, &{&1.folder, &1.backfill_complete})
    }
  rescue
    _ -> %{pending_ops: 0, held_folders: [], backfill: %{}}
  catch
    :exit, _ -> %{pending_ops: 0, held_folders: [], backfill: %{}}
  end

  defp broadcast_status(state) do
    broadcast_event({:mail_status_changed, state.account, build_status(state)})
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mail", event)
  end
end
