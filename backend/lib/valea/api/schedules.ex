defmodule Valea.Api.Schedules do
  @moduledoc """
  The schedules RPC (tasks+schedules spec §RPC surface): `list_schedules`,
  `create_schedule`, `mutate_schedule`, `delete_schedule`, `run_schedule_now`,
  `schedule_run_history`, `set_scheduler_paused`.

  UI-plane only — agents have no RPC path, so registering a schedule from an
  agent means writing `schedules.json` with ordinary file tools, which is
  always-ask by policy. These actions are the *user* acting through the
  control-token-gated socket, which is why they carry no extra gate of their
  own (spec §Consent & containment).

  Conventions follow `Valea.Api.Tasks` verbatim: `check_generation/1` FIRST on
  every action (`verified/2`), string keys throughout (the falsy-at-top-level
  rule), unconstrained `:map` arguments whose keys are the file's own
  snake_case names, ledger writes through `Valea.Schedules.Edit` (so they
  serialize in `Valea.Ledger.Writer` and never clobber a key), and the
  writer-is-gone exits mapped to `workspace_not_open` / `workspace_changed`
  rather than a 500.

  ## What a row carries, and why

    * `disposition` + `reason` — `Valea.Schedules.Entry`'s strict-execution
      verdict, verbatim: `"executable" | "paused" | "not_executable"` with the
      per-entry sentence for the last one ("invalid cron: …", "duplicate id",
      "`paused` is not a boolean"). The UI renders the reason on the row; the
      strict-execution guarantee has no UI override.
    * `cadence` / `timezone` / `payload_kind` are DISPLAY fields and fall back
      to the raw file values when validation stopped before reaching them (the
      validation order is id → cron → timezone → payload, so an entry refused
      for its cron would otherwise show no payload chip at all). Lenient
      display, strict execution — both halves of the spec's contract.
    * `next_fire` is computed ONLY for `executable` entries, from
      `max(last_attempted_slot, first_seen_at)` (the scheduler's own anchor
      semantics) or from now when the schedule has no state row yet. A paused
      or non-executable entry advertises no next fire, because it has none.
    * `last_outcome` is the newest run EVENT's projected outcome — which may be
      a `"skipped: still running"` record, and may be `"waiting"` for a session
      parked on an ask (see `Valea.Schedules.Runs` for why that outcome exists
      only as a read-time projection).
    * `registered_recently` backs the spec's "newly registered/changed
      schedules get a subtle highlight" — `first_seen_at` inside 24 h.
    * `paused` is the file's own flag, filled in for display independently of
      the validation chain, so an entry refused for another reason still shows
      the pause it asked for (a `not_executable` row's toggle would otherwise
      render wrong).

  Per-ICM `status` ("ok" | "absent" | "unreadable") rides alongside, for the
  calm malformed-file note; an unreadable file yields NO entries, because
  nothing fires from a file Valea cannot parse.

  `create_schedule`/`mutate_schedule` answer with the same `disposition` +
  `reason` beside the written entry. Writes are deliberately lenient — the file
  is the user's, and an invalid entry lands and shows up non-executable rather
  than being refused — so the composer needs to hear "saved, and it will not
  fire: invalid cron" in the SAME reply, without re-implementing the strict
  validation only the backend may own.

  ## The kill switch is TRI-state

  `scheduler_paused` is `"on" | "off" | "unreadable"` — never a boolean.
  `"unreadable"` means `config/workspace.yaml` exists but does not parse, so
  nobody can say what the user asked for; it fails CLOSED (nothing fires) and
  the UI copy for it differs from a deliberate pause. Folding it into `true`
  would tell the user they paused something they did not.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Schedules")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Schedules.Cron
  alias Valea.Schedules.Edit
  alias Valea.Schedules.File, as: SchedulesFile
  alias Valea.Schedules.Runs
  alias Valea.Schedules.Scheduler
  alias Valea.Schedules.Store
  alias Valea.Workspace.Manager

  # Identity and provenance Valea stamps; a caller may not forge them.
  @valea_owned ~w(id created_at created_by)

  @recent_seconds 86_400
  @default_history_limit 20
  @max_history_limit 200

  @icm_row_fields [
    mount_key: [type: :string, allow_nil?: false],
    icm_name: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    schedules: [type: {:array, :map}, allow_nil?: false]
  ]

  # The write actions' shared shape: the entry AS WRITTEN (unconstrained — it
  # round-trips the user's own fields) plus the disposition it now has.
  # `disposition` is nullable only for the vanishing race below.
  @edit_result_fields [
    schedule: [type: :map, allow_nil?: false],
    disposition: [type: :string, allow_nil?: true],
    reason: [type: :string, allow_nil?: true]
  ]

  actions do
    action :list_schedules, :map do
      constraints fields: [
                    icms: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [items: [fields: @icm_row_fields]]
                    ],
                    scheduler_paused: [type: :string, allow_nil?: false]
                  ]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        verified(input.arguments.generation, fn ws ->
          {:ok,
           %{
             "icms" => Enum.map(icm_mounts(ws), &schedules_row/1),
             "scheduler_paused" => to_string(Mounts.scheduler_pause_state(ws))
           }}
        end)
      end
    end

    # The write is LENIENT (the file is the user's; an invalid entry lands and
    # shows up non-executable), so the response carries the entry's freshly
    # read-back `disposition`/`reason` beside it: a composer that just saved
    # "30 25 * * *" can say "not executable: invalid cron" without a second
    # round trip, and without the UI having to re-implement the strict
    # validation it must never own.
    action :create_schedule, :map do
      constraints fields: @edit_result_fields

      argument :mount_key, :string, allow_nil?: false
      argument :fields, :map, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, fields: fields, generation: generation} = input.arguments

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key),
               {:ok, entry} <- Edit.create(mount.root, user_fields(fields, "user")) do
            audit(mount_key, entry["id"], "create")
            {:ok, edit_result(mount, entry)}
          end
        end)
      end
    end

    action :mutate_schedule, :map do
      constraints fields: @edit_result_fields

      argument :mount_key, :string, allow_nil?: false
      argument :schedule_id, :string, allow_nil?: false
      argument :patch, :map, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, schedule_id: id, patch: patch, generation: generation} =
          input.arguments

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key),
               {:ok, entry} <- Edit.patch(mount.root, id, user_fields(patch, nil)) do
            audit(mount_key, id, "mutate")
            {:ok, edit_result(mount, entry)}
          end
        end)
      end
    end

    action :delete_schedule, :map do
      constraints fields: [deleted: [type: :boolean, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :schedule_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, schedule_id: id, generation: generation} = input.arguments

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key),
               {:ok, _entry} <- Edit.delete(mount.root, id) do
            audit(mount_key, id, "delete")
            {:ok, %{"deleted" => true}}
          end
        end)
      end
    end

    # The debug affordance: fire NOW, out of band. Identical launch path to a
    # scheduled fire (launch-time re-validation included), recorded as
    # `trigger: "manual"`, and it does NOT advance the anchor. Allowed for
    # `executable` AND `paused` entries — an explicit human click overrides a
    # pause once — and refused for `not_executable`/duplicate ones with the
    # displayed reason's own error code. Not audited here: the scheduler audits
    # every fire itself, with the fingerprint and (for commands) the full
    # command line.
    action :run_schedule_now, :map do
      constraints fields: [run_id: [type: :string, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :schedule_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, schedule_id: id, generation: generation} = input.arguments

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key),
               {:ok, run_id} <- Scheduler.run_now(mount.manifest.id, String.trim(id)) do
            {:ok, %{"run_id" => run_id}}
          end
        end)
      end
    end

    # Run history for one schedule — keyed by `(icm_id, schedule_id)`, so it
    # survives the schedule's deletion and the mount's rename (spec §Audit).
    # `output` IS included (already capped at 256 KiB by the writer): this is
    # the surface where a command run's captured output belongs, and where a
    # prompt run's transcript link (`session_id`) comes from.
    action :schedule_run_history, :map do
      constraints fields: [runs: [type: {:array, :map}, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :schedule_id, :string, allow_nil?: false
      argument :limit, :integer, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, schedule_id: id, generation: generation} = input.arguments
        limit = history_limit(Map.get(input.arguments, :limit))

        verified(generation, fn ws ->
          with {:ok, mount} <- icm_mount(ws, mount_key) do
            {:ok, %{"runs" => Runs.history(mount.manifest.id, String.trim(id), limit)}}
          end
        end)
      end
    end

    # Pause-all. Audited here rather than in `Valea.Mounts` because this is
    # where the human intent is (spec §Audit — "pause/resume incl. Pause-all"),
    # and the reported state is READ BACK from the file: a config that turned
    # unreadable under the write must not be reported as a clean pause.
    action :set_scheduler_paused, :map do
      constraints fields: [scheduler_paused: [type: :string, allow_nil?: false]]

      argument :paused, :boolean, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{paused: paused, generation: generation} = input.arguments

        verified(generation, fn ws ->
          with :ok <- Mounts.set_scheduler_paused(ws, paused) do
            state = to_string(Mounts.scheduler_pause_state(ws))
            Valea.Audit.append("scheduler_pause_set", %{"scheduler_paused" => state})
            {:ok, %{"scheduler_paused" => state}}
          end
        end)
      end
    end
  end

  # -- rows --------------------------------------------------------------------

  # One `states_for/1` query per ICM (batched) plus one newest-run lookup per
  # ENTRY. The per-entry query is deliberate: "the newest event" is an ordered
  # top-1 per schedule, which SQLite would need a window function for, and a
  # schedules file has single digits of entries — the file is a human-maintained
  # cadence list, not a table. If that ever stops being true, batch here, not in
  # `Valea.Schedules.Store`.
  defp schedules_row(mount) do
    %{status: status, entries: entries} = SchedulesFile.load(mount.root)
    states = Map.new(Store.states_for(mount.manifest.id), &{&1.schedule_id, &1})
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      "mount_key" => mount.name,
      "icm_name" => mount.manifest.name,
      "status" => to_string(status),
      "schedules" => Enum.map(entries, &schedule_payload(&1, mount, Map.get(states, &1.id), now))
    }
  end

  defp schedule_payload(entry, mount, state, now) do
    %{
      "id" => entry.id,
      "title" => entry.title,
      "disposition" => to_string(entry.disposition),
      "reason" => entry.reason,
      "cadence" => entry.cron_raw,
      "timezone" => entry.timezone || raw_string(entry.raw["timezone"]),
      "payload_kind" => payload_kind(entry),
      # The raw payload map as written in the file — the composer's Edit flow
      # seeds its fields from this (a row click must show what the schedule
      # DOES, not just its kind). Display data of the user's own file; `nil`
      # when the file carries none or a non-map.
      "payload" => raw_payload(entry),
      "paused" => entry.paused,
      "catchup" => entry.catchup,
      "created_by" => entry.created_by,
      "next_fire" => next_fire(entry, state, now),
      "last_outcome" => entry.id && Runs.last_outcome(mount.manifest.id, entry.id),
      "registered_recently" => recent?(state, now)
    }
  end

  # The written entry plus its disposition, read back through
  # `Valea.Schedules.File.load/1` rather than `Entry.build/1` alone: the
  # duplicate-id pass is FILE-WIDE (an entry is only a duplicate relative to its
  # siblings), and dispositioning has exactly one owner. The extra read is one
  # file per write, on a human-paced action.
  #
  # `nil`/`nil` if the id is no longer in the file by the time it is re-read —
  # a foreign writer deleted it in the microseconds since. Nothing to say about
  # an entry that is gone, and inventing a disposition for it would be worse.
  defp edit_result(mount, entry) do
    id = entry["id"]

    found =
      mount.root
      |> SchedulesFile.load()
      |> Map.fetch!(:entries)
      |> Enum.find(&(is_binary(id) and &1.id == String.trim(id)))

    %{
      "schedule" => entry,
      "disposition" => found && to_string(found.disposition),
      "reason" => found && found.reason
    }
  end

  # The file's own payload map, verbatim (string keys) — display/edit seeding
  # only, never re-validated here. `nil` for absent or wrong-typed.
  defp raw_payload(%{raw: %{"payload" => %{} = payload}}), do: payload
  defp raw_payload(_entry), do: nil

  defp payload_kind(%{payload: %{kind: kind}}), do: to_string(kind)

  # Lenient display fallback for an entry refused BEFORE payload validation.
  defp payload_kind(entry) do
    case entry.raw["payload"] do
      %{"kind" => kind} -> raw_string(kind)
      _absent_or_wrong_typed -> nil
    end
  end

  defp raw_string(value) when is_binary(value), do: value
  defp raw_string(_wrong_typed), do: nil

  # Only an executable entry has a next fire. The base is the scheduler's own
  # anchor semantics — the LATEST of the consumed-slot anchor and the
  # first-seen instant — falling back to now for a schedule this workspace has
  # never seen (which is what the scheduler's first pass will anchor it to).
  defp next_fire(%{disposition: :executable, cron: cron, timezone: zone}, state, now)
       when not is_nil(cron) do
    case Cron.next_slot(cron, zone, anchor(state, now)) do
      {:ok, slot} -> DateTime.to_iso8601(slot)
      {:error, :invalid_zone} -> nil
    end
  end

  defp next_fire(_paused_or_not_executable, _state, _now), do: nil

  defp anchor(nil, now), do: now

  defp anchor(state, now) do
    [state.last_attempted_slot, state.first_seen_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> now end)
  end

  defp recent?(nil, _now), do: false
  defp recent?(%{first_seen_at: nil}, _now), do: false

  defp recent?(%{first_seen_at: first_seen_at}, now) do
    DateTime.diff(now, first_seen_at, :second) <= @recent_seconds
  end

  defp history_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_history_limit)

  defp history_limit(_absent_or_nonsense), do: @default_history_limit

  # -- shared plumbing ---------------------------------------------------------

  # Enabled ICM content mounts in config order — schedules are ICM files, and
  # there are no workspace-level schedules (spec §Non-goals).
  defp icm_mounts(ws) do
    ws |> Mounts.enabled() |> Enum.filter(&(&1.kind == :icm and &1.manifest != nil))
  end

  defp icm_mount(ws, mount_key) do
    case Mounts.mount_by_key(ws, mount_key) do
      %{kind: :icm, enabled: true, degraded: nil, manifest: %{id: id}} = mount
      when is_binary(id) ->
        {:ok, mount}

      _missing_disabled_degraded_or_synthetic ->
        {:error, :icm_unavailable}
    end
  end

  defp user_fields(fields, created_by) when is_map(fields) do
    fields
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(@valea_owned)
    |> then(fn stripped ->
      if created_by, do: Map.put(stripped, "created_by", created_by), else: stripped
    end)
  end

  defp audit(mount_key, schedule_id, action) do
    Valea.Audit.append("schedule_edited", %{
      "mount_key" => mount_key,
      "schedule_id" => schedule_id,
      "action" => action
    })
  end

  # See `Valea.Api.Tasks.verified/2` — same contract, same reasoning; the
  # `GenServer.call/3` exits caught here are `Valea.Ledger.Writer`'s AND
  # `Valea.Schedules.Scheduler`'s (both workspace-runtime children, so
  # `run_schedule_now` with nothing open exits exactly like a ledger write).
  defp verified(generation, fun) when is_function(fun, 1) do
    result =
      with :ok <- Manager.check_generation(generation),
           {:ok, %{path: ws}} <- Manager.current() do
        fun.(ws)
      end

    case result do
      {:error, reason} -> {:error, error_for(reason)}
      {:ok, payload} -> {:ok, payload}
    end
  catch
    :exit, {:noproc, {GenServer, :call, _args}} ->
      {:error, error_for(:no_workspace)}

    :exit, {:normal, {GenServer, :call, _args}} ->
      {:error, error_for(:workspace_changed)}

    :exit, {:shutdown, {GenServer, :call, _args}} ->
      {:error, error_for(:workspace_changed)}

    :exit, {{:shutdown, _reason}, {GenServer, :call, _args}} ->
      {:error, error_for(:workspace_changed)}
  end

  # Central error mapping. Everything the dependencies return already
  # stringifies to the client code the frontend renders — `not_found`,
  # `duplicate_id`, `conflict`, `unreadable`, `not_executable`,
  # `already_running`, `scheduler_paused`, `workspace_changed`,
  # `internal_error`, `icm_unavailable` — with two translations:
  # `:no_workspace` is the shared `workspace_not_open`, and a
  # `{:config_unreadable, _}` from a `config/workspace.yaml` that will not
  # parse becomes `config_unreadable` (the pause toggle's own failure: Valea
  # refuses to rewrite a config it cannot read).
  # Public (`@doc false`) for the same reason as `Valea.Api.Tasks.error_for/1`:
  # `:conflict` cannot be driven through an action (it needs a foreign writer
  # inside the optimistic window, which only `Valea.Schedules.Edit`'s
  # `:before_write` seam can stage — see `Valea.Schedules.EditTest`), and
  # `{:config_unreadable, _}` needs a `workspace.yaml` that parses for the
  # generation guard and then fails for the write.
  @doc false
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for({:config_unreadable, _reason}), do: Error.new("config_unreadable")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))
end
