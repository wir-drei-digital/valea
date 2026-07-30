defmodule Valea.Schedules.Runner do
  @moduledoc """
  What a fire actually DOES — the seam between `Valea.Schedules.Scheduler`
  (which decides *whether* and *when*) and the two payload kinds (which decide
  *how*). `Valea.Schedules.Runner.Live` is the production implementation; the
  determinism suite substitutes a fake, which is the whole reason this
  boundary exists: the scheduler's rules (anchors, coalescing, tombstones,
  catch-up, the kill switch) are testable without starting a single agent
  session or subprocess.

  Three callbacks, and the third is the interesting one.

  `start_prompt/3` and `start_command/4` launch and return a handle
  (`session_id` / the run process's pid). Neither *waits*: a prompt fire is a
  normal session that outlives the tick, and a command fire is a supervised
  process that reports back with `{:run_finished, run_id, outcome,
  duration_ms, output}`.

  `live?/4` answers "is a run of this schedule still going?" — the spec's
  one-run-at-a-time rule — and it is deliberately **derived, never process
  state the scheduler keeps**. The scheduler holds no run table: after a
  restart, a workspace switch, or a crashed session, an in-memory flag would
  be a lie that suppresses every future fire of that schedule. `Live` derives
  it from the `Valea.Schedules.RunRegistry` (commands) and the session Registry
  (prompts, via the last run record's `session_id`), so the answer is always a
  fresh observation of the world.

  `meta` carries everything a launch needs that isn't in the entry:

      %{
        icm_id:, icm_name:, mount_key:,          # who
        schedule_id:, fingerprint:,              # which definition
        slot:, trigger:, coalesced_count:,       # which fire
        run_id:, generation:, workspace_root:    # where to report back
      }

  `run_id` is present because the run record is written BEFORE the spawn (so a
  crash in the spawn window still leaves evidence), and a command run needs it
  to report its own completion. `workspace_root` spares the runner a
  `Valea.Workspace.Manager` round-trip on the launch path — the scheduler
  already holds the root it was started with, generation-bound.
  """

  alias Valea.Schedules.Entry

  @doc "Starts a scheduled agent session; returns its session id."
  @callback start_prompt(mount :: map(), entry :: Entry.t(), meta :: map()) ::
              {:ok, session_id :: String.t()} | {:error, term()}

  @doc """
  Starts a supervised command run owned by `owner` (the scheduler), which will
  receive `{:run_finished, run_id, outcome, duration_ms, output}`.
  """
  @callback start_command(
              mount :: map(),
              entry :: Entry.t(),
              meta :: map(),
              owner :: pid()
            ) :: {:ok, pid()} | {:error, term()}

  @doc """
  Whether a run of `(icm_id, schedule_id)` is still live. `last_run` is the
  newest run record (or `nil`), passed in so an implementation need not query
  the store itself.
  """
  @callback live?(
              icm_id :: String.t(),
              schedule_id :: String.t(),
              kind :: :prompt | :command,
              last_run :: map() | nil
            ) :: boolean()
end

