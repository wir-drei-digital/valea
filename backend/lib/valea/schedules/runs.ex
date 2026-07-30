defmodule Valea.Schedules.Runs do
  @moduledoc """
  The READ side of run history: `Valea.Schedules.Store` rows shaped for the UI,
  with the `waiting` outcome derived by a **join against live session state**.

  ## `waiting` is a projection, never a stored outcome

  A scheduled prompt session that parks on a permission ask is still a
  perfectly healthy run: its row stays `"running"` in the store and its session
  process stays alive. The spec wants that surfaced (`waiting for approval` in
  the cockpit and on the row) — but writing `"waiting"` into the store would
  break two exact-equality contracts at once:

    * `Valea.Schedules.Store.running_runs/1` matches the literal `"running"`,
      and it is what enforces one-run-at-a-time AND what converges abandoned
      rows to `interrupted`. A row relabelled `"waiting"` would be invisible to
      both — the schedule would fire a second concurrent session at the next
      slot, and the parked row would never converge.
    * `notices_since/1` matches `"waiting"`/`"failed"` by exact equality, so a
      persisted `"waiting"` would also become a permanent notice for a run that
      has long since been approved.

  So the outcome is computed at read time, here, from the session's live
  timeline — and `Valea.Schedules.Scheduler` keeps writing only the tokens it
  can defend. `Store.notices_since/1`'s `waiting:` bucket is consequently
  always empty in production; `waiting_since/1` below is the cockpit's actual
  source, and the two are deliberately not the same thing.

  ## Cost

  The join only ever runs for rows recorded `"running"` with `kind: "prompt"`
  and a `session_id` — at most one per schedule by construction — and it is one
  `SessionServer.attach/1` call apiece (a live-process question; an ended
  session answers `:not_running` without touching the filesystem). Nothing here
  reads a transcript.
  """

  alias Valea.Agents.SessionServer
  alias Valea.Schedules.Store

  @running "running"
  @waiting "waiting"
  @prompt "prompt"

  @doc """
  Up to `limit` run rows for `(icm_id, schedule_id)`, newest first, as
  string-keyed JSON-ready maps with the outcome PROJECTED (see the moduledoc).

  `output` rides along verbatim: it is already capped at 256 KiB by the writer
  (`Valea.Schedules.CommandRun`'s containment contract), and the run history is
  the one surface where the human is asking to see it. Nothing else in the RPC
  surface carries output — cockpit notices deliberately do not.
  """
  @spec history(String.t(), String.t(), pos_integer()) :: [map()]
  def history(icm_id, schedule_id, limit) do
    icm_id |> Store.runs(schedule_id, limit) |> Enum.map(&payload/1)
  end

  @doc """
  The newest run's projected outcome for `(icm_id, schedule_id)`, or `nil` when
  the schedule has never run in this workspace.

  "Newest" is the newest EVENT, which may be a `"skipped: still running"`
  record rather than a run — that is the honest last outcome, and the reason
  `Store.runs/3` orders by `fired_at`.
  """
  @spec last_outcome(String.t(), String.t()) :: String.t() | nil
  def last_outcome(icm_id, schedule_id) do
    case Store.runs(icm_id, schedule_id, 1) do
      [run] -> projected_outcome(run)
      [] -> nil
    end
  end

  @doc """
  Every run parked on a permission ask with `fired_at >= since` — the cockpit's
  `waiting` notices, newest first.

  Derived from `Store.running_runs/1` (the "newest RUNNING-shaped row" query,
  which a newer skip record cannot hide) narrowed to prompt fires, then joined
  against live session state. Returns the raw `Store` maps (atom keys), for a
  caller that is about to shape its own notice payload.
  """
  @spec waiting_since(DateTime.t()) :: [map()]
  def waiting_since(%DateTime{} = since) do
    Store.running_runs()
    |> Enum.filter(fn run ->
      run.kind == @prompt and
        DateTime.compare(run.fired_at, DateTime.truncate(since, :second)) != :lt and
        awaiting_approval?(run.session_id)
    end)
  end

  @doc """
  The outcome to SHOW for a run row: `"waiting"` for a prompt fire still
  recorded `"running"` whose session is parked on an unresolved ask, otherwise
  the stored outcome verbatim.

  A row whose session is simply gone keeps `"running"`: this read side does not
  invent an ending it cannot verify — marking abandoned rows `interrupted` is
  the scheduler's per-mount convergence pass, which knows whether the runner
  still considers the run live.
  """
  @spec projected_outcome(map()) :: String.t() | nil
  def projected_outcome(%{outcome: @running, kind: @prompt, session_id: session_id} = run) do
    if awaiting_approval?(session_id), do: @waiting, else: run.outcome
  end

  def projected_outcome(run), do: run.outcome

  # A live session holding at least one unresolved permission item. Anything
  # else — no session id, an ended session, a Registry mid-close, a session
  # server that dies or times out while answering — is "not waiting": a notice
  # must never be the thing that crashes (or hangs) a cockpit read, and "no
  # notice" is the honest answer when the session cannot be asked.
  defp awaiting_approval?(session_id) when is_binary(session_id) do
    case SessionServer.attach(session_id) do
      {:ok, %{items: items}} -> Enum.any?(items, &unresolved_ask?/1)
      {:error, :not_running} -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp awaiting_approval?(_missing), do: false

  defp unresolved_ask?(%{"type" => "permission"} = item), do: item["resolved"] != true
  defp unresolved_ask?(_other_item), do: false

  defp payload(run) do
    %{
      "id" => run.id,
      "slot" => iso(run.slot),
      "fired_at" => iso(run.fired_at),
      "trigger" => run.trigger,
      "kind" => run.kind,
      "outcome" => projected_outcome(run),
      "duration_ms" => run.duration_ms,
      "session_id" => run.session_id,
      "output" => run.output,
      "coalesced_count" => run.coalesced_count
    }
  end

  @doc "A stored UTC timestamp as ISO 8601, `nil`-tolerant."
  @spec iso(DateTime.t() | nil) :: String.t() | nil
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def iso(nil), do: nil
end
