defmodule Valea.Calendar.Engine do
  @moduledoc """
  Per-SOURCE calendar sync GenServer (calendar spec F, §Sync engine) — the
  `Valea.Mail.Engine` pattern minus everything two-way. One instance per
  valid source in `config/calendar.yaml`, supervised by
  `Valea.Calendar.Supervisor` and registered under `{:via, Registry,
  {Valea.Calendar.Registry, slug}}` (the Registry lives at the app level —
  see `Valea.Application`).

  ## Activation (the pinned order)

  Engines boot inert and activate off their own generation's
  `{:workspace_opened, info, generation}` broadcast on the `"workspace"`
  topic (or immediately via `activate: true` when rehash-started
  mid-session). Activation runs, IN ORDER:

    1. an unconditional repair ATTEMPT from the committed `feed.ics` — no
       marker consultation, no credential needed. An ATTEMPT, never an
       unconditional commit: the rebuild runs only past the shared
       parse + acceptance admission (see "the guarded derive" below), so a
       damaged on-disk snapshot leaves BOTH derived stores untouched and
       marks the source degraded. This repairs out-of-band damage to
       derived files even when both markers still match;
    2. credential install: the dev/env fallback URL
       (`VALEA_CAL_URL_<SLUG>`) if one is available — RAM-only closure,
       exactly the mail credential posture (a zero-arity closure so no
       state dump ever renders the URL);
    3. ONLY with a URL in hand, `Valea.Calendar.Source.verify_or_claim/2`
       (absent → claim; mismatch → inert `identity_mismatch`). With NO
       URL, `.source` stays untouched and the engine idles with
       `url_present: false` until `set_url/2` resupplies one;
    4. the poll timer starts only when a URL is present and identity
       verified.

  ## The guarded derive

  ONE function (`guarded_derive/5`) serves every snapshot → derived-store
  path — activation, the post-fetch derive, and the 304/marker repair:
  parse → `Ics.acceptable?(feed, Store.occurrence_count(slug) > 0)` (the
  previous-event evidence is ALWAYS the live index count read at guard
  time, never an engine-state counter) → `Views.rebuild!` (views + `.rev`
  swap FIRST) → `Store.replace_source!` (the SQLite transaction SECOND,
  writing `derived_rev`). On parse or guard failure BOTH stores stay
  untouched and the source goes degraded with the reason. The post-fetch
  path runs the admission BEFORE the atomic `feed.ics` swap — a rejected
  response is never committed as the snapshot.

  EVERY pass — including a 304 `:unchanged` — computes the day-quantized
  revision from the CURRENT `feed.ics` bytes plus today's window

      rev = sha256hex(snapshot) <> ":" <> host_zone
            <> ":" <> window_from <> ":" <> window_to

  and re-derives through the same guarded function whenever
  `Views.current_rev/1` OR `Store.derived_rev/1` disagrees — healing
  crashes between the two stores' swaps, failed derives behind 304s,
  host-zone changes, day rollover, and window-config changes, without ever
  letting a damaged snapshot erase a healthy mirror.

  ## The URL is a credential

  Held as a RAM-only zero-arity closure, never written to disk, never in
  any log/error/status/broadcast. A pass task receives the closure and
  resolves it only at the `Fetch.get/3` boundary (the mail pattern);
  `with_credentials/2` instead runs its fun INSIDE the engine process —
  mutually exclusive with a pass — so the closure it hands out in `ctx`
  never crosses a process boundary and the caller only ever sees the fun's
  own return value.

  Clock and zone are injected (`now_fun`/`zone_fun` in the start config)
  so tests never sleep; production uses `DateTime.utc_now/0` and
  `host_zone/0`.
  """

  use GenServer

  alias Valea.Calendar.Ics
  alias Valea.Calendar.Settings
  alias Valea.Calendar.Source
  alias Valea.Calendar.Store
  alias Valea.Calendar.Views

  @typedoc """
  `state` is one of `"inactive"`, `"idle"`, `"syncing"`, `"degraded"`,
  `"identity_mismatch"` (plain `String.t()` — typespecs have no
  singleton-string literals). `invalid_config` is NOT an engine state:
  engines exist only for valid sources; invalid entries are synthesized at
  the API layer from `Settings.load/1`'s `invalid` map.
  `unsupported_series` comes from the LAST SUCCESSFUL derive (0 until one
  happens), updated on EVERY derive including activation and 304
  self-heal re-derives, so "N series unsupported" survives restarts.
  """
  @type status :: %{
          source: String.t(),
          state: String.t(),
          last_sync_at: String.t() | nil,
          last_error: String.t() | nil,
          event_count: non_neg_integer(),
          notices: [String.t()],
          url_present: boolean(),
          unsupported_series: non_neg_integer()
        }

  @doc "The `{:via, Registry, ...}` name a slug's Engine is registered under."
  @spec via(String.t()) :: {:via, Registry, {Valea.Calendar.Registry, String.t()}}
  def via(slug) when is_binary(slug), do: {:via, Registry, {Valea.Calendar.Registry, slug}}

  def start_link(%{source: slug} = cfg),
    do: GenServer.start_link(__MODULE__, cfg, name: via(slug))

  @doc "Current status for `slug`, or `nil` when no Engine is running for it."
  @spec status(String.t()) :: status() | nil
  def status(slug) when is_binary(slug) do
    case whereis(slug) do
      nil -> nil
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc "Every currently-running Engine's status, keyed by source slug."
  @spec statuses() :: %{String.t() => status()}
  def statuses do
    Valea.Calendar.Registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new(fn {slug, pid} -> {slug, GenServer.call(pid, :status)} end)
  end

  @doc """
  Triggers a sync pass immediately (in a monitored Task). `{:error, :busy}`
  while a pass (or a `with_credentials/2` fun) holds the single work slot;
  `{:error, :no_url}` when no usable URL is installed — an inert engine, a
  missing credential, or an unresolved `identity_mismatch`;
  `{:error, :not_running}` when no Engine exists for `slug`.
  """
  @spec sync_now(String.t()) :: :ok | {:error, :busy | :no_url | :not_running}
  def sync_now(slug) when is_binary(slug) do
    case whereis(slug) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :sync_now)
    end
  end

  @doc """
  Installs `url` as `slug`'s feed credential (RAM-only closure).
  `Valea.Calendar.Fetch.validate_url/1` runs FIRST — a non-HTTPS/invalid
  URL is rejected with its typed error BEFORE any closure is stored and
  BEFORE `Source.verify_or_claim/2` runs, so a bad URL can never bind the
  slug's `.source` identity. An identity mismatch equally stores nothing.
  """
  @spec set_url(String.t(), String.t()) :: :ok | {:error, term()}
  def set_url(slug, url) when is_binary(slug) and is_binary(url) do
    case Valea.Calendar.Fetch.validate_url(url) do
      :ok ->
        case whereis(slug) do
          nil -> {:error, :not_running}
          pid -> GenServer.call(pid, {:set_url, url})
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The credential-safe execution seam (the Doctor is the consumer): runs
  `fun` INSIDE the engine process, occupying the single work slot (`:busy`
  while a pass runs, and vice versa). `ctx` is `%{url_fun:, etag:,
  last_modified:, interval_minutes:, last_sync_at:}` — the URL closure
  never crosses a process boundary; the caller receives only the fun's
  return value.
  """
  @spec with_credentials(String.t(), (map() -> result)) ::
          {:ok, result} | {:error, :busy | :no_url | :not_running}
        when result: any()
  def with_credentials(slug, fun) when is_binary(slug) and is_function(fun, 1) do
    case whereis(slug) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:with_credentials, fun}, 60_000)
    end
  end

  @doc """
  The host's IANA zone name: `$TZ` when set and resolvable, else the
  `/etc/localtime` symlink target, else `"Etc/UTC"`. The production
  default for `zone_fun`; evaluated per pass so a zone change re-derives
  via the revision marker.
  """
  @spec host_zone() :: String.t()
  def host_zone do
    [System.get_env("TZ"), localtime_zone()]
    |> Enum.find("Etc/UTC", fn zone ->
      is_binary(zone) and zone != "" and match?({:ok, _}, DateTime.now(zone))
    end)
  end

  defp localtime_zone do
    case File.read_link("/etc/localtime") do
      {:ok, target} ->
        case String.split(target, "zoneinfo/", parts: 2) do
          [_prefix, zone] -> zone
          _no_zoneinfo -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp whereis(slug), do: GenServer.whereis(via(slug))

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(cfg) do
    # Trap exits so the pass task can be LINKED (not just monitored): a
    # Runtime teardown on a workspace switch kills this Engine, and the link
    # kills a task still blocked in a fetch — it can never survive to write
    # the old workspace's rows into the new one (the mail engine posture).
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")

    state = %{
      root: cfg.root,
      generation: cfg.generation,
      source: cfg.source,
      config: cfg.config,
      fetch: Application.get_env(:valea, :calendar_fetch, Valea.Calendar.Fetch),
      now_fun: Map.get(cfg, :now_fun, &DateTime.utc_now/0),
      zone_fun: Map.get(cfg, :zone_fun, &__MODULE__.host_zone/0),
      active: false,
      url_fun: nil,
      verified: false,
      status: "inactive",
      last_sync_at: nil,
      last_error: nil,
      notices: [],
      unsupported_series: 0,
      poll_timer: nil,
      sync_task: nil
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

  # Internal — `Valea.Calendar.Supervisor`'s own rehash diff, not public API.
  def handle_call(:current_config, _from, state), do: {:reply, state.config, state}

  def handle_call(:sync_now, _from, state) do
    case validate_pass(state) do
      :ok -> {:reply, :ok, start_pass(state)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:set_url, url}, _from, state) do
    # Defense-in-depth: the public fn already ran the admission gate.
    with :ok <- Valea.Calendar.Fetch.validate_url(url),
         :ok <- Source.verify_or_claim(source_dir(state), url) do
      new_state =
        %{state | url_fun: fn -> url end, verified: true}
        |> recover_from_mismatch()
        |> arm_if_ready()

      broadcast_status(new_state)
      {:reply, :ok, new_state}
    else
      {:error, :identity_mismatch} = error ->
        # Nothing stored. An engine with no working URL surfaces the
        # mismatch in status; one already polling a verified URL keeps it.
        if state.url_fun == nil do
          new_state = %{state | status: "identity_mismatch"}
          broadcast_status(new_state)
          {:reply, error, new_state}
        else
          {:reply, error, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:with_credentials, fun}, _from, state) do
    cond do
      state.sync_task != nil ->
        {:reply, {:error, :busy}, state}

      state.url_fun == nil ->
        {:reply, {:error, :no_url}, state}

      true ->
        meta = safe_sync_meta(state.source)

        ctx = %{
          url_fun: state.url_fun,
          etag: meta.etag,
          last_modified: meta.last_modified,
          interval_minutes: state.config.interval_minutes,
          last_sync_at: state.last_sync_at
        }

        {:reply, run_credential_fun(fun, ctx), state}
    end
  end

  @impl true
  def handle_info({:workspace_opened, _info, generation}, %{generation: generation} = state) do
    {:noreply, activate(state)}
  end

  def handle_info({:workspace_opened, _info, _other_generation}, state), do: {:noreply, state}
  def handle_info({:workspace_closed}, state), do: {:noreply, state}

  def handle_info(:poll, state), do: {:noreply, state |> maybe_start_pass() |> schedule_poll()}

  # A pass task reported its result: flush the pending :DOWN, apply it.
  def handle_info({:pass_result, pid, result}, %{sync_task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_pass(state, result)}
  end

  # The pass task crashed before reporting (run_pass returns tuples, so this
  # is an unexpected raise/exit) — a failed pass, not a wedge.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{sync_task: {pid, ref}} = state) do
    safe_mark_error(state.source, "sync task crashed")
    {:noreply, finish_pass(state, {:error, "sync task crashed: #{inspect(reason)}"})}
  end

  # Stale task chatter (already handled/superseded): ignore.
  def handle_info({:pass_result, _pid, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # A LINKED pass task exited; the paired monitor's :DOWN drives the result
  # handling (the engine traps exits), so the exit signal itself is a no-op.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # -- activation -------------------------------------------------------------

  defp activate(state) do
    state = %{state | active: true} |> activation_derive()

    url_fun = state.url_fun || env_url(state.source)

    new_state =
      case url_fun do
        nil ->
          # No URL available: `.source` untouched, no timer — idle with
          # url_present: false until set_url resupplies.
          %{state | url_fun: nil, verified: false}

        fun ->
          case Source.verify_or_claim(source_dir(state), fun.()) do
            :ok ->
              %{state | url_fun: fun, verified: true} |> schedule_poll()

            {:error, :identity_mismatch} ->
              # Inert: no polling, no closure kept. The mirror stays as the
              # repair attempt (step 1) left it.
              %{state | url_fun: nil, verified: false, active: false, status: "identity_mismatch"}
          end
      end

    broadcast_status(new_state)
    new_state
  end

  # Activation step 1 — the unconditional repair ATTEMPT from the committed
  # snapshot, through the same guarded admission as every other derive.
  defp activation_derive(state) do
    meta = safe_sync_meta(state.source)
    state = %{state | last_sync_at: meta.last_sync_at}

    case File.read(feed_path(state)) do
      {:error, _no_snapshot} ->
        %{state | status: "idle", last_error: nil}

      {:ok, snapshot} ->
        case safe_guarded_derive(derive_ctx(state), snapshot, meta.etag, meta.last_modified) do
          {:ok, outcome} ->
            %{
              state
              | status: "idle",
                last_error: nil,
                notices: outcome.notices,
                unsupported_series: outcome.unsupported_series
            }

          {:error, reason} ->
            %{state | status: "degraded", last_error: reason}
        end
    end
  end

  # The guarded derive raising (disk full, DB down) must not fell the
  # engine at activation — a supervisor restart loop would follow.
  defp safe_guarded_derive(ctx, snapshot, etag, last_modified) do
    guarded_derive(ctx, snapshot, etag, last_modified, nil)
  rescue
    _error ->
      safe_mark_error(ctx.slug, "derive failed")
      {:error, "derive failed"}
  catch
    :exit, _reason ->
      safe_mark_error(ctx.slug, "derive failed")
      {:error, "derive failed"}
  end

  defp env_url(slug) do
    with url when is_binary(url) and url != "" <- System.get_env(Settings.env_var(slug)),
         :ok <- Valea.Calendar.Fetch.validate_url(url) do
      fn -> url end
    else
      _absent_or_invalid -> nil
    end
  end

  defp recover_from_mismatch(%{status: "identity_mismatch"} = state),
    do: %{state | active: true, status: "idle", last_error: nil}

  defp recover_from_mismatch(state), do: state

  defp arm_if_ready(%{active: true, url_fun: fun, verified: true} = state) when fun != nil,
    do: schedule_poll(state)

  defp arm_if_ready(state), do: state

  # -- pass gating ------------------------------------------------------------

  defp validate_pass(state) do
    cond do
      state.sync_task != nil -> {:error, :busy}
      not state.active -> {:error, :no_url}
      state.url_fun == nil or not state.verified -> {:error, :no_url}
      true -> :ok
    end
  end

  defp maybe_start_pass(state) do
    case validate_pass(state) do
      :ok -> start_pass(state)
      {:error, _reason} -> state
    end
  end

  # Runs the pass in a LINKED + monitored task (see init/1 on why linked).
  # The URL closure travels into the task and is resolved only at the
  # Fetch.get/3 boundary.
  defp start_pass(state) do
    parent = self()

    args = %{
      source: state.source,
      dir: source_dir(state),
      config: state.config,
      url_fun: state.url_fun,
      fetch: state.fetch,
      now_fun: state.now_fun,
      zone_fun: state.zone_fun
    }

    pid = spawn_link(fn -> send(parent, {:pass_result, self(), run_pass(args)}) end)
    ref = Process.monitor(pid)

    new_state = %{state | sync_task: {pid, ref}, status: "syncing"}
    broadcast_status(new_state)
    new_state
  end

  defp finish_pass(state, {:ok, outcome}) do
    state = %{state | sync_task: nil, status: "idle", last_sync_at: now_iso(), last_error: nil}

    state =
      case outcome do
        %{derived: true} = info ->
          %{state | notices: info.notices, unsupported_series: info.unsupported_series}

        :unchanged ->
          state
      end

    broadcast_event({:calendar_synced, state.source, %{event_count: safe_count(state.source)}})
    broadcast_status(state)
    state
  end

  defp finish_pass(state, {:error, reason}) do
    state = %{state | sync_task: nil, status: "degraded", last_error: reason}
    broadcast_status(state)
    state
  end

  # -- the pass ---------------------------------------------------------------

  # Runs inside the task. Every failure is a plain reason string with the
  # URL structurally absent (Fetch returns typed atoms; paths carry only
  # the slug); the crash path additionally scrubs the URL as
  # defense-in-depth before the message can reach status or a broadcast.
  defp run_pass(args) do
    ctx = derive_ctx(args)
    meta = safe_sync_meta(args.source)

    case args.fetch.get(args.url_fun.(), meta.etag, meta.last_modified) do
      {:ok, %{body: body, etag: etag, last_modified: last_modified}} ->
        # Admission runs INSIDE guarded_derive BEFORE the commit hook swaps
        # feed.ics — a rejected response is never committed.
        case guarded_derive(ctx, body, etag, last_modified, &commit_snapshot!(ctx.dir, &1)) do
          {:ok, outcome} -> {:ok, outcome}
          {:error, _reason} = error -> error
        end

      :unchanged ->
        marker_repair(ctx, meta)

      {:error, reason} ->
        message = "fetch failed: #{fetch_reason(reason)}"
        safe_mark_error(args.source, message)
        {:error, message}
    end
  rescue
    error ->
      message = scrub("pass crashed: " <> Exception.message(error), args.url_fun)
      safe_mark_error(args.source, message)
      {:error, message}
  catch
    :exit, _reason ->
      safe_mark_error(args.source, "pass crashed")
      {:error, "pass crashed"}
  end

  # The 304 path: EVERY pass runs the marker check — compute today's rev
  # from the CURRENT feed.ics bytes; any mismatch in EITHER store repairs
  # through the same guarded derive (which can reject a damaged snapshot,
  # leaving both stores untouched and the source degraded).
  defp marker_repair(ctx, meta) do
    case File.read(Path.join(ctx.dir, "feed.ics")) do
      {:error, _no_snapshot} ->
        {:ok, :unchanged}

      {:ok, snapshot} ->
        rev = rev(snapshot, ctx)

        if Views.current_rev(ctx.dir) == rev and safe_derived_rev(ctx.slug) == rev do
          {:ok, :unchanged}
        else
          guarded_derive(ctx, snapshot, meta.etag, meta.last_modified, nil)
        end
    end
  end

  # THE one guarded derive (moduledoc, "The guarded derive"): parse →
  # acceptance guard against the LIVE index count → optional post-admission
  # snapshot commit (the post-fetch path's feed.ics swap) → views + .rev
  # swap FIRST → SQLite transaction SECOND.
  defp guarded_derive(ctx, snapshot, etag, last_modified, commit_fun) do
    with {:ok, feed} <- Ics.parse(snapshot),
         :ok <- Ics.acceptable?(feed, safe_count(ctx.slug) > 0) do
      if commit_fun, do: commit_fun.(snapshot)

      rev = rev(snapshot, ctx)
      result = Views.rebuild!(ctx.dir, ctx.slug, feed, rev, ctx.window, ctx.zone)
      Store.replace_source!(ctx.slug, result.rows, rev, etag, last_modified)

      {:ok,
       %{
         derived: true,
         event_count: length(result.rows),
         notices: feed.notices ++ result.notices,
         unsupported_series: result.unsupported_series
       }}
    else
      {:error, guard_reason} ->
        message = derive_reason(guard_reason)
        safe_mark_error(ctx.slug, message)
        {:error, message}
    end
  end

  # tmp + fsync + rename — the atomic snapshot commit point.
  defp commit_snapshot!(dir, bytes) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "feed.ics")
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    File.write!(tmp, bytes)
    File.open!(tmp, [:binary], fn file -> :file.datasync(file) end)
    File.rename!(tmp, path)
    :ok
  end

  defp derive_reason(:not_ics), do: "response is not an ICS calendar"

  defp derive_reason(:zero_parseable),
    do: "feed has zero parseable events where the previous snapshot had events"

  defp derive_reason(:too_many_malformed), do: "too many malformed VEVENTs in the response"

  defp fetch_reason({:http, status}), do: "http #{status}"
  defp fetch_reason(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp fetch_reason(other), do: inspect(other)

  # -- rev / window -----------------------------------------------------------

  # Works over both the engine state and the pass task args: both carry
  # `source`, `config`, `now_fun`, `zone_fun`, and a way to the source dir.
  defp derive_ctx(holder) do
    zone = holder.zone_fun.()
    today = today(holder.now_fun.(), zone)
    config = holder.config

    %{
      slug: holder.source,
      dir: dir_of(holder),
      zone: zone,
      window: {Date.add(today, -config.past_days), Date.add(today, config.future_days)}
    }
  end

  defp dir_of(%{dir: dir}), do: dir
  defp dir_of(%{root: root, source: slug}), do: Path.join([root, "sources", "calendar", slug])

  defp today(%DateTime{} = now, zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> DateTime.to_date(now)
    end
  end

  defp rev(snapshot, ctx) do
    {from, to} = ctx.window

    Base.encode16(:crypto.hash(:sha256, snapshot), case: :lower) <>
      ":" <> ctx.zone <> ":" <> Date.to_iso8601(from) <> ":" <> Date.to_iso8601(to)
  end

  # -- credential seam --------------------------------------------------------

  # A raising fun must not fell the engine (the RAM-only closure would die
  # with it); degrade to a typed error that carries nothing of the URL.
  defp run_credential_fun(fun, ctx) do
    {:ok, fun.(ctx)}
  rescue
    _error -> {:error, :fun_crashed}
  catch
    :exit, _reason -> {:error, :fun_crashed}
  end

  # -- rescued store reads ----------------------------------------------------

  # Status/derive paths must never crash the engine over Repo state (the
  # mail store_snapshot posture — the Repo is not a Runtime child).
  defp safe_count(slug) do
    Store.occurrence_count(slug)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp safe_derived_rev(slug) do
    Store.derived_rev(slug)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_sync_meta(slug) do
    Store.sync_meta(slug) || empty_meta()
  rescue
    _ -> empty_meta()
  catch
    :exit, _ -> empty_meta()
  end

  defp empty_meta, do: %{etag: nil, last_modified: nil, last_sync_at: nil, last_error: nil}

  defp safe_mark_error(slug, reason) do
    Store.mark_error(slug, reason)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # -- scrubbing --------------------------------------------------------------

  # Defense-in-depth: no path builds messages from the URL, but a crash
  # message could theoretically embed it — scrub before it can reach
  # status/broadcast surfaces.
  defp scrub(message, url_fun) when is_function(url_fun, 0),
    do: String.replace(message, url_fun.(), "[url]")

  defp scrub(message, _no_url), do: message

  # -- poll timer -------------------------------------------------------------

  defp schedule_poll(state) do
    cancel_timer(state.poll_timer)
    timer = Process.send_after(self(), :poll, state.config.interval_minutes * 60_000)
    %{state | poll_timer: timer}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # -- status / broadcasts ----------------------------------------------------

  defp source_dir(state), do: Path.join([state.root, "sources", "calendar", state.source])
  defp feed_path(state), do: Path.join(source_dir(state), "feed.ics")

  defp build_status(state) do
    %{
      source: state.source,
      state: state.status,
      last_sync_at: state.last_sync_at,
      last_error: state.last_error,
      event_count: safe_count(state.source),
      notices: state.notices,
      url_present: state.url_fun != nil,
      unsupported_series: state.unsupported_series
    }
  end

  defp broadcast_status(state) do
    broadcast_event({:calendar_status_changed, state.source, build_status(state)})
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "calendar", event)
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