defmodule Valea.Schedules.Runner.Live do
  @moduledoc """
  The production runner: prompt fires become ordinary `"scheduled"` agent
  sessions, command fires become supervised `Valea.Schedules.CommandRun`
  processes.

  ## Prompt fires

  Exactly the flow `Valea.Api.Agents`' `create_session` follows — generate the
  id, resolve the scope with that id, start the session with it — because the
  scope's `managed_context` path is keyed to the session id and the two must
  not disagree. `kind: "scheduled"` is the only difference from a human
  session, and it is metadata: **posture is identical**. A scheduled session
  gets no extra grants, no weakened permission policy, and no bypass; a write
  it cannot do unattended parks on the same ask a human session would get
  (spec §Consent & containment — self-perpetuation fails closed).

  The initial prompt is a fixed preamble plus the schedule's prompt verbatim.
  The preamble exists so the session knows it has nobody to ask: it names the
  schedule and tells the agent to record blockers in `tasks.json` and end
  rather than sit on a question no human will see.

  `context_doc` is the entry's ICM-relative path lifted into a stable
  `Valea.Icm.Locator` (`icm_id` + path — the ICM's own identity, not the mount
  key, so a rename doesn't break it) and pre-flighted through
  `Valea.Agents.resolve_context_doc/2`. A context doc that names nothing fails
  the fire (`{:error, :context_doc_unavailable}` → a `failed` run record)
  rather than starting a session that silently lacks the document its prompt
  assumes.

  ## Command fires

  `Valea.Schedules.CommandRun` under `Valea.Schedules.RunSupervisor`, keyed in
  `Valea.Schedules.RunRegistry` by `{icm_id, schedule_id}` — which is what
  makes "one run at a time" observable rather than remembered
  (`{:error, :already_running}` if the key is taken, though the scheduler's
  own `live?/4` check normally gets there first).
  """
  @behaviour Valea.Schedules.Runner

  alias Valea.Agents.SessionScope
  alias Valea.Schedules.CommandRun
  alias Valea.Schedules.RunRegistry
  alias Valea.Schedules.RunSupervisor

  # How long the scope resolution may take before the fire is treated as a
  # spawn failure. Generous for the work involved (two Manager calls plus a
  # mount listing), short enough that a workspace close is never held up.
  @scope_timeout_ms 2_000

  @impl true
  def start_prompt(_mount, entry, meta) do
    id = Valea.Agents.generate_session_id()
    workspace = meta.workspace_root

    with {:ok, context_doc} <- context_doc(entry, meta, workspace),
         {:ok, scope} <- resolve_scope(meta, id),
         {:ok, %{id: id}} <-
           Valea.Agents.start_session(%{
             id: id,
             kind: "scheduled",
             title: title(entry, meta),
             scope: scope,
             run: nil,
             initial_prompt: initial_prompt(entry, meta),
             on_turn_end: nil,
             context_doc: context_doc,
             input: nil,
             include_mounts: []
           }) do
      {:ok, id}
    end
  end

  # `SessionScope.resolve/1` calls `Valea.Workspace.Manager` twice
  # (`check_generation`, `current`) on its default 5 s leash — and this runs
  # INSIDE the scheduler process, which is a Runtime child, so a close landing
  # here meets the deadlock the scheduler's own 500 ms leash exists to break
  # (Manager waits on the Runtime, the Runtime waits on the scheduler, the
  # scheduler waits on the Manager). Running it in a Task bounds the wait
  # without touching shared code: a timeout becomes an ordinary spawn failure,
  # so the fire lands as a `failed` run record with the reason in `output` and
  # the next slot is the retry.
  #
  # `Task.yield/2` reports a crashed task as `{:exit, reason}` rather than
  # taking the scheduler down with it (the scheduler traps exits, and its
  # catch-all `handle_info/2` drops the stray `{:EXIT, …}`).
  defp resolve_scope(meta, session_id) do
    task =
      Task.async(fn ->
        SessionScope.resolve(%{
          kind: "scheduled",
          mount_key: meta.mount_key,
          generation: meta.generation,
          session_id: session_id,
          read_paths: [],
          include_mounts: []
        })
      end)

    case Task.yield(task, @scope_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:scope_failed, reason}}
      nil -> {:error, :scope_timeout}
    end
  end

  @impl true
  def start_command(mount, entry, meta, owner) when is_pid(owner) do
    case DynamicSupervisor.start_child(
           RunSupervisor,
           {CommandRun, %{mount: mount, entry: entry, meta: meta, owner: owner}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_running}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def live?(icm_id, schedule_id, :command, _last_run) do
    Registry.lookup(RunRegistry, {icm_id, schedule_id}) != []
  rescue
    # No Registry (mid-close, or a runner used outside the supervision tree):
    # "not live" is the honest answer — the run cannot be reached either.
    _error -> false
  catch
    :exit, _reason -> false
  end

  # Off the session Registry (`Valea.Agents.list_running_session_inputs/0`),
  # liveness-filtered, NOT `list_sessions/0`: the latter asks
  # `Valea.Workspace.Manager` which workspace is current, and a Runtime child
  # calling into the Manager can meet its own shutdown coming the other way
  # (see `Valea.Workspace.Manager.check_generation/2`). The Registry answers the
  # sharper question anyway — "is that session's process alive right now" — and a
  # session parked on a permission ask IS alive, which is exactly right: the
  # schedule must not fire over it.
  @impl true
  def live?(_icm_id, _schedule_id, :prompt, %{outcome: "running", session_id: session_id})
      when is_binary(session_id) do
    Enum.any?(Valea.Agents.list_running_session_inputs(), fn {id, _input} -> id == session_id end)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  @impl true
  def live?(_icm_id, _schedule_id, :prompt, _no_running_run), do: false

  # -- prompt composition ------------------------------------------------------

  @doc """
  The composed initial prompt for a scheduled session: the fixed preamble, a
  blank line, then the schedule's own prompt **verbatim**.

  Public and pure so it can be pinned by a test that reads like the spec
  paragraph it implements. It used to be private, and the sigil that built it
  was silently broken: a `~s(…)` closes at the first unescaped `)`, which the
  preamble itself contains (it wraps the schedule id in parentheses), so the
  remainder of the line parsed as `binary in binary` and EVERY prompt fire died
  with a `Protocol.UndefinedError`, recorded as a `failed` run with the
  protocol error in `output`. Plain double-quoted concatenation, no sigil: this
  string contains both parentheses and quotes, and the only formatting worth
  having here is the kind that cannot swallow them.
  """
  @spec initial_prompt(Entry.t(), map()) :: String.t()
  def initial_prompt(entry, meta), do: preamble(entry, meta) <> "\n\n" <> entry.payload.prompt

  @doc """
  The preamble, verbatim from the spec (§Run lifecycle & workspace switch →
  Prompt fires):

  > Scheduled run "<title>" (<schedule_id>) in <icm_name>. You are running
  > unattended; if you get blocked, record what's needed in tasks.json and end
  > the session.

  It exists because a scheduled session has nobody to ask: it names the
  schedule and its ICM, and tells the agent to record blockers in `tasks.json`
  and end rather than sit on a question no human will read. Changing a word
  changes what every scheduled session is told about its own situation.
  """
  @spec preamble(Entry.t(), map()) :: String.t()
  def preamble(entry, meta) do
    "Scheduled run \"#{entry.title}\" (#{meta.schedule_id}) in #{meta.icm_name}. " <>
      "You are running unattended; if you get blocked, record what's needed in " <>
      "tasks.json and end the session."
  end

  # `<schedule title> — <date>`, the date being the slot's WALL-CLOCK date in
  # the schedule's own zone: a 23:30 Zurich slot belongs to the evening the
  # user scheduled, not to the UTC day it happens to land in.
  defp title(entry, meta) do
    date =
      case DateTime.shift_zone(meta.slot, entry.timezone || "Etc/UTC") do
        {:ok, local} -> DateTime.to_date(local)
        {:error, _unknown_zone} -> DateTime.to_date(meta.slot)
      end

    "#{entry.title} — #{Date.to_iso8601(date)}"
  end

  defp context_doc(%{payload: %{context_doc: nil}}, _meta, _workspace), do: {:ok, nil}

  defp context_doc(%{payload: %{context_doc: path}}, meta, workspace) when is_binary(path) do
    Valea.Agents.resolve_context_doc(
      %{"kind" => "icm", "icm_id" => meta.icm_id, "path" => path},
      workspace
    )
  end

  defp context_doc(_entry_without_context_doc, _meta, _workspace), do: {:ok, nil}
end
