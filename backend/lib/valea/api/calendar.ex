defmodule Valea.Api.Calendar do
  @moduledoc """
  Data-layer-less Ash resource exposing the calendar subsystem over RPC
  (calendar spec F, §RPC surface) — the 13 actions of the spec's table,
  following `Valea.Api.Mail`'s conventions throughout:

    * `constraints fields: [...]` typed actions for fixed top-level
      shapes; UNCONSTRAINED `:map`/`{:array, :map}` passthrough for
      heterogeneous or wire-pinned content: `calendar_status`'s
      `sources` (valid entries carry the full
      `Valea.Calendar.Engine.status/1` shape, invalid-config entries
      only `source`/`valid`/`state`/`reason`), `calendar_doctor`'s
      `checks`, and `list_calendar_events`' `events` — the
      CalendarOccurrence rows are THE wire schema Task 7 consumes
      (string keys, snake_case, no camelCase translation), so they pass
      through verbatim.
    * The ash_typescript top-level falsy rule (see `Valea.Api.Mail`'s
      moduledoc): every top-level field that can genuinely be `false`
      uses a STRING key (`saved`, `accepted`, `removed`, `purged`,
      `started`, `ok`, `created`, `updated`, `deleted`,
      `feed_enabled`).
    * Every MUTATING action takes `generation` and guards with
      `Valea.Workspace.Manager.check_generation/1` first (a fast path —
      for the lifecycle mutations the AUTHORITATIVE check re-runs inside
      the serialized section, see `verified_lifecycle/2`); the read-only
      actions (`calendar_status`, `list_calendar_events`) still resolve
      `Manager.current/0` before touching anything.
    * Every `source` argument is grammar-validated FIRST
      (`Valea.Calendar.Settings.valid_slug?/1` — which already embeds
      the reserved `valea`), before it is ever interpolated into a path
      or reaches an engine.
    * `set_calendar_source_url`'s `url` is `sensitive? true` (the
      `set_mail_credential` posture) and `Valea.Calendar.Fetch.validate_url/1`
      runs BEFORE any engine call or `.source` claim — a rejected URL
      leaves no state behind anywhere.
    * Lifecycle mutations (setup / set-url / remove / purge, plus the
      feed-token config writes) run through `verified_lifecycle/2`:
      `Valea.Calendar.Supervisor.lifecycle/1`, the per-slug serializer —
      no two lifecycle mutations can interleave (spec §Sync engine) —
      with the generation check AND root resolution RE-RUN inside the
      serialized section, so a stale RPC parked behind a workspace
      switch can never mutate the newly opened workspace and every
      effect acts on the root resolved under the lock (the valea-event
      actions carry the same posture via `Local.write/5`'s `verify:`
      hook).

  ## `list_calendar_events`

  The range is the half-open `[from, to)` interpreted in `zone` (an IANA
  name validated against the configured tz database — an invalid zone is
  a typed error, never a silent default). Zone-boundary instants resolve
  through `Valea.Calendar.Ics.resolve/2`, i.e. the Task-1 pinned DST
  rules (ambiguous local midnight → earlier instant; nonexistent →
  first instant after the gap). Timed rows match by OVERLAP
  (`occ_start < zone_end AND occ_end > zone_start`); all-day rows by
  date-range overlap of `[start, end)` against `[from, to)` (exclusive
  ends). Valea events are merged LIVE (`Valea.Calendar.Local.list/1` —
  no index round-trip), timed ones UTC-normalized. Rows come back
  chronologically IN `zone`: per local day, all-day rows first, then
  timed by local start.

  External rows' `description` is HYDRATED at query time from the view
  file body (the SQLite index stores no description column — spec's
  pinned columns); a missing/unreadable view degrades to `nil`, never an
  error. `events_in_range/4` is public: `Valea.Cockpit`'s Today line is
  computed through this exact query path (host-zone today).
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Calendar")
  end

  alias Valea.Api.Error
  alias Valea.Calendar.Doctor
  alias Valea.Calendar.Engine
  alias Valea.Calendar.Fetch
  alias Valea.Calendar.Ics
  alias Valea.Calendar.Local
  alias Valea.Calendar.Settings
  alias Valea.Calendar.Store
  alias Valea.Calendar.Supervisor, as: CalendarSupervisor
  alias Valea.Workspace.Manager

  actions do
    # -- status ---------------------------------------------------------------

    action :calendar_status, :map do
      constraints fields: [
                    sources: [type: {:array, :map}, allow_nil?: false],
                    feed_enabled: [type: :boolean, allow_nil?: false],
                    valea_event_count: [type: :integer, allow_nil?: false],
                    valea_invalid: [type: {:array, :map}, allow_nil?: false],
                    config_invalid: [type: :string, allow_nil?: true]
                  ]

      run fn _input, _ctx ->
        with {:ok, %{path: root}} <- Manager.current() do
          {:ok, status_payload(root)}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- source lifecycle -----------------------------------------------------

    action :setup_calendar_source, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]

      argument :source, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{source: slug, name: name, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <-
               verified_lifecycle(generation, fn root ->
                 with :ok <- Settings.put_source(root, slug, name) do
                   CalendarSupervisor.rehash()
                 end
               end) do
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_calendar_source_url, :map do
      constraints fields: [accepted: [type: :boolean, allow_nil?: false]]

      argument :source, :string, allow_nil?: false
      argument :url, :string, allow_nil?: false, sensitive?: true
      argument :generation, :integer, allow_nil?: false

      # `Fetch.validate_url/1` runs FIRST — `:not_https`/`:invalid_url`
      # surface before any engine call or `.source` claim (the admission
      # gate; `Engine.set_url/2` re-runs it as defense-in-depth).
      run fn input, _ctx ->
        %{source: slug, url: url, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- Fetch.validate_url(url),
             :ok <- verified_lifecycle(generation, fn _root -> Engine.set_url(slug, url) end) do
          {:ok, %{"accepted" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :remove_calendar_source, :map do
      constraints fields: [removed: [type: :boolean, allow_nil?: false]]

      argument :source, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{source: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <-
               verified_lifecycle(generation, fn root ->
                 with :ok <- Settings.remove_source(root, slug) do
                   CalendarSupervisor.rehash()
                 end
               end) do
          {:ok, %{"removed" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :purge_calendar_source_files, :map do
      constraints fields: [purged: [type: :boolean, allow_nil?: false]]

      argument :source, :string, allow_nil?: false
      argument :confirmation, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      # Typed confirm = slug; only ever a non-configured EXTERNAL target
      # (the reserved `valea` fails the slug grammar; a slug that is
      # neither configured nor has files on disk is `not_found` —
      # `ensure_purge_target/2` runs INSIDE the serialized section
      # against the in-lock root, so the target validation can never see
      # a different workspace than the deletion). The deletion itself is
      # `Supervisor.purge!/1`: called from within `verified_lifecycle/2`
      # it re-enters the serializer directly (`lifecycle/1`'s
      # re-entrancy guard) — refuse-while-configured, await any
      # in-flight pass, re-check, then delete files + index rows, all
      # ONE serialized unit with the workspace verification.
      run fn input, _ctx ->
        %{source: slug, confirmation: confirmation, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- require_confirmation(confirmation, slug),
             :ok <-
               verified_lifecycle(generation, fn root ->
                 with :ok <- ensure_purge_target(root, slug) do
                   CalendarSupervisor.purge!(slug)
                 end
               end) do
          {:ok, %{"purged" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- sync / doctor --------------------------------------------------------

    action :calendar_sync_now, :map do
      constraints fields: [started: [type: :boolean, allow_nil?: false]]

      argument :source, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{source: slug, generation: generation} = input.arguments

        # Same in-lock re-verification as every other mutating action: a
        # sync pass fetches and rewrites the mirror/index, so a stale
        # generation parked behind a workspace switch must never start one
        # against the NEW workspace's same-slug engine (Codex round 5).
        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             :ok <- validate_slug(slug),
             :ok <- verified_lifecycle(generation, fn _root -> Engine.sync_now(slug) end) do
          {:ok, %{"started" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :calendar_doctor, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    checks: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :source, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{source: slug, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_slug(slug),
             {:ok, %{checks: checks, ok: ok}} <- Doctor.run(%{root: root, source: slug}) do
          {:ok, %{"ok" => ok, "checks" => checks}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- events (read-only) ---------------------------------------------------

    action :list_calendar_events, :map do
      constraints fields: [events: [type: {:array, :map}, allow_nil?: false]]

      argument :from, :string, allow_nil?: false
      argument :to, :string, allow_nil?: false
      argument :zone, :string, allow_nil?: false

      run fn input, _ctx ->
        %{from: from, to: to, zone: zone} = input.arguments

        with {:ok, %{path: root}} <- Manager.current(),
             {:ok, events} <- events_in_range(root, from, to, zone) do
          {:ok, %{events: events}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- valea events ---------------------------------------------------------

    action :create_valea_event, :map do
      constraints fields: [
                    created: [type: :boolean, allow_nil?: false],
                    path: [type: :string, allow_nil?: false]
                  ]

      argument :name, :string, allow_nil?: false
      argument :title, :string, allow_nil?: false
      argument :start, :string, allow_nil?: false
      argument :end, :string, allow_nil?: true
      argument :all_day, :boolean, allow_nil?: true
      argument :location, :string, allow_nil?: true
      argument :status, :string, allow_nil?: true
      argument :description, :string, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      # `name` is a bare basename without extension — the grammar
      # (`Local.valid_name?/1`) rejects separators/traversal BEFORE any
      # path construction (the get_mail_draft posture); `Local.write/5`
      # then validates the attrs through the full fail-closed table and
      # refuses an existing name. The generation check + root resolution
      # RE-RUN inside the write's serialized section (`verify_workspace/1`)
      # so a stale RPC parked behind a workspace switch can never mutate
      # the old root.
      run fn input, _ctx ->
        %{name: name, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_event_name(name),
             {:ok, path} <-
               Local.write(root, name, event_attrs(input.arguments), :create,
                 verify: verify_workspace(generation)
               ) do
          broadcast_local_changed()
          {:ok, %{"created" => true, "path" => path}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :update_valea_event, :map do
      constraints fields: [updated: [type: :boolean, allow_nil?: false]]

      argument :name, :string, allow_nil?: false
      argument :title, :string, allow_nil?: false
      argument :start, :string, allow_nil?: false
      argument :end, :string, allow_nil?: true
      argument :all_day, :boolean, allow_nil?: true
      argument :location, :string, allow_nil?: true
      argument :status, :string, allow_nil?: true
      argument :description, :string, allow_nil?: true
      argument :generation, :integer, allow_nil?: false

      # Full-replace write of the named file (spec table); generation +
      # root re-verified inside the serialized section (create's posture).
      run fn input, _ctx ->
        %{name: name, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_event_name(name),
             {:ok, _path} <-
               Local.write(root, name, event_attrs(input.arguments), :update,
                 verify: verify_workspace(generation)
               ) do
          broadcast_local_changed()
          {:ok, %{"updated" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :delete_valea_event, :map do
      constraints fields: [deleted: [type: :boolean, allow_nil?: false]]

      argument :name, :string, allow_nil?: false
      argument :confirmation, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, confirmation: confirmation, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- validate_event_name(name),
             :ok <- require_confirmation(confirmation, name),
             :ok <- Local.delete(root, name, verify: verify_workspace(generation)) do
          broadcast_local_changed()
          {:ok, %{"deleted" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # -- served feed ----------------------------------------------------------

    action :enable_calendar_feed, :map do
      constraints fields: [token: [type: :string, allow_nil?: false]]

      argument :generation, :integer, allow_nil?: false

      # The plain token is returned exactly ONCE; only its sha256 hex is
      # persisted (`Settings.generate_feed_token/1`). The config write is
      # serialized through the lifecycle (with the workspace re-verified
      # in-lock) so it can never interleave with a concurrent
      # setup/remove rewrite of the same file — nor land on a workspace
      # opened after this request was issued.
      run fn input, _ctx ->
        %{generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             {:ok, token} <-
               verified_lifecycle(generation, fn root -> Settings.generate_feed_token(root) end) do
          {:ok, %{"token" => token}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :rotate_calendar_feed_token, :map do
      constraints fields: [token: [type: :string, allow_nil?: false]]

      argument :generation, :integer, allow_nil?: false

      # Overwriting the stored hash IS the rotation (Settings moduledoc);
      # the previous token stops verifying the moment the write lands.
      run fn input, _ctx ->
        %{generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, _ws} <- Manager.current(),
             {:ok, token} <-
               verified_lifecycle(generation, fn root -> Settings.generate_feed_token(root) end) do
          {:ok, %{"token" => token}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping — mirrors `Valea.Api.Mail.error_for/1`. Most
  # dependencies return atoms whose `to_string/1` already IS the client
  # code; the exceptions:
  #   * `:no_workspace` -> "workspace_not_open" (the shared convention);
  #   * `:not_running` (a slug with no engine) -> "not_found" — the
  #     client-facing meaning is "no such source", exactly like mail's
  #     unknown-account mapping;
  #   * `{:invalid, reason}` (Settings whole-file invalidity or a
  #     valea-event validation failure) -> the reason string VERBATIM (the
  #     mail binary-passthrough posture) — the event editor and the setup
  #     panel show the human-readable why;
  #   * `{:lifecycle_failed, _}` (a raising lifecycle fun, degraded by the
  #     Supervisor) -> "lifecycle_failed".
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(:not_running), do: Error.new("not_found")
  def error_for(:enoent), do: Error.new("not_found")
  def error_for({:invalid, reason}) when is_binary(reason), do: Error.new(reason)
  def error_for({:lifecycle_failed, _message}), do: Error.new("lifecycle_failed")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason) when is_binary(reason), do: Error.new(reason)
  def error_for(reason), do: Error.new(inspect(reason))

  # -- guards -------------------------------------------------------------------

  # THE shared wrapper for every lifecycle-serialized mutation (setup /
  # set-url / remove / purge / feed-token — the valea-event actions get
  # the identical posture through `Local.write/5`'s `verify:` hook):
  # enters `Valea.Calendar.Supervisor.lifecycle/1` and RE-RUNS the
  # workspace guards INSIDE the serialized section — after any queued
  # mutation (or completed workspace switch) ahead of it — handing `fun`
  # the FRESH root resolved under the lock. The out-of-lock pre-checks in
  # each action are only a fast path; this is the authoritative check: a
  # stale RPC whose lifecycle call lands on a NEWLY opened workspace's
  # supervisor fails `check_generation/1` here, before any effect against
  # the new root. The guard errors are the exact atoms the pre-checks
  # already surface (`:workspace_changed`, `:no_workspace`), so
  # `error_for/1` maps them identically — no wire change. A serializer
  # that is gone, or dies out from under the queued call (workspace
  # closing, nothing reopened yet), is the same stale-workspace condition
  # the generation pre-check reports for a closed workspace — surfaced as
  # `:workspace_changed`, never a raw exit.
  defp verified_lifecycle(generation, fun) when is_function(fun, 1) do
    CalendarSupervisor.lifecycle(fn ->
      with :ok <- Manager.check_generation(generation),
           {:ok, %{path: root}} <- Manager.current() do
        fun.(root)
      end
    end)
  catch
    :exit, {:noproc, {GenServer, :call, _args}} -> {:error, :workspace_changed}
    :exit, {:shutdown, {GenServer, :call, _args}} -> {:error, :workspace_changed}
    :exit, {{:shutdown, _reason}, {GenServer, :call, _args}} -> {:error, :workspace_changed}
  end

  defp validate_slug(slug) do
    if Settings.valid_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end

  defp validate_event_name(name) do
    if Local.valid_name?(name), do: :ok, else: {:error, :invalid_event_name}
  end

  defp require_confirmation(confirmation, expected) do
    if confirmation == expected, do: :ok, else: {:error, :confirmation_mismatch}
  end

  # The `verify:` closure for `Local.write/5` / `Local.delete/3` —
  # executed INSIDE the write serializer, after any queued mutation ahead
  # of it: the generation check AND the root resolution both re-run under
  # the lock, so a mutation parked behind a workspace switch fails
  # `workspace_changed` against the NEW workspace's serializer instead of
  # writing the root it captured before the switch. The errors are the
  # exact atoms the pre-checks already surface (`:workspace_changed`,
  # `:no_workspace`), so `error_for/1` maps them identically.
  defp verify_workspace(generation) do
    fn ->
      with :ok <- Manager.check_generation(generation),
           {:ok, %{path: root}} <- Manager.current() do
        {:ok, root}
      end
    end
  end

  # A purge target must be a real external source: still configured (the
  # purge itself then refuses with `still_configured` — remove first), or
  # unconfigured with files on disk. A slug that is neither is `not_found`
  # — purge never "succeeds" against something that never existed.
  defp ensure_purge_target(root, slug) do
    configured? =
      case Settings.load(root) do
        {:ok, %Settings{sources: sources, invalid: invalid}} ->
          Map.has_key?(sources, slug) or Map.has_key?(invalid, slug)

        _absent_or_invalid ->
          false
      end

    if configured? or File.dir?(Path.join([root, "sources", "calendar", slug])) do
      :ok
    else
      {:error, :not_found}
    end
  end

  # -- calendar_status ----------------------------------------------------------

  # Mirrors `Valea.Api.Mail.mail_status_accounts/1`: valid sources are the
  # running engines' statuses stringified + `"valid" => true`; per-entry
  # invalid config synthesizes `invalid_config` entries; a WHOLE-FILE
  # invalid config yields `"sources" => []` plus the top-level
  # `"config_invalid"` reason (nil whenever the file is absent or valid).
  # The local Valea calendar stays available throughout (mount
  # availability keys on file EXISTENCE — Task 5), so `feed_enabled` and
  # `valea_event_count` are always computed.
  defp status_payload(root) do
    load = Settings.load(root)

    {sources, config_invalid} =
      case load do
        {:error, {:invalid, reason}} -> {[], reason}
        _valid_or_absent -> {status_sources(load), nil}
      end

    valea = Local.list(root)

    %{
      "sources" => sources,
      "feed_enabled" => feed_enabled?(load),
      "valea_event_count" => length(valea.valid),
      # Spec §The Valea calendar: a file that fails validation is "listed as
      # `invalid` with its reason (UI + status), rendered NOWHERE" — this is
      # the status half; the setup panel renders it.
      "valea_invalid" =>
        Enum.map(valea.invalid, fn entry ->
          %{"name" => entry.name, "reason" => entry.reason}
        end),
      "config_invalid" => config_invalid
    }
  end

  defp status_sources(load) do
    invalid =
      case load do
        {:ok, %Settings{invalid: invalid}} -> invalid
        _absent -> %{}
      end

    valid_entries =
      Enum.map(Engine.statuses(), fn {_slug, status} ->
        status |> stringify() |> Map.put("valid", true)
      end)

    invalid_entries =
      Enum.map(invalid, fn {slug, reason} ->
        %{"source" => slug, "valid" => false, "state" => "invalid_config", "reason" => reason}
      end)

    (valid_entries ++ invalid_entries) |> Enum.sort_by(& &1["source"])
  end

  defp feed_enabled?({:ok, %Settings{feed_token_hash: hash}}), do: is_binary(hash)
  defp feed_enabled?(_absent_or_invalid), do: false

  defp stringify(status), do: Map.new(status, fn {k, v} -> {to_string(k), v} end)

  # -- list_calendar_events -----------------------------------------------------

  @doc """
  The one merged range query (see the moduledoc section): external index
  rows (descriptions hydrated from view files) plus live-read valea
  events, as CalendarOccurrence wire rows ordered chronologically in
  `zone`. Public because `Valea.Cockpit`'s Today line runs through this
  exact path for host-zone today.
  """
  @spec events_in_range(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :invalid_range | :invalid_zone}
  def events_in_range(root, from, to, zone) do
    with {:ok, from_date} <- parse_date(from),
         {:ok, to_date} <- parse_date(to),
         :ok <- validate_zone(zone),
         {:ok, zone_start} <- zone_boundary(from_date, zone),
         {:ok, zone_end} <- zone_boundary(to_date, zone) do
      external =
        Store.occurrences_overlapping(
          DateTime.to_iso8601(zone_start),
          DateTime.to_iso8601(zone_end),
          Date.to_iso8601(from_date),
          Date.to_iso8601(to_date)
        )
        |> Enum.map(&external_row(root, &1))

      valea =
        Local.list(root).valid
        |> Enum.filter(&valea_in_range?(&1, zone_start, zone_end, from_date, to_date))
        |> Enum.map(&valea_row/1)

      {:ok, Enum.sort_by(external ++ valea, &sort_key(&1, zone))}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_range}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_range}

  # Validated against the configured tz database — an invalid zone is an
  # ERROR, never silently defaulted.
  defp validate_zone(zone) when is_binary(zone) do
    case DateTime.now(zone) do
      {:ok, _now} -> :ok
      {:error, _reason} -> {:error, :invalid_zone}
    end
  end

  defp validate_zone(_zone), do: {:error, :invalid_zone}

  # Local midnight of `date` in `zone` as a UTC instant, through the
  # Task-1 DST rules (`Ics.resolve/2`: ambiguous → earlier, gap → after).
  defp zone_boundary(%Date{} = date, zone) do
    case Ics.resolve({:floating, NaiveDateTime.new!(date, ~T[00:00:00])}, zone) do
      {:ok, instant} -> {:ok, instant}
      {:error, :unknown_tzid} -> {:error, :invalid_zone}
    end
  end

  defp external_row(root, row) do
    %{
      "source" => row.source,
      "all_day" => row.all_day,
      "start" => row.occ_start,
      "end" => row.occ_end,
      "summary" => row.summary || "",
      "location" => row.location,
      "status" => row.status,
      "description" => hydrate_description(root, row.view_path),
      "view_path" => row.view_path,
      "path" => nil
    }
  end

  # The description lives ONLY in the view file body (the index stores no
  # description column) — read it live for rows in range. Lenient: a
  # missing or malformed view degrades to nil, never an error. The path
  # is engine-written, but sanity-gate it to the calendar tree anyway.
  defp hydrate_description(root, view_path) do
    with true <- is_binary(view_path) and String.starts_with?(view_path, "sources/calendar/"),
         {:ok, "---\n" <> rest} <- File.read(Path.join(root, view_path)),
         [_frontmatter, body] <- String.split(rest, "\n---\n", parts: 2) do
      presence(String.trim_trailing(body, "\n"))
    else
      _missing_or_malformed -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp valea_in_range?(%Local.Event{all_day: false} = event, zone_start, zone_end, _from, _to) do
    occ_start = to_utc(event.start)
    occ_end = to_utc(Map.fetch!(event, :end))

    DateTime.compare(occ_start, zone_end) == :lt and
      DateTime.compare(occ_end, zone_start) == :gt
  end

  defp valea_in_range?(%Local.Event{all_day: true} = event, _zone_start, _zone_end, from, to) do
    Date.compare(event.start, to) == :lt and Date.compare(Map.fetch!(event, :end), from) == :gt
  end

  defp valea_row(%Local.Event{all_day: false} = event) do
    %{
      "source" => "valea",
      "all_day" => false,
      "start" => DateTime.to_iso8601(to_utc(event.start)),
      "end" => DateTime.to_iso8601(to_utc(Map.fetch!(event, :end))),
      "summary" => event.title,
      "location" => event.location,
      "status" => event.status,
      "description" => presence(event.description),
      "view_path" => nil,
      "path" => event.path
    }
  end

  defp valea_row(%Local.Event{all_day: true} = event) do
    %{
      "source" => "valea",
      "all_day" => true,
      "start" => Date.to_iso8601(event.start),
      "end" => Date.to_iso8601(Map.fetch!(event, :end)),
      "summary" => event.title,
      "location" => event.location,
      "status" => event.status,
      "description" => presence(event.description),
      "view_path" => nil,
      "path" => event.path
    }
  end

  # UTC-normalize a (possibly fixed-offset) DateTime without a tz-database
  # lookup — valea files carry arbitrary offsets; second precision.
  defp to_utc(%DateTime{} = dt), do: dt |> DateTime.to_unix() |> DateTime.from_unix!()

  # Chronological IN `zone`: per local day, all-day rows (0) before timed
  # (1); timed ordered by local wall-clock start. All-day rows sort under
  # their (plain-date) start; string dates and naive ISO strings compare
  # correctly lexicographically. Trailing keys keep ties deterministic.
  defp sort_key(%{"all_day" => true} = row, _zone) do
    {row["start"], 0, "", row["end"], row["summary"]}
  end

  defp sort_key(%{"all_day" => false} = row, zone) do
    local = local_naive_iso(row["start"], zone)
    {String.slice(local, 0, 10), 1, local, row["end"], row["summary"]}
  end

  defp local_naive_iso(utc_iso, zone) do
    {:ok, instant, _offset} = DateTime.from_iso8601(utc_iso)

    case DateTime.shift_zone(instant, zone) do
      {:ok, local} -> local |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
      # Unreachable — the zone was validated up front; degrade to UTC order.
      {:error, _reason} -> utc_iso
    end
  end

  # -- valea event writes -------------------------------------------------------

  # `Local.write/5`'s attrs shape (atom keys; nil/"" optionals dropped by
  # Local's own attrs_to_raw).
  defp event_attrs(arguments) do
    %{
      title: Map.get(arguments, :title),
      start: Map.get(arguments, :start),
      end: Map.get(arguments, :end),
      all_day: Map.get(arguments, :all_day),
      location: Map.get(arguments, :location),
      status: Map.get(arguments, :status),
      description: Map.get(arguments, :description)
    }
  end

  # The channel push contract (spec §RPC surface): the valea-event RPC
  # write paths fire {:calendar_local_changed} on the engines' "calendar"
  # topic — agent-written files need no event (live-read at query time).
  defp broadcast_local_changed do
    Phoenix.PubSub.broadcast(Valea.PubSub, "calendar", {:calendar_local_changed})
  end
end
