defmodule Valea.Schedules.Scheduler do
  @moduledoc """
  The workspace's one scheduler: a GenServer that ticks every 30 s, re-reads
  every enabled ICM's `schedules.json`, and fires what is due (tasks+schedules
  spec §Scheduler runtime). It lives and dies with the open workspace, like the
  mail and calendar engines.

  ## Nothing that matters lives in this process

  The tick is a pure function of `schedules.json` (re-read every time, never
  cached) and the persisted state in `Valea.Schedules.Store` (fingerprints,
  anchors, tombstones, run records). Process state holds only the injected
  clock/runner/mount seams, the last unreadable-file hash per ICM (notice
  dedupe), and the last sweep date — all of it reconstructible, none of it
  load-bearing. A crash or a restart therefore cannot lose a slot, double-fire
  one, or resurrect one that was already consumed.

  ## The firing rule, in the order it runs (spec §Firing rule steps 1–7)

  1. **Load** — `Valea.Schedules.File.load/1` per enabled ICM mount. An
     `:unreadable` file fires nothing (fail-safe) and audits once per content
     hash; `:absent` is the ordinary state of a fresh ICM, and covers a
     vanished ICM root, so neither ever infers deletion.
  2. **Reconcile** — new, fingerprint-changed and reappeared-after-tombstone
     entries reset to `first_seen_at = last_attempted_slot = now`; ids that
     vanished from a *parseable* file get a tombstone. A newly registered
     schedule therefore first fires at its next FUTURE slot, and no edit or
     delete-recreate (byte-identical included) ever inherits old anchors.
  3. **Due test** — the first slot strictly after `max(last_attempted_slot,
     first_seen_at)`, due iff `<= now`. Strictly-after is load-bearing: the
     store truncates to the second, and `>=` would re-expose the slot an entry
     was registered in.
  4. **Coalesce** — every elapsed slot is consumed, but the fire happens once,
     carrying `coalesced_count`. A forward clock jump costs one fire.
  5. **One run at a time** — due while the previous run is live consumes ALL
     elapsed slots with ONE `skipped: still running` record, never one per
     slot and never re-emitted per tick.
  6. **Present-but-not-firing entries consume their slots silently** — paused,
     `not_executable`, duplicate-id carriers, and (uniformly) everything while
     the workspace kill switch is engaged: the anchor advances, nothing fires,
     nothing is recorded. Unpausing, repairing, de-duplicating or lifting the
     kill switch therefore never back-fires the gap.
  7. **Launch-time re-validation** — the file is re-read immediately before the
     spawn; the entry must still exist, still be executable and un-paused,
     carry the same fingerprint, and the kill switch must still be off, or this
     tick consumes NOTHING (not even the anchor). The guarantee is
     snapshot-based: an edit landing inside the snapshot-to-spawn window
     (milliseconds) may miss that one fire.

  Anchors are **monotonic**: every anchor write goes through `max(stored,
  candidate)`, so a backward clock jump or a restart can never regress one and
  re-expose consumed slots.

  ## Catch-up, on the first tick

  Reconciliation runs first (so a definition edited while Valea was closed is
  reset, not caught up). Then `catchup: false` (the default) fast-forwards the
  anchor to `max(anchor, now)` — missed slots consumed silently — while
  `catchup: true` leaves it, and the ordinary due test produces exactly one
  coalesced fire recorded with `trigger: "catchup"`.

  The first tick runs from `handle_continue/2` rather than a timer: it must
  happen before any `tick_now/0`/`run_now/2` call this process might receive,
  and a `Process.send_after(self(), :tick, 0)` is only *probably* first.

  ## Generation binding

  Every store write goes through `bound_write/2`, which re-checks the workspace
  generation first (`Valea.Workspace.Manager.check_generation/1`) — a run
  completing after a workspace switch cannot write into the new workspace's
  state. The tick itself is gated the same way. The ONE exemption is
  `terminate/2`, which marks still-`running` command runs `interrupted` under
  the *closing* generation: that write is the terminator acting, not a stale
  completion racing in (spec §Run lifecycle & workspace switch).

  Two honest limits on that shutdown write. It is **best-effort**: on a
  workspace close the Manager terminates the Repo BEFORE the Runtime, so by the
  time this process is asked to stop, the database is usually already gone. The
  reliable path is therefore the *boot* pass, which marks any command run still
  recorded `running` as `interrupted` on the first tick — nothing can be live in
  a Registry that was created seconds ago. Prompt runs are left `running` on
  purpose: their completion is observed lazily by the run-history query joining
  live session status (Task 6), which is also where a session parked on a
  permission ask becomes a `waiting` notice.

  ## Test seams

  `now_fun`, `runner`, `mounts_fun`, `generation_fun`, `tick_ms` and the
  test-only `before_launch` hook (run immediately before step 7's
  re-validation, so a test can land an edit inside the snapshot window). The
  determinism suite drives ticks synchronously with `tick_now/0` and never
  sleeps.
  """
  use GenServer

  require Logger

  alias Valea.Schedules.Cron
  alias Valea.Schedules.Entry
  alias Valea.Schedules.File, as: SchedulesFile
  alias Valea.Schedules.Store

  @tick_ms 30_000

  @running "running"
  @skipped "skipped: still running"
  @failed "failed"
  @interrupted "interrupted"

  # A bound on one tick's slot walk. Only reachable with `catchup: true` and a
  # very long closure (a minutely cron closed for months); the remainder is
  # consumed by the following ticks rather than spinning inside this one.
  @max_slots_per_tick 100_000

  # How long a generation check may block. Short on purpose — this process runs
  # INSIDE the workspace Runtime, so a long wait would hold up the close it is
  # asking about.
  @generation_timeout_ms 500

  # Per-tick "the generation check already said no" marker (process dictionary,
  # cleared at the top of every tick).
  @stale_key {__MODULE__, :generation_stale}

  # -- API ---------------------------------------------------------------------

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: __MODULE__)

  @doc """
  Runs one full tick synchronously and returns when it is done. The scheduler's
  own timer is untouched (this does not reschedule it). Tests use it to drive
  the clock deterministically; production uses the timer.
  """
  @spec tick_now() :: :ok
  def tick_now, do: GenServer.call(__MODULE__, :tick, 120_000)

  @doc """
  Fires a schedule now, out of band — the human override behind the UI's "run
  now" (Task 6's RPC).

  Allowed for `:executable` AND `:paused` entries: a paused schedule is one the
  user turned off for the *cadence*, and asking for it explicitly is a
  different act. Refused for `:not_executable` entries and duplicate-id
  carriers (there is no unambiguous definition to run), for an unknown id or
  ICM, while a run of the schedule is already live, and while the workspace
  kill switch is engaged — "everything is off" has to mean it.

  Records a run with `trigger: "manual"` and **does not touch the anchor**: a
  manual run consumes no slot, so the next scheduled fire lands exactly where
  it would have.
  """
  @spec run_now(String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error,
             :not_found
             | :not_executable
             | :already_running
             | :scheduler_paused
             | :workspace_changed}
  def run_now(icm_id, schedule_id) when is_binary(icm_id) and is_binary(schedule_id) do
    GenServer.call(__MODULE__, {:run_now, icm_id, schedule_id}, 120_000)
  end

  # -- lifecycle ---------------------------------------------------------------

  @impl true
  def init(cfg) do
    # Trapped so `terminate/2` runs on a workspace close (the shutdown-path
    # `interrupted` write).
    Process.flag(:trap_exit, true)

    state = %{
      root: cfg.root,
      generation: cfg.generation,
      tick_ms: Map.get(cfg, :tick_ms) || @tick_ms,
      now_fun: Map.get(cfg, :now_fun) || (&DateTime.utc_now/0),
      runner: Map.get(cfg, :runner) || Valea.Schedules.Runner.Live,
      # `Valea.Mounts.enabled/1` — the PURE form, listing OUR workspace's
      # mounts. Not `enabled/0`: that asks the Manager which workspace is
      # current, and a Runtime child calling into the Manager during a
      # close/switch deadlocks against its own shutdown (see
      # `Manager.check_generation/2`). It is also the more correct question —
      # this scheduler serves the workspace it was started for, whatever is
      # "current" by the time a tick lands.
      mounts_fun: Map.get(cfg, :mounts_fun) || fn -> {:ok, Valea.Mounts.enabled(cfg.root)} end,
      generation_fun: Map.get(cfg, :generation_fun) || (&default_generation_check/1),
      before_launch: Map.get(cfg, :before_launch),
      boot: true,
      notices: %{},
      last_sweep_date: nil
    }

    {:ok, state, {:continue, :boot_tick}}
  end

  @impl true
  def handle_continue(:boot_tick, state), do: {:noreply, schedule_tick(tick(state))}

  @impl true
  def handle_info(:tick, state), do: {:noreply, schedule_tick(tick(state))}

  @impl true
  def handle_info({:run_finished, run_id, outcome, duration_ms, output}, state) do
    {:noreply, record_completion(state, run_id, outcome, duration_ms, output)}
  end

  @impl true
  def handle_info(_ignored, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, :ok, tick(state)}

  @impl true
  def handle_call({:run_now, icm_id, schedule_id}, _from, state) do
    {:reply, do_run_now(state, icm_id, schedule_id), state}
  end

  @impl true
  def terminate(_reason, _state) do
    # The spec's one exemption from generation binding: the terminator records
    # `interrupted` synchronously, under the closing generation. Best-effort —
    # see the moduledoc: the Repo is usually already down on a workspace close,
    # and the boot pass is what makes this converge.
    Enum.each(live_command_keys(), fn {icm_id, schedule_id} ->
      interrupt_running_run(icm_id, schedule_id)
    end)

    :ok
  catch
    _kind, _reason -> :ok
  end

  # -- the tick ----------------------------------------------------------------

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, state.tick_ms)
    state
  end

  # A command run reporting its outcome. Degrades the same way a tick does: a
  # completion landing while the workspace closes finds a Repo on its way out,
  # and the honest outcome is a run row left `running` (the next boot pass marks
  # it `interrupted`), never a crashed scheduler.
  defp record_completion(state, run_id, outcome, duration_ms, output) do
    clear_stale()

    written =
      bound_write(state, fn ->
        Store.update_run(run_id, %{outcome: outcome, duration_ms: duration_ms, output: output})
      end)

    # Audited only when the write landed: a completion arriving after a
    # workspace switch must not leave a trace in the NEW workspace's log
    # either. Identified by `run_id` alone — the run record carries the rest,
    # and enriching this would mean keeping a run table in process state.
    if written != :refused do
      audit("schedule_run_finished", %{
        "run_id" => run_id,
        "outcome" => outcome,
        "duration_ms" => duration_ms
      })
    end

    state
  rescue
    error ->
      Logger.warning("scheduler completion degraded: #{Exception.message(error)}")
      state
  catch
    :exit, reason ->
      Logger.warning("scheduler completion degraded: #{inspect(reason)}")
      state
  end

  # Broad rescue/catch on purpose, mirroring `Valea.Cockpit.mail_summary/0`: a
  # tick landing in a workspace-close window touches a Repo that is going away,
  # and "some dependency of the read is down" must degrade to a skipped tick
  # rather than crash the scheduler (whose restart would then re-run the boot
  # pass against the same dying workspace). `boot` deliberately stays set on a
  # failed tick, so a first tick that could not complete retries its catch-up
  # instead of silently skipping it.
  defp tick(state) do
    clear_stale()
    now = now(state)

    if generation_ok?(state) do
      mounts = icm_mounts(state)

      state
      |> tick_mounts(mounts, now)
      |> sweep_if_due(mounts, now)
      |> Map.put(:boot, false)
    else
      state
    end
  rescue
    error ->
      Logger.warning("scheduler tick degraded: #{Exception.message(error)}")
      state
  catch
    :exit, reason ->
      Logger.warning("scheduler tick degraded: #{inspect(reason)}")
      state
  end

  defp tick_mounts(state, mounts, now) do
    Enum.reduce(mounts, state, fn mount, acc -> tick_mount(acc, mount, now) end)
  end

  defp tick_mount(state, mount, now) do
    icm_id = mount.manifest.id

    case SchedulesFile.load(mount.root) do
      %{status: :ok, entries: entries} ->
        entries = addressable(entries)

        state
        |> clear_notice(icm_id)
        |> reconcile(mount, icm_id, entries, now)
        |> boot_pass(mount, icm_id, entries, now)
        |> process_entries(mount, icm_id, entries, now)

      %{status: :unreadable, hash: hash} ->
        note_unreadable(state, mount, icm_id, hash)

      %{status: :absent} ->
        clear_notice(state, icm_id)
    end
  end

  # Entries with no id are not addressable — nothing can name them in an RPC,
  # nothing can key their state — so they are excluded from every pass; they
  # still show in the UI with their "missing id" reason. Duplicate ids collapse
  # to their FIRST carrier for state purposes (file order, so it is stable):
  # they never fire, but the id still needs exactly one state row, and letting
  # two carriers reconcile against it would thrash the fingerprint every tick.
  defp addressable(entries) do
    entries |> Enum.filter(& &1.id) |> Enum.uniq_by(& &1.id)
  end

  # -- step 2: reconciliation --------------------------------------------------

  defp reconcile(state, mount, icm_id, entries, now) do
    stored = Map.new(Store.states_for(icm_id), &{&1.schedule_id, &1})

    Enum.each(entries, fn entry ->
      case Map.get(stored, entry.id) do
        nil ->
          register(state, mount, icm_id, entry, now, "registered")

        %{deleted_at: deleted} when not is_nil(deleted) ->
          register(state, mount, icm_id, entry, now, "reappeared")

        %{fingerprint: stored_fp} when stored_fp != entry.fingerprint ->
          register(state, mount, icm_id, entry, now, "changed")

        _unchanged ->
          :ok
      end
    end)

    present = MapSet.new(entries, & &1.id)

    Enum.each(stored, fn {schedule_id, row} ->
      if is_nil(row.deleted_at) and not MapSet.member?(present, schedule_id) do
        bound_write(state, fn -> Store.put_state(icm_id, schedule_id, %{deleted_at: now}) end)

        audit("schedule_registered_changed", %{
          "mount_key" => mount.name,
          "icm_id" => icm_id,
          "schedule_id" => schedule_id,
          "fingerprint" => row.fingerprint,
          "change" => "deleted"
        })
      end
    end)

    state
  end

  # One write for the whole reset, including the explicit `deleted_at: nil`
  # that lifts a tombstone (`put_state/3` merges over stored, so an explicit
  # nil CLEARS while an omitted key preserves).
  defp register(state, mount, icm_id, entry, now, change) do
    bound_write(state, fn ->
      Store.put_state(icm_id, entry.id, %{
        fingerprint: entry.fingerprint,
        first_seen_at: now,
        last_attempted_slot: now,
        deleted_at: nil
      })
    end)

    audit("schedule_registered_changed", %{
      "mount_key" => mount.name,
      "icm_id" => icm_id,
      "schedule_id" => entry.id,
      "fingerprint" => entry.fingerprint,
      "created_by" => entry.created_by,
      "change" => change
    })
  end

  # -- the boot pass: stale runs + catch-up ------------------------------------

  defp boot_pass(%{boot: false} = state, _mount, _icm_id, _entries, _now), do: state

  defp boot_pass(state, _mount, icm_id, entries, now) do
    # Any command run still recorded `running` predates this workspace session
    # (the Registry is seconds old and empty), so it was interrupted by whatever
    # ended that session. Covers tombstoned schedules too, which is why it
    # walks stored state rather than the file's entries.
    Enum.each(Store.states_for(icm_id), fn row ->
      if command_run_pending?(icm_id, row.schedule_id) do
        bound_write(state, fn -> interrupt_running_run(icm_id, row.schedule_id) end)
      end
    end)

    # Spec §Catch-up: `false` fast-forwards (silently consuming what passed
    # while closed), `true` leaves the anchor for the ordinary due test to
    # coalesce into one `catchup` fire. Runs AFTER reconciliation, so an entry
    # edited while Valea was closed is reset rather than caught up.
    Enum.each(entries, fn entry ->
      unless entry.catchup do
        advance(state, icm_id, entry.id, Store.get_state(icm_id, entry.id), now)
      end
    end)

    state
  end

  defp command_run_pending?(icm_id, schedule_id) do
    match?([%{outcome: @running, kind: "command"}], Store.runs(icm_id, schedule_id, 1))
  end

  defp interrupt_running_run(icm_id, schedule_id) do
    case Store.runs(icm_id, schedule_id, 1) do
      [%{outcome: @running, id: run_id}] -> Store.update_run(run_id, %{outcome: @interrupted})
      _no_pending_run -> :ok
    end
  end

  # -- steps 3–7: per entry ----------------------------------------------------

  defp process_entries(state, mount, icm_id, entries, now) do
    paused_all? = kill_switch?(state)

    Enum.each(entries, fn entry ->
      process_entry(state, mount, icm_id, entry, now, paused_all?)
    end)

    state
  end

  defp process_entry(state, mount, icm_id, entry, now, paused_all?) do
    case Store.get_state(icm_id, entry.id) do
      nil ->
        # Only reachable when reconciliation's write was refused (stale
        # generation) — there is no anchor to reason from, so do nothing.
        :ok

      row ->
        due(state, mount, icm_id, entry, row, now, paused_all?)
    end
  end

  # A state row with NO anchors at all — not something this module writes, but a
  # future writer (an RPC seeding a row) could. Adopt `now` rather than treating
  # the epoch as the anchor and firing every slot since 1970.
  defp due(
         state,
         _mount,
         icm_id,
         entry,
         %{last_attempted_slot: nil, first_seen_at: nil} = row,
         now,
         _paused_all?
       ) do
    advance(state, icm_id, entry.id, row, now)
  end

  # An entry with no parseable cron has no slots to walk, so "consume the
  # elapsed slots" degenerates to "consume the elapsed time": the anchor
  # advances to now, and repairing the cron (a fingerprint change, hence a
  # reset anyway) never back-fires.
  defp due(state, _mount, icm_id, %Entry{cron: nil} = entry, row, now, _paused_all?) do
    advance(state, icm_id, entry.id, row, now)
  end

  defp due(state, mount, icm_id, entry, row, now, paused_all?) do
    case elapsed_slots(entry, row, now) do
      {0, _latest} ->
        :ok

      {count, latest} ->
        cond do
          entry.disposition != :executable or paused_all? ->
            advance(state, icm_id, entry.id, row, latest)

          live?(state, icm_id, entry) ->
            record_skip(state, mount, icm_id, entry, count, latest, now)
            advance(state, icm_id, entry.id, row, latest)

          true ->
            launch(state, mount, icm_id, entry, row, count, latest, now)
        end
    end
  end

  # Every slot strictly after the anchor and at or before now. Returns the
  # count (the spec's `coalesced_count`) and the latest one (the new anchor).
  defp elapsed_slots(entry, row, now) do
    walk_slots(entry, anchor(row), now, 0, nil)
  end

  defp walk_slots(_entry, _cursor, _now, count, latest) when count >= @max_slots_per_tick do
    {count, latest}
  end

  defp walk_slots(entry, cursor, now, count, latest) do
    case Cron.next_slot(entry.cron, entry.timezone, cursor) do
      {:ok, slot} ->
        if DateTime.compare(slot, now) == :gt do
          {count, latest}
        else
          walk_slots(entry, slot, now, count + 1, slot)
        end

      {:error, :invalid_zone} ->
        # The zone was validated when the entry was built; if it stopped
        # resolving, the entry has no slots — fail closed, fire nothing.
        {count, latest}
    end
  end

  defp anchor(row), do: later(row.last_attempted_slot, row.first_seen_at)

  # -- step 7 + launch ---------------------------------------------------------

  defp launch(state, mount, icm_id, entry, row, count, latest, now) do
    trigger = if state.boot and entry.catchup, do: "catchup", else: "scheduled"

    run_before_launch(state)

    case revalidate(state, mount, entry) do
      {:ok, fresh} ->
        fire(state, mount, icm_id, fresh, row, count, latest, now, trigger, advance: true)

      :stop ->
        # Consume NOTHING this tick — not even the anchor. The next tick
        # re-evaluates against a file that now says what it says.
        :ok
    end
  end

  # Test-only hook: the window the spec calls snapshot-to-spawn, made
  # addressable so a test can land a pause/edit/kill-switch inside it.
  defp run_before_launch(%{before_launch: hook}) when is_function(hook, 0), do: hook.()
  defp run_before_launch(_no_hook), do: :ok

  defp revalidate(state, mount, entry) do
    expected = entry.fingerprint

    with false <- kill_switch?(state),
         %{status: :ok, entries: entries} <- SchedulesFile.load(mount.root),
         %Entry{disposition: :executable, fingerprint: ^expected} = fresh <-
           Enum.find(entries, &(&1.id == entry.id)) do
      {:ok, fresh}
    else
      _gone_or_changed_or_paused -> :stop
    end
  end

  # The lifecycle the store documents: record BEFORE the spawn (so a crash in
  # the spawn window still leaves evidence a fire happened), attach the session
  # after, and only then advance the anchor.
  defp fire(state, mount, icm_id, entry, row, count, latest, now, trigger, opts) do
    kind = Atom.to_string(entry.payload.kind)

    attrs = %{
      icm_id: icm_id,
      schedule_id: entry.id,
      fingerprint: entry.fingerprint,
      slot: latest,
      fired_at: now,
      trigger: trigger,
      kind: kind,
      outcome: @running,
      coalesced_count: count,
      mount_key: mount.name
    }

    case bound_write(state, fn -> Store.record_run(attrs) end) do
      {:ok, run_id} ->
        meta = meta(state, mount, icm_id, entry, latest, trigger, count, run_id)
        result = start_run(state, mount, entry, meta)
        settle(state, mount, icm_id, entry, row, latest, run_id, result, kind, trigger, opts)

      :refused ->
        {:error, :workspace_changed}
    end
  end

  defp start_run(state, mount, %Entry{payload: %{kind: :prompt}} = entry, meta) do
    state.runner.start_prompt(mount, entry, meta)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp start_run(state, mount, %Entry{payload: %{kind: :command}} = entry, meta) do
    state.runner.start_command(mount, entry, meta, self())
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp settle(state, mount, icm_id, entry, row, latest, run_id, result, kind, trigger, opts) do
    case result do
      {:ok, handle} ->
        if is_binary(handle) do
          bound_write(state, fn -> Store.update_run(run_id, %{session_id: handle}) end)
        end

        audit("schedule_fired", %{
          "mount_key" => mount.name,
          "icm_id" => icm_id,
          "schedule_id" => entry.id,
          "fingerprint" => entry.fingerprint,
          "trigger" => trigger,
          "kind" => kind,
          "slot" => iso(latest),
          "session_id" => if(is_binary(handle), do: handle),
          "command" => command_line(entry)
        })

        if opts[:advance], do: advance(state, icm_id, entry.id, row, latest)
        {:ok, run_id}

      {:error, reason} ->
        detail = "spawn failed: #{inspect(reason)}"

        # Detail goes in `output`, NEVER appended to the outcome token: the
        # notice feed matches outcomes by exact equality.
        bound_write(state, fn ->
          Store.update_run(run_id, %{outcome: @failed, duration_ms: 0, output: detail})
        end)

        audit("schedule_run_failed", %{
          "mount_key" => mount.name,
          "icm_id" => icm_id,
          "schedule_id" => entry.id,
          "fingerprint" => entry.fingerprint,
          "trigger" => trigger,
          "kind" => kind,
          "detail" => detail
        })

        # The slot is spent either way — the spec's no-auto-retry rule ("the
        # next slot is the retry").
        if opts[:advance], do: advance(state, icm_id, entry.id, row, latest)
        {:error, reason}
    end
  end

  defp record_skip(state, mount, icm_id, entry, count, latest, now) do
    bound_write(state, fn ->
      Store.record_run(%{
        icm_id: icm_id,
        schedule_id: entry.id,
        fingerprint: entry.fingerprint,
        slot: latest,
        fired_at: now,
        trigger: "scheduled",
        kind: Atom.to_string(entry.payload.kind),
        outcome: @skipped,
        coalesced_count: count,
        mount_key: mount.name
      })
    end)

    audit("schedule_skipped", %{
      "mount_key" => mount.name,
      "icm_id" => icm_id,
      "schedule_id" => entry.id,
      "fingerprint" => entry.fingerprint,
      "trigger" => "scheduled",
      "coalesced_count" => count
    })
  end

  defp meta(state, mount, icm_id, entry, slot, trigger, count, run_id) do
    %{
      icm_id: icm_id,
      icm_name: mount.manifest.name,
      mount_key: mount.name,
      schedule_id: entry.id,
      fingerprint: entry.fingerprint,
      slot: slot,
      trigger: trigger,
      coalesced_count: count,
      generation: state.generation,
      run_id: run_id,
      workspace_root: state.root
    }
  end

  # The full command line, for the audit (spec §Audit: "command fires record
  # the full command line").
  defp command_line(%Entry{payload: %{kind: :command, command: command, args: args}}) do
    Enum.join([command | args], " ")
  end

  defp command_line(_prompt_payload), do: nil

  # -- run_now -----------------------------------------------------------------

  defp do_run_now(state, icm_id, schedule_id) do
    clear_stale()
    now = now(state)

    with :ok <- generation_check(state),
         :ok <- kill_switch_check(state),
         {:ok, mount} <- find_mount(state, icm_id),
         {:ok, entry} <- find_entry(mount, schedule_id),
         :ok <- runnable(entry),
         :ok <- not_live(state, icm_id, entry) do
      # Same launch path, minus the anchor: a manual run consumes no slot.
      fire(state, mount, icm_id, entry, nil, 1, now, now, "manual", advance: false)
    end
  rescue
    error ->
      Logger.warning("run_now degraded: #{Exception.message(error)}")
      {:error, :not_found}
  catch
    :exit, reason ->
      Logger.warning("run_now degraded: #{inspect(reason)}")
      {:error, :not_found}
  end

  defp find_mount(state, icm_id) do
    case Enum.find(icm_mounts(state), &(&1.manifest.id == icm_id)) do
      nil -> {:error, :not_found}
      mount -> {:ok, mount}
    end
  end

  defp find_entry(mount, schedule_id) do
    case SchedulesFile.load(mount.root) do
      %{status: :ok, entries: entries} ->
        case Enum.find(entries, &(&1.id == schedule_id)) do
          nil -> {:error, :not_found}
          entry -> {:ok, entry}
        end

      _absent_or_unreadable ->
        {:error, :not_found}
    end
  end

  defp runnable(%Entry{disposition: disposition}) when disposition in [:executable, :paused],
    do: :ok

  defp runnable(_not_executable), do: {:error, :not_executable}

  defp not_live(state, icm_id, entry) do
    if live?(state, icm_id, entry), do: {:error, :already_running}, else: :ok
  end

  defp kill_switch_check(state) do
    if kill_switch?(state), do: {:error, :scheduler_paused}, else: :ok
  end

  # -- liveness ----------------------------------------------------------------

  defp live?(state, icm_id, entry) do
    last =
      case Store.runs(icm_id, entry.id, 1) do
        [run] -> run
        [] -> nil
      end

    state.runner.live?(icm_id, entry.id, entry.payload.kind, last)
  end

  # -- anchors -----------------------------------------------------------------

  # The one place an anchor is written, and it is monotonic by construction:
  # `max(stored, candidate)`, so a backward clock jump or a stale candidate can
  # never re-expose a consumed slot.
  defp advance(state, icm_id, schedule_id, row, candidate) do
    stored = row && row.last_attempted_slot
    target = later(stored, candidate)

    if target && target != stored do
      bound_write(state, fn ->
        Store.put_state(icm_id, schedule_id, %{last_attempted_slot: target})
      end)
    end

    :ok
  end

  defp later(nil, b), do: b
  defp later(a, nil), do: a
  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  # -- mounts, clock, kill switch ---------------------------------------------

  defp icm_mounts(state) do
    case state.mounts_fun.() do
      {:ok, mounts} -> Enum.filter(mounts, &schedulable?/1)
      mounts when is_list(mounts) -> Enum.filter(mounts, &schedulable?/1)
      _no_workspace -> []
    end
  end

  # ICM mounts only (spec §Non-goals: no workspace-level schedules — the mail
  # and calendar engines keep their own loops), and only ones whose manifest id
  # exists: that id is the state key.
  defp schedulable?(%{kind: :icm, enabled: true, degraded: nil, manifest: %{id: id}})
       when is_binary(id),
       do: true

  defp schedulable?(_other), do: false

  # Second-truncated, matching what the store persists: comparing an
  # untruncated `now` against truncated anchors would make the strictly-after
  # due test wobble inside a second.
  defp now(state), do: state.now_fun.() |> DateTime.truncate(:second)

  defp kill_switch?(state), do: Valea.Mounts.scheduler_paused?(state.root)

  # -- generation binding ------------------------------------------------------

  # The default check, for production: the Manager's authoritative answer, on a
  # short leash. See `Valea.Workspace.Manager.check_generation/2` for why a
  # Runtime child must not wait the full default here.
  defp default_generation_check(generation) do
    Valea.Workspace.Manager.check_generation(generation, @generation_timeout_ms)
  end

  defp generation_ok?(state), do: generation_check(state) == :ok

  # Re-checked per write (a switch can land mid-tick), but ONCE refused, the
  # rest of this tick short-circuits: a tick that overlaps a close would
  # otherwise pay the timeout per entry and hold up the very shutdown it is
  # racing. The marker is per-tick (cleared at the top of every tick and
  # `run_now`), so it is a memo, never a cache of "the workspace is gone".
  defp generation_check(state) do
    if Process.get(@stale_key) do
      {:error, :workspace_changed}
    else
      case state.generation_fun.(state.generation) do
        :ok ->
          :ok

        _stale ->
          Process.put(@stale_key, true)
          {:error, :workspace_changed}
      end
    end
  catch
    # No Manager, one mid-restart, or one too busy to answer: none of those can
    # confirm this workspace is still the open one — fail closed.
    :exit, _reason ->
      Process.put(@stale_key, true)
      {:error, :workspace_changed}
  end

  defp clear_stale, do: Process.delete(@stale_key)

  defp bound_write(state, fun) do
    if generation_ok?(state), do: fun.(), else: :refused
  end

  # -- notices, audit, sweep ---------------------------------------------------

  # One audit per content hash, so a file that stays broken stays quiet until
  # it changes. Process-local on purpose: this is notice dedupe, and re-audit
  # after a restart is the harmless direction.
  defp note_unreadable(state, mount, icm_id, hash) do
    if Map.get(state.notices, icm_id) == hash do
      state
    else
      audit("schedules_unreadable", %{
        "mount_key" => mount.name,
        "icm_id" => icm_id,
        # Hex, not the raw digest `Valea.Ledger.JsonFile` hands back: an audit
        # entry is JSON, and raw SHA-256 bytes fail to encode — which drops the
        # WHOLE entry, silently.
        "hash" => hash && Base.encode16(hash, case: :lower)
      })

      %{state | notices: Map.put(state.notices, icm_id, hash)}
    end
  end

  defp clear_notice(state, icm_id), do: %{state | notices: Map.delete(state.notices, icm_id)}

  defp audit(type, fields), do: Valea.Audit.append(type, fields)

  # Daily auto-archive (spec §Archival) — once on the first tick, then whenever
  # the UTC date turns over.
  defp sweep_if_due(state, mounts, now) do
    date = DateTime.to_date(now)

    if state.last_sweep_date == date do
      state
    else
      Enum.each(mounts, &sweep_mount(&1, now))
      %{state | last_sweep_date: date}
    end
  end

  defp sweep_mount(mount, now) do
    Valea.Tasks.sweep(mount.root, now: now)
  rescue
    error -> Logger.warning("task sweep degraded (#{mount.name}): #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("task sweep degraded (#{mount.name}): #{inspect(reason)}")
  end

  defp live_command_keys do
    Registry.select(Valea.Schedules.RunRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  catch
    _kind, _reason -> []
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
