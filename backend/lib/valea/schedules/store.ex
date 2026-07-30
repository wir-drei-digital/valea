defmodule Valea.Schedules.Store do
  @moduledoc """
  The scheduler's persisted state — `Valea.Repo` (per-workspace,
  `AshSqlite.DataLayer`) backed by two tables (tasks+schedules spec §Scheduler
  runtime → Persisted state):

    * `schedule_state` (`State`) — per-`(icm_id, schedule_id)` anchors and
      execution fingerprint. What decides whether a slot is due.
    * `schedule_runs` (`Run`) — one row per fire/skip event. What the human
      reads afterwards.

  Neither is cache. `schedules.json` is the source of truth for schedule
  *definitions*; these tables are the source of truth for *what has already
  been consumed* and *what happened*, and nothing rebuilds them.

  No `AshTypescript` extension — this domain is internal-only, never exposed
  over RPC (the cockpit and Tasks views reach it through `Valea.Api`, Task 6).
  The resources stay deliberately minimal (one `:upsert`/`:create` action
  apiece plus one narrow `:update`, no timestamps/soft-deletes/relationships
  beyond what's hand-declared); the plain-Elixir API below is hand-written on
  top of them rather than generated `code_interface` `define`s, because the
  merge-over-stored upsert and the notice split are small pieces of logic, not
  bare CRUD. Same shape as `Valea.Mail.Store`.

  ## Invariants this module keeps, and the ones it deliberately does not

    * **The key is `(icm_id, schedule_id)`**, `icm_id` being the ICM's
      `manifest.id` — the identity that survives a mount rename or re-add.
      `mount_key` appears on run records as display metadata only.
    * **Timestamps are UTC**, `:utc_datetime`, second precision. Slots are
      minute-granular by construction, so nothing load-bearing is truncated.
    * **`last_attempted_slot` is monotonic — it never moves backward.** This
      module *persists* the anchor; it does not police it. The `max/2` that
      enforces monotonicity across a backward clock jump or a restart lives in
      the scheduler (spec §Catch-up), because only the caller knows which
      candidate is the new anchor.
    * **Run records outlive their schedule.** They carry no foreign key to
      `schedule_state`, so a tombstone — or a hard-deleted state row — never
      cascades history away, and `runs/3` answers for a `(icm_id,
      schedule_id)` that has no state row at all.
    * **`output` is capped by the CALLER**, per the command containment
      contract. Nothing here re-caps or truncates it.
    * **Outcomes are free-form strings**, not an enum — see
      `Valea.Schedules.Store.Run`. `notices_since/1` matches `"waiting"` and
      `"failed"` by exact equality, so detail belongs in `output`, never
      appended to the outcome.
    * **`fired_at` can never be NULL** (`allow_nil? false` *and* a default): it
      is both the history ordering key and the notices' window bound, and a
      NULL fails `fired_at >= ?` silently — a failed run would show in
      `runs/3` while being permanently invisible to `notices_since/1`.
    * **`put_state/3`'s merge-over-stored is forward-insurance, not a fix for a
      live bug.** `State` has no attribute defaults today, so a bare upsert
      would behave identically; the merge is what keeps that true if a
      `default:` is ever added. Full reasoning on `put_state/3` and on
      `Valea.Schedules.Store.State`; a test pins the emitted `SET` list.
  """
  use Ash.Domain

  require Ash.Query

  alias Valea.Schedules.Store.Run
  alias Valea.Schedules.Store.State

  resources do
    resource State
    resource Run
  end

  # The two outcomes the cockpit surfaces as notices. Exact equality, on
  # purpose — see the `Run` moduledoc.
  @notice_outcomes ["waiting", "failed"]

  @state_keys [
    :icm_id,
    :schedule_id,
    :fingerprint,
    :first_seen_at,
    :last_attempted_slot,
    :deleted_at
  ]

  # -- schedule state ----------------------------------------------------------

  @doc """
  The stored state for `(icm_id, schedule_id)`, or `nil` when the schedule has
  never been seen in this workspace.

  A tombstoned schedule still has a row: `deleted_at` is set, and the caller
  needs to see it — "this id was seen before and is now absent" is exactly what
  distinguishes a reappearance (reset the anchors) from a first registration.
  """
  @spec get_state(String.t(), String.t()) :: map() | nil
  def get_state(icm_id, schedule_id) do
    case fetch_state(icm_id, schedule_id) do
      {:ok, row} -> state_map(row)
      :error -> nil
    end
  end

  @doc """
  Upserts `(icm_id, schedule_id)`'s state. Only the keys present in `attrs`
  change; every other column keeps its stored value.

  Read-modify-write, not a bare `ON CONFLICT ... DO UPDATE`. As the schema
  stands today a bare upsert would behave identically — `State` declares no
  attribute defaults, and an omitted attribute with no default never reaches
  the INSERT column list, so the `SET` clause only touches columns the caller
  passed. The merge is deliberate **forward-insurance**: give any of those four
  columns a `default:` and an omitted key would start arriving as that default
  and overwrite the stored value, which is the live bug
  `Valea.Mail.Store.put_sync_state/3` documents (`backfill_complete`/`held`
  carry `default: false` there, and a partial write resets whichever flag it
  did not mention). The scheduler advances the anchor with
  `%{last_attempted_slot: slot}` on most ticks; that write must never be able
  to erase the fingerprint the due test just matched on, whatever the schema
  grows later. `Valea.Schedules.Store.State`'s moduledoc carries the same note,
  and a test pins the emitted `SET` list so the merge cannot be dropped as
  dead code.

  Independently of that, the merge is what gives `attrs` its **explicit-`nil`
  clears** semantics — which is how the reappearance reset lifts a tombstone
  (`%{fingerprint: fp, first_seen_at: now, last_attempted_slot: now,
  deleted_at: nil}` in one write) while omitting `deleted_at` preserves it.

  Unknown keys are dropped rather than raising, so a caller may hand back a map
  it got from `get_state/2`.
  """
  @spec put_state(String.t(), String.t(), map()) :: :ok
  def put_state(icm_id, schedule_id, attrs) when is_map(attrs) do
    stored =
      case fetch_state(icm_id, schedule_id) do
        {:ok, row} -> state_map(row)
        :error -> %{}
      end

    merged =
      stored
      |> Map.merge(Map.take(attrs, @state_keys))
      |> Map.merge(%{icm_id: icm_id, schedule_id: schedule_id})

    State
    |> Ash.Changeset.for_create(:upsert, merged)
    |> Ash.create!()

    :ok
  end

  @doc """
  Every stored state for `icm_id`, tombstoned rows included — the reconciler
  needs the tombstones (see `get_state/2`), and the UI filters them out itself.
  Order is unspecified.
  """
  @spec states_for(String.t()) :: [map()]
  def states_for(icm_id) do
    State
    |> Ash.Query.filter(icm_id == ^icm_id)
    |> Ash.read!()
    |> Enum.map(&state_map/1)
  end

  defp fetch_state(icm_id, schedule_id) do
    case Ash.get(State, %{icm_id: icm_id, schedule_id: schedule_id}) do
      {:ok, row} -> {:ok, row}
      {:error, _not_found} -> :error
    end
  end

  defp state_map(row) do
    %{
      icm_id: row.icm_id,
      schedule_id: row.schedule_id,
      fingerprint: row.fingerprint,
      first_seen_at: row.first_seen_at,
      last_attempted_slot: row.last_attempted_slot,
      deleted_at: row.deleted_at
    }
  end

  # -- run records -------------------------------------------------------------

  @doc """
  Writes a run record and returns its id — the handle `update_run/2` needs when
  the run finishes.

  `icm_id`, `schedule_id` and `fired_at` are required; `id` is generated unless
  `attrs` carries one, `fired_at` defaults to now when the key is **absent**
  (an explicit `nil` raises — see `Valea.Schedules.Store.Run`), and
  `coalesced_count` to `1`. That resource's moduledoc also has what each field
  means, which outcome tokens the notices depend on, and why `output` arrives
  pre-capped.

  Strict about its input, unlike `put_state/3`: a missing required attribute or
  an unrecognised key raises (`attribute icm_id is required`, `No such input
  \`...\``). A run record is the only evidence a scheduled run happened — a
  misspelled field silently dropped would leave a history row that lies. Call
  it BEFORE the spawn and attach the session with `update_run/2`; see there for
  the full lifecycle.
  """
  @spec record_run(map()) :: {:ok, String.t()}
  def record_run(attrs) when is_map(attrs) do
    run =
      Run
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!()

    {:ok, run.id}
  end

  @doc """
  Advances a run record: any of `session_id`, `outcome`, `duration_ms` and
  `output` present in `attrs`. Omitted keys are left untouched (a bare
  `%{outcome: "timed out"}` keeps the partial output already captured), and the
  launch columns (`slot`, `trigger`, `fingerprint`, `kind`, `coalesced_count`,
  `mount_key`) are immutable — they are history.

  Strict about its input, like `record_run/1`: an unrecognised or immutable key
  raises rather than being silently dropped, so a typo cannot leave a run
  record that quietly never recorded its outcome.

  The lifecycle this supports, for the scheduler:

      {:ok, run_id} = record_run(%{..., outcome: "running"})   # BEFORE the spawn
      update_run(run_id, %{session_id: sid})                    # spawn returned
      update_run(run_id, %{outcome: "completed", duration_ms: ms, output: text})

  Recording before the spawn is the point: a crash in the window between the
  two still leaves evidence that the fire happened. `session_id` is therefore a
  post-create write, not a create field — though `record_run/1` accepts it too,
  for a caller that already has the id.

  A silent no-op — not an error — when `run_id` is unknown: the workspace
  database can be replaced under a long-running run, and a completion with
  nowhere to land has nothing useful to raise about.
  """
  @spec update_run(String.t(), map()) :: :ok
  def update_run(run_id, attrs) when is_map(attrs) do
    case Ash.get(Run, run_id) do
      {:ok, run} ->
        run
        |> Ash.Changeset.for_update(:progress, attrs)
        |> Ash.update!()

        :ok

      {:error, _not_found} ->
        :ok
    end
  end

  @doc """
  Up to `limit` run records for `(icm_id, schedule_id)`, **newest `fired_at`
  first**. Answers even when no `schedule_state` row exists (history outlives
  the schedule).

  Runs sharing a `fired_at` second fall back to a stable but arbitrary order
  (descending id); in practice one schedule cannot have two events in the same
  second, since only one run of a schedule is ever live.
  """
  @spec runs(String.t(), String.t(), pos_integer()) :: [map()]
  def runs(icm_id, schedule_id, limit) do
    Run
    |> Ash.Query.filter(icm_id == ^icm_id and schedule_id == ^schedule_id)
    |> Ash.Query.sort(fired_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.map(&run_map/1)
  end

  @doc """
  The cockpit's notice feed since `utc`, across every ICM and schedule:

      %{waiting: [run], failed: [run], registered: [state]}

  `waiting` and `failed` are the run records whose `outcome` is exactly
  `"waiting"` or `"failed"` with `fired_at >= utc`, newest first; `registered`
  is the states with `first_seen_at >= utc` (a schedule newly seen in this
  workspace), newest first. Everything else — `"completed"`,
  `"skipped: still running"`, `"interrupted"`, `"timed out"`, `"running"` — is
  history, not a notice.

  `utc` is truncated to the second before comparing, matching the stored
  precision: a cutoff mid-second includes that whole second rather than
  half-excluding events that were themselves truncated down into it. The bound
  is inclusive, so a caller polling with the previous call's instant may see one
  event twice; dedupe on the run id.
  """
  @spec notices_since(DateTime.t()) :: %{waiting: [map()], failed: [map()], registered: [map()]}
  def notices_since(%DateTime{} = utc) do
    since = DateTime.truncate(utc, :second)

    by_outcome =
      Run
      |> Ash.Query.filter(outcome in ^@notice_outcomes and fired_at >= ^since)
      |> Ash.Query.sort(fired_at: :desc, id: :desc)
      |> Ash.read!()
      |> Enum.map(&run_map/1)
      |> Enum.group_by(& &1.outcome)

    registered =
      State
      |> Ash.Query.filter(not is_nil(first_seen_at) and first_seen_at >= ^since)
      |> Ash.Query.sort(first_seen_at: :desc)
      |> Ash.read!()
      |> Enum.map(&state_map/1)

    %{
      waiting: Map.get(by_outcome, "waiting", []),
      failed: Map.get(by_outcome, "failed", []),
      registered: registered
    }
  end

  defp run_map(row) do
    %{
      id: row.id,
      icm_id: row.icm_id,
      schedule_id: row.schedule_id,
      fingerprint: row.fingerprint,
      slot: row.slot,
      fired_at: row.fired_at,
      trigger: row.trigger,
      kind: row.kind,
      outcome: row.outcome,
      duration_ms: row.duration_ms,
      session_id: row.session_id,
      output: row.output,
      coalesced_count: row.coalesced_count,
      mount_key: row.mount_key
    }
  end
end
