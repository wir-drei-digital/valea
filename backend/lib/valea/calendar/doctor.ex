defmodule Valea.Calendar.Doctor do
  @moduledoc """
  Connection preflight for one calendar source (calendar spec F, §Doctor)
  — the `Valea.Mail.Doctor` shape: a fixed, SEQUENTIAL check pipeline
  where a failure marks every gated check after it `"unknown"` rather
  than attempting work that cannot meaningfully run.

  Check ids, in order:

    1. `config_present` — does `config/calendar.yaml` carry a VALID entry
       for this source (`Valea.Calendar.Settings.load/1`)? An invalid
       entry or an invalid/absent file fails with the load reason.
    2. `url_present` — is a feed URL installed in the source's running
       engine (RAM-only closure; keychain- or env-supplied)? Gated on 1.
       A source with NO running engine fails here with the resupply
       remedy — checks after a failed gate don't run.
    3. `reachable` — a conditional GET through the engine's
       credential-safe seam (below), reporting the HTTP status class /
       TLS outcome. Gated on 2.
    4. `parse_ok` — parseable-event count + per-component notices, from
       the 200 body (or, on a 304, the committed `feed.ics` snapshot —
       that IS the current feed content). Gated on 3.
    5. `freshness` — the age of the last successful sync vs 2× the
       source's poll interval ("wedged poller on a reachable feed").
       Gated on 4. The value compared is the ENGINE's in-memory
       `last_sync_at` (via the `with_credentials` ctx) — never
       `Store.sync_meta/1`'s DB column, which no-network repair derives
       pollute (`Store.replace_source!/5` stamps it on every re-derive).
    6. `feed_endpoint` — the SERVED feed: a token is configured and the
       loopback `/calendar/feed.ics` route answers a self-request.
       Independent of the per-source chain (it belongs to the setup
       panel's feed block), so it always runs.

  ## The URL is a credential

  The network checks run INSIDE `Valea.Calendar.Engine.with_credentials/2`
  — the Doctor never reads the keychain/env itself, and the URL closure
  never crosses a process boundary. `with_credentials/2` returns
  `{:error, :busy | :no_url | :not_running}` (plus `:fun_crashed` as its
  own belt-and-braces) — every one maps to a check outcome here, never a
  raise. The fun body carries its own try/rescue because the engine
  intentionally does NOT surface a crashed fun's reason; the rescue
  additionally scrubs the URL and its host out of any exception message.
  NO check detail/remedy/error string ever carries the URL, its host, or
  the feed token — a dedicated test greps the full output for both.

  The engine's status (for `url_present`) is gathered BEFORE the
  `with_credentials/2` call — `Engine.status/1` is a GenServer call into
  the same engine process the doctor fun occupies, so calling it from
  inside would deadlock until the 5s call timeout.
  """

  alias Valea.Calendar.Engine
  alias Valea.Calendar.Ics
  alias Valea.Calendar.Settings

  @type check :: %{String.t() => String.t() | nil}

  @typedoc """
  `root`/`source` are required. Optional seams: `fetch` (defaults to the
  `:calendar_fetch` app env, the engine's own seam), `feed_probe` (the
  loopback self-request, defaults to a real `:httpc` GET against the
  endpoint's configured port), `now_fun` (freshness clock).
  """
  @type ctx :: %{
          required(:root) => String.t(),
          required(:source) => String.t(),
          optional(:fetch) => module(),
          optional(:feed_probe) => (-> :ok | {:error, term()}),
          optional(:now_fun) => (-> DateTime.t())
        }

  @gate_detail "not checked — an earlier check failed."

  @config_label "Source configured"
  @url_label "Feed URL available"
  @reachable_label "Feed reachable"
  @parse_label "Feed parses"
  @freshness_label "Sync freshness"
  @feed_label "Served feed endpoint"

  @config_remedy "Add the source (slug + name) in Calendar settings."
  @resupply_remedy "Paste the source's secret ICS address in Calendar settings to resupply the feed URL."
  @busy_remedy "A sync pass is running for this source — wait for it to finish, then run the doctor again."
  @network_remedy "Check your network connection, then try again."
  @revoked_remedy "The feed address may have been revoked — generate a fresh secret address with your provider and paste it again."
  @missing_remedy "The feed no longer exists at this address — paste the provider's current subscription URL."
  @provider_remedy "The provider answered with a server error — try again later."
  @tls_remedy "The feed host's TLS certificate could not be verified — check the address with your provider."
  @parse_remedy "The address is not serving an ICS calendar — paste the provider's ICS subscription URL."
  @never_synced_remedy "Trigger \"Sync now\" for this source."
  @wedged_remedy "The poller looks wedged — trigger \"Sync now\", or restart Valea if it stays stale."
  @enable_remedy "Enable the calendar feed in Calendar settings to generate a subscription token."
  @probe_remedy "Make sure Valea's local server is running, then try again."

  @probe_timeout_ms 5_000

  @doc """
  Runs the full pipeline against `ctx`. Always returns `{:ok, ...}` — the
  `ok:` flag (every check `"ok"`) is how a caller learns whether anything
  is wrong; see the moduledoc for the gating rule.
  """
  @spec run(ctx()) :: {:ok, %{checks: [check()], ok: boolean()}}
  def run(%{root: root, source: source} = ctx) when is_binary(root) and is_binary(source) do
    {config, config_ok?} = config_present(ctx)

    # Engine.status/1 runs BEFORE with_credentials/2 occupies the engine
    # (see the moduledoc) — its url_present is exactly the RAM-closure
    # presence the url_present check reports.
    status = if config_ok?, do: safe_status(source), else: nil

    {url, url_ok?} = url_present(status, config_ok?)
    {reachable, parse, freshness} = network_group(ctx, url_ok?)
    feed = feed_endpoint(ctx)

    checks = [config, url, reachable, parse, freshness, feed]
    {:ok, %{checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
  end

  # -- 1. config_present ------------------------------------------------------

  defp config_present(%{root: root, source: source}) do
    case Settings.load(root) do
      {:ok, %Settings{sources: sources, invalid: invalid}} ->
        cond do
          Map.has_key?(sources, source) ->
            {ok(
               "config_present",
               @config_label,
               "config/calendar.yaml has a valid entry for this source."
             ), true}

          Map.has_key?(invalid, source) ->
            {failed(
               "config_present",
               @config_label,
               "The source's config entry is invalid: #{invalid[source]}",
               @config_remedy
             ), false}

          true ->
            {failed(
               "config_present",
               @config_label,
               "config/calendar.yaml has no entry for this source.",
               @config_remedy
             ), false}
        end

      {:error, :absent} ->
        {failed(
           "config_present",
           @config_label,
           "config/calendar.yaml is missing.",
           @config_remedy
         ), false}

      {:error, {:invalid, reason}} ->
        {failed(
           "config_present",
           @config_label,
           "config/calendar.yaml is invalid: #{reason}",
           @config_remedy
         ), false}
    end
  end

  # -- 2. url_present ---------------------------------------------------------

  defp url_present(_status, false) do
    {unknown("url_present", @url_label, @gate_detail), false}
  end

  defp url_present(nil, true) do
    {failed(
       "url_present",
       @url_label,
       "No sync engine is running for this source (it may still be starting, or the workspace needs re-opening).",
       @resupply_remedy
     ), false}
  end

  defp url_present(%{url_present: true}, true) do
    {ok("url_present", @url_label, "A feed URL is installed (held in RAM only)."), true}
  end

  defp url_present(%{url_present: false} = status, true) do
    detail =
      case status.state do
        "identity_mismatch" ->
          "The supplied URL did not match this source's recorded identity (.source) — resolved by purging the source's files."

        _no_url_yet ->
          "No feed URL has been supplied since the app started."
      end

    {failed("url_present", @url_label, detail, @resupply_remedy), false}
  end

  # -- 3/4/5. reachable + parse_ok + freshness (one with_credentials run) -----

  defp network_group(_ctx, false) do
    {unknown("reachable", @reachable_label, @gate_detail),
     unknown("parse_ok", @parse_label, @gate_detail),
     unknown("freshness", @freshness_label, @gate_detail)}
  end

  defp network_group(ctx, true) do
    fetch =
      Map.get(ctx, :fetch) || Application.get_env(:valea, :calendar_fetch, Valea.Calendar.Fetch)

    now_fun = Map.get(ctx, :now_fun, &DateTime.utc_now/0)
    feed_path = Path.join([ctx.root, "sources", "calendar", ctx.source, "feed.ics"])

    case Engine.with_credentials(ctx.source, &probe_feed(&1, fetch, feed_path, now_fun)) do
      {:ok, {reachable, parse, freshness}} ->
        {reachable, parse, freshness}

      {:error, :busy} ->
        {failed(
           "reachable",
           @reachable_label,
           "The source's engine is busy with a sync pass.",
           @busy_remedy
         ), unknown("parse_ok", @parse_label, @gate_detail),
         unknown("freshness", @freshness_label, @gate_detail)}

      {:error, :no_url} ->
        # Raced away between the status read and this call (e.g. an engine
        # restart) — same condition url_present reports.
        {failed("reachable", @reachable_label, "The engine lost its feed URL.", @resupply_remedy),
         unknown("parse_ok", @parse_label, @gate_detail),
         unknown("freshness", @freshness_label, @gate_detail)}

      {:error, :not_running} ->
        {failed(
           "reachable",
           @reachable_label,
           "No sync engine is running for this source.",
           @resupply_remedy
         ), unknown("parse_ok", @parse_label, @gate_detail),
         unknown("freshness", @freshness_label, @gate_detail)}

      {:error, :fun_crashed} ->
        # The engine intentionally withholds the crash reason; our own
        # rescue inside probe_feed/4 normally reports (and scrubs) it first.
        {failed("reachable", @reachable_label, "The doctor probe crashed.", @network_remedy),
         unknown("parse_ok", @parse_label, @gate_detail),
         unknown("freshness", @freshness_label, @gate_detail)}
    end
  end

  # Runs INSIDE the engine process (the with_credentials fun). `cred` is
  # `%{url_fun:, etag:, last_modified:, interval_minutes:, last_sync_at:}`.
  defp probe_feed(cred, fetch, feed_path, now_fun) do
    case fetch.get(cred.url_fun.(), cred.etag, cred.last_modified) do
      {:ok, %{body: body}} ->
        {ok("reachable", @reachable_label, "HTTP 200 — the feed responded."),
         gated_parse_and_freshness(parse_check(body), cred, now_fun)}
        |> flatten_network()

      :unchanged ->
        {ok(
           "reachable",
           @reachable_label,
           "HTTP 304 — the feed is unchanged since the last successful sync."
         ), gated_parse_and_freshness(snapshot_parse_check(feed_path), cred, now_fun)}
        |> flatten_network()

      {:error, reason} ->
        {reachable_failure(reason), unknown("parse_ok", @parse_label, @gate_detail),
         unknown("freshness", @freshness_label, @gate_detail)}
    end
  rescue
    error ->
      {failed(
         "reachable",
         @reachable_label,
         scrub("The probe crashed: " <> Exception.message(error), cred),
         @network_remedy
       ), unknown("parse_ok", @parse_label, @gate_detail),
       unknown("freshness", @freshness_label, @gate_detail)}
  catch
    :exit, reason ->
      {failed(
         "reachable",
         @reachable_label,
         scrub("The probe exited: " <> inspect(reason), cred),
         @network_remedy
       ), unknown("parse_ok", @parse_label, @gate_detail),
       unknown("freshness", @freshness_label, @gate_detail)}
  end

  defp gated_parse_and_freshness({parse, parse_ok?}, cred, now_fun) do
    freshness =
      if parse_ok? do
        freshness_check(cred, now_fun)
      else
        unknown("freshness", @freshness_label, @gate_detail)
      end

    {parse, freshness}
  end

  defp flatten_network({reachable, {parse, freshness}}), do: {reachable, parse, freshness}

  # -- reachable failure mapping ----------------------------------------------

  # Typed atoms only (Valea.Calendar.Fetch's pinned error union) — no
  # reason term from the transport ever reaches a detail string.
  defp reachable_failure({:http, status}) do
    remedy =
      cond do
        status in [401, 403] -> @revoked_remedy
        status == 404 -> @missing_remedy
        status >= 500 -> @provider_remedy
        true -> @network_remedy
      end

    failed("reachable", @reachable_label, "The feed answered HTTP #{status}.", remedy)
  end

  defp reachable_failure(:tls),
    do: failed("reachable", @reachable_label, "The TLS handshake failed.", @tls_remedy)

  defp reachable_failure(:timeout),
    do:
      failed(
        "reachable",
        @reachable_label,
        "Could not reach the feed host (unresolvable, refused, or timed out).",
        @network_remedy
      )

  defp reachable_failure(:ssrf_blocked),
    do:
      failed(
        "reachable",
        @reachable_label,
        "The feed host resolves to a private or reserved address, which the fetcher refuses.",
        "Use a feed hosted on a public address."
      )

  defp reachable_failure(other) when is_atom(other),
    do: failed("reachable", @reachable_label, "The fetch failed: #{other}.", @network_remedy)

  defp reachable_failure(other),
    do:
      failed(
        "reachable",
        @reachable_label,
        "The fetch failed: #{inspect(other)}.",
        @network_remedy
      )

  # -- 4. parse_ok ------------------------------------------------------------

  defp parse_check(body) do
    case Ics.parse(body) do
      {:ok, feed} ->
        count = length(feed.events)

        if count == 0 and feed.notices != [] do
          {failed(
             "parse_ok",
             @parse_label,
             "Zero parseable events — #{length(feed.notices)} component notice(s): #{notice_summary(feed.notices)}",
             @parse_remedy
           ), false}
        else
          {ok("parse_ok", @parse_label, parse_detail(count, feed.notices)), true}
        end

      {:error, :not_ics} ->
        {failed("parse_ok", @parse_label, "The response is not an ICS calendar.", @parse_remedy),
         false}
    end
  end

  # The 304 leg: the committed snapshot IS the current feed content.
  defp snapshot_parse_check(feed_path) do
    case File.read(feed_path) do
      {:ok, snapshot} ->
        parse_check(snapshot)

      {:error, _reason} ->
        {failed(
           "parse_ok",
           @parse_label,
           "The feed answered 304 but no committed snapshot exists on disk.",
           @never_synced_remedy
         ), false}
    end
  end

  defp parse_detail(count, []), do: "#{count} parseable event(s)."

  defp parse_detail(count, notices) do
    "#{count} parseable event(s); #{length(notices)} notice(s): #{notice_summary(notices)}"
  end

  # Notices are already sanitized by the parser/views (printable ASCII,
  # truncated) and never carry the URL; keep the detail bounded anyway.
  defp notice_summary(notices) do
    notices |> Enum.take(3) |> Enum.join("; ")
  end

  # -- 5. freshness -----------------------------------------------------------

  defp freshness_check(%{last_sync_at: nil}, _now_fun) do
    failed(
      "freshness",
      @freshness_label,
      "This source has not completed a successful sync since the app started.",
      @never_synced_remedy
    )
  end

  defp freshness_check(%{last_sync_at: last_sync_at, interval_minutes: interval}, now_fun) do
    case DateTime.from_iso8601(last_sync_at) do
      {:ok, last_dt, _offset} ->
        age_minutes = div(DateTime.diff(now_fun.(), last_dt, :second), 60)

        if age_minutes <= 2 * interval do
          ok("freshness", @freshness_label, "Last successful sync #{age_minutes} minute(s) ago.")
        else
          failed(
            "freshness",
            @freshness_label,
            "Last successful sync #{age_minutes} minute(s) ago — more than twice the #{interval}-minute poll interval.",
            @wedged_remedy
          )
        end

      {:error, _reason} ->
        failed(
          "freshness",
          @freshness_label,
          "The last-sync timestamp is unreadable.",
          @never_synced_remedy
        )
    end
  end

  # -- 6. feed_endpoint -------------------------------------------------------

  defp feed_endpoint(ctx) do
    case Settings.load(ctx.root) do
      {:ok, %Settings{feed_token_hash: hash}} when is_binary(hash) ->
        case run_probe(Map.get(ctx, :feed_probe, &default_feed_probe/0)) do
          :ok ->
            ok(
              "feed_endpoint",
              @feed_label,
              "A feed token is configured and /calendar/feed.ics is answering on loopback."
            )

          {:error, reason} ->
            failed(
              "feed_endpoint",
              @feed_label,
              "A feed token is configured but the loopback route did not answer (#{probe_reason(reason)}).",
              @probe_remedy
            )
        end

      _absent_invalid_or_tokenless ->
        failed(
          "feed_endpoint",
          @feed_label,
          "The served calendar feed is not enabled — no token is configured.",
          @enable_remedy
        )
    end
  end

  defp run_probe(probe) when is_function(probe, 0) do
    probe.()
  rescue
    _error -> {:error, :probe_crashed}
  catch
    :exit, _reason -> {:error, :probe_crashed}
  end

  # A real loopback self-request against the endpoint's configured port,
  # with a deliberately-bogus token: ANY HTTP answer (the expected 404
  # included) proves the route is up — the doctor never holds the plain
  # token (only its hash is ever persisted), so an authenticated request
  # is structurally impossible. Connection-level failures are collapsed to
  # `:unreachable` — no reason term (which could embed the request URL,
  # secret-free as it is here) reaches a detail string.
  defp default_feed_probe do
    {:ok, _apps} = Application.ensure_all_started([:inets])

    port = ValeaWeb.Endpoint.config(:http)[:port]
    url = ~c"http://127.0.0.1:#{port}/calendar/feed.ics?token=valea-doctor-probe"

    case :httpc.request(
           :get,
           {url, []},
           [timeout: @probe_timeout_ms, connect_timeout: @probe_timeout_ms],
           body_format: :binary
         ) do
      {:ok, {{_version, _status, _phrase}, _headers, _body}} -> :ok
      {:error, _reason} -> {:error, :unreachable}
    end
  rescue
    _error -> {:error, :unreachable}
  catch
    :exit, _reason -> {:error, :unreachable}
  end

  defp probe_reason(reason) when is_atom(reason), do: to_string(reason)
  defp probe_reason(reason), do: inspect(reason)

  # -- helpers ----------------------------------------------------------------

  # Engine.status/1 can exit if the engine dies between the Registry lookup
  # and the call — the doctor treats that exactly like "not running".
  defp safe_status(source) do
    Engine.status(source)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  # Defense-in-depth for the rescue paths: an exception message could
  # theoretically embed the URL — scrub the full URL and its host before
  # the message can reach a check detail. Runs inside the engine process,
  # where the closure is legitimately in hand.
  defp scrub(message, cred) do
    url = cred.url_fun.()

    host =
      case URI.new(url) do
        {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host
        _no_host -> nil
      end

    message = String.replace(message, url, "[url]")
    if host, do: String.replace(message, host, "[host]"), else: message
  end

  # -- check builders ---------------------------------------------------------

  defp ok(id, label, detail),
    do: %{"id" => id, "label" => label, "status" => "ok", "detail" => detail, "remedy" => nil}

  defp failed(id, label, detail, remedy),
    do: %{
      "id" => id,
      "label" => label,
      "status" => "failed",
      "detail" => detail,
      "remedy" => remedy
    }

  defp unknown(id, label, detail),
    do: %{
      "id" => id,
      "label" => label,
      "status" => "unknown",
      "detail" => detail,
      "remedy" => nil
    }
end
