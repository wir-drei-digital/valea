defmodule Valea.Calendar.Fetch do
  @moduledoc """
  Minimal pinned HTTPS GET for ICS subscription feeds (calendar spec
  §Fetching), built on `:httpc` in async/streaming mode. Pinned behavior:

    * **HTTPS only.** `validate_url/1` is THE one URL admission gate
      (parseable URI, scheme `https`, non-empty host) — Task 3's
      `Engine.set_url` and Task 6's `set_calendar_source_url` run it
      BEFORE any keychain write, engine state, or `.source` identity
      claim. `get/4` re-checks the same gate on entry and on every
      redirect target.
    * **TLS is mandatory and verified** — `verify: :verify_peer`,
      hostname check, SNI, CA trust via the OS-provided
      `:public_key.cacerts_get/0`, exactly `Valea.Mail.ImapClient`'s
      posture including the one sanctioned override: tests inject the
      fixture CA via `opts[:tls_opts]`, which must never be used to
      weaken or disable `verify_peer`.
    * **Manual redirects** (`autoredirect: false`), cap 3, SAME-ORIGIN
      only (scheme + host + port) — a cross-origin redirect fails the
      pass with `:cross_origin_redirect` before the target is ever
      resolved or contacted.
    * **SSRF gate before EVERY connect** (initial + each redirect hop):
      the host's resolved addresses are checked and loopback,
      link-local, RFC 1918/ULA, and reserved ranges (IPv4 + IPv6,
      including v4-mapped/v4-compatible/NAT64 embeddings) are rejected
      as `:ssrf_blocked`. Residual risk, accepted and documented in the
      spec: a DNS-rebinding host can still race this check against the
      connect's own second resolution.
    * **Body cap 20 MB**, enforced twice: a declared `content-length`
      over the cap is rejected before any body bytes are read, and the
      streamed body is aborted mid-download the moment it exceeds the
      cap.
    * **Timeout 30 s** as ONE overall deadline across the whole redirect
      chain.
    * **Conditional GET** via `If-None-Match`/`If-Modified-Since`; a 304
      ends the pass with `:unchanged`.

  ## The URL is a credential

  A feed URL embeds a private token (Google's "secret address"), so it
  must never appear in logs, error strings, or exceptions from this
  module. Every failure is one of the typed atoms in `get/4`'s spec —
  no reason term from `:httpc`/`:ssl` (which could embed request
  context) ever escapes: TLS-layer failures collapse to `:tls`, and
  every other transport failure (refused, closed, unresolvable host,
  ...) collapses to `:timeout`, the generic could-not-reach atom the
  sync engine treats as retryable. This module logs nothing.

  ## Test-only options

  `opts` exists for the test seams only (the FakeFeedServer binds
  loopback and mostly speaks plain HTTP): `:tls_opts` (fixture CA,
  merged like ImapClient's), `:allow_http` (admit `http://`),
  `:allow_loopback` (exempt loopback — and only loopback — from the
  SSRF gate), `:timeout` and `:max_body_bytes` (scaled-down pins).
  Production callers pass no opts.
  """

  import Bitwise

  @timeout 30_000
  @max_body_bytes 20 * 1024 * 1024
  @redirect_cap 3
  @redirect_statuses [301, 302, 303, 307, 308]

  @type get_error ::
          :not_https
          | :ssrf_blocked
          | :cross_origin_redirect
          | :redirect_limit
          | :too_large
          | :timeout
          | :tls
          | {:http, pos_integer()}

  @doc """
  The one URL admission gate: parseable URI, scheme `"https"`, non-empty
  host. Anything else never reaches a keychain, engine, or `.source`
  claim.
  """
  @spec validate_url(String.t()) :: :ok | {:error, :not_https | :invalid_url}
  def validate_url(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        :ok

      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme not in ["https"] ->
        {:error, :not_https}

      _ ->
        {:error, :invalid_url}
    end
  end

  def validate_url(_url), do: {:error, :invalid_url}

  @doc """
  Conditional GET of `url`. `etag`/`last_modified` are the validators
  from the previous successful fetch (or `nil`); a 304 returns
  `:unchanged`, a 200 returns the body plus this response's validators.
  Every failure is a typed atom — see the moduledoc.
  """
  @spec get(String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, %{body: binary(), etag: String.t() | nil, last_modified: String.t() | nil}}
          | :unchanged
          | {:error, get_error()}
  def get(url, etag, last_modified, opts \\ []) when is_binary(url) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    timeout = Keyword.get(opts, :timeout, @timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    case admit(url, opts) do
      {:ok, uri} -> run(uri, uri, etag, last_modified, opts, deadline, 0)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The SSRF address classifier — `true` when `addr` (an
  `:inet.ip_address/0` tuple) must never be connected to: IPv4
  loopback/link-local/RFC 1918/CGNAT/reserved/multicast, IPv6
  loopback/unspecified/link-local/ULA/multicast/documentation, and every
  v4-mapped, v4-compatible, or NAT64 form classified by its embedded
  IPv4 address. Strict — the loopback test seam lives in the caller,
  never here.
  """
  @spec blocked_address?(:inet.ip_address()) :: boolean()
  def blocked_address?({a, b, c, _d})
      when a in 0..255 and b in 0..255 and c in 0..255 do
    cond do
      a == 0 -> true
      a == 10 -> true
      a == 100 and b in 64..127 -> true
      a == 127 -> true
      a == 169 and b == 254 -> true
      a == 172 and b in 16..31 -> true
      a == 192 and b == 168 -> true
      a == 192 and b == 0 and c in [0, 2] -> true
      a == 198 and b in [18, 19] -> true
      a == 198 and b == 51 and c == 100 -> true
      a == 203 and b == 0 and c == 113 -> true
      a >= 224 -> true
      true -> false
    end
  end

  def blocked_address?({w1, w2, w3, w4, w5, w6, w7, w8} = addr)
      when w1 in 0..65_535 and w8 in 0..65_535 do
    cond do
      addr == {0, 0, 0, 0, 0, 0, 0, 0} ->
        true

      addr == {0, 0, 0, 0, 0, 0, 0, 1} ->
        true

      # ::ffff:a.b.c.d — v4-mapped: classify the embedded IPv4
      {w1, w2, w3, w4, w5} == {0, 0, 0, 0, 0} and w6 == 0xFFFF ->
        blocked_address?(embedded_v4(w7, w8))

      # ::a.b.c.d — deprecated v4-compatible: fail closed
      {w1, w2, w3, w4, w5, w6} == {0, 0, 0, 0, 0, 0} ->
        true

      # 64:ff9b::/96 — NAT64 well-known prefix: classify the embedded IPv4
      {w1, w2, w3, w4, w5, w6} == {0x64, 0xFF9B, 0, 0, 0, 0} ->
        blocked_address?(embedded_v4(w7, w8))

      # fe80::/10 link-local
      (w1 &&& 0xFFC0) == 0xFE80 ->
        true

      # fc00::/7 unique-local
      (w1 &&& 0xFE00) == 0xFC00 ->
        true

      # ff00::/8 multicast
      (w1 &&& 0xFF00) == 0xFF00 ->
        true

      # 2001:db8::/32 documentation
      w1 == 0x2001 and w2 == 0x0DB8 ->
        true

      true ->
        false
    end
  end

  defp embedded_v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  # -- admission (scheme gate, shared by the entry URL and every redirect) ---

  # `get/4`'s error union has no `:invalid_url` — real callers ran
  # `validate_url/1` at setup, so a URL failing to parse here maps to the
  # scheme-gate atom rather than growing the union.
  defp admit(url, opts) do
    allowed_schemes =
      if Keyword.get(opts, :allow_http, false), do: ["https", "http"], else: ["https"]

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if scheme in allowed_schemes, do: {:ok, uri}, else: {:error, :not_https}

      _ ->
        {:error, :not_https}
    end
  end

  # -- the redirect-following request loop -----------------------------------

  defp run(uri, origin, etag, last_modified, opts, deadline, redirects) do
    with :ok <- ssrf_gate(uri.host, opts),
         {:ok, remaining} <- remaining(deadline),
         {:ok, outcome} <- request(uri, etag, last_modified, opts, remaining, deadline) do
      case outcome do
        {:success, body, resp_etag, resp_last_modified} ->
          {:ok, %{body: body, etag: resp_etag, last_modified: resp_last_modified}}

        :unchanged ->
          :unchanged

        {:redirect, location} ->
          follow(location, uri, origin, etag, last_modified, opts, deadline, redirects)
      end
    end
  end

  defp follow(location, current, origin, etag, last_modified, opts, deadline, redirects) do
    cond do
      redirects >= @redirect_cap ->
        {:error, :redirect_limit}

      location == nil ->
        {:error, :cross_origin_redirect}

      true ->
        target = current |> URI.merge(location) |> normalize_port()

        case admit(URI.to_string(target), opts) do
          {:ok, target} ->
            if same_origin?(target, origin) do
              run(target, origin, etag, last_modified, opts, deadline, redirects + 1)
            else
              {:error, :cross_origin_redirect}
            end

          {:error, _reason} ->
            # A redirect to a scheme we would not admit (http downgrade,
            # ftp, ...) is by definition not this origin.
            {:error, :cross_origin_redirect}
        end
    end
  end

  # `URI.merge/2` keeps an explicit port and leaves an implicit one `nil`;
  # `URI.parse/1`-style default-port filling makes `https://h/` and
  # `https://h:443/` compare equal.
  defp normalize_port(%URI{port: nil, scheme: scheme} = uri),
    do: %URI{uri | port: URI.default_port(scheme)}

  defp normalize_port(uri), do: uri

  defp same_origin?(%URI{} = a, %URI{} = b) do
    {a.scheme, a.host, a.port} == {b.scheme, b.host, b.port}
  end

  # -- SSRF gate -------------------------------------------------------------

  defp ssrf_gate(host, opts) do
    allow_loopback? = Keyword.get(opts, :allow_loopback, false)

    case resolve(host) do
      {:ok, addrs} ->
        if Enum.any?(addrs, fn addr ->
             blocked_address?(addr) and not (allow_loopback? and loopback?(addr))
           end) do
          {:error, :ssrf_blocked}
        else
          :ok
        end

      :unresolvable ->
        # Nothing to classify and nothing to connect to — the generic
        # could-not-reach atom (never a reason term that could carry the
        # hostname).
        {:error, :timeout}
    end
  end

  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, addr} ->
        {:ok, [addr]}

      {:error, _not_a_literal} ->
        addrs = getaddrs(charlist, :inet) ++ getaddrs(charlist, :inet6)
        if addrs == [], do: :unresolvable, else: {:ok, addrs}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _reason} -> []
    end
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, _lo}), do: true
  defp loopback?(_addr), do: false

  # -- one hop: async :httpc request + streamed response ---------------------

  defp request(uri, etag, last_modified, opts, remaining, deadline) do
    url = uri |> URI.to_string() |> String.to_charlist()

    headers =
      [{~c"accept", ~c"text/calendar, */*"}] ++
        conditional_header(~c"if-none-match", etag) ++
        conditional_header(~c"if-modified-since", last_modified)

    http_opts =
      [
        autoredirect: false,
        timeout: remaining,
        connect_timeout: remaining
      ] ++ ssl_opts(uri, opts)

    case :httpc.request(:get, {url, headers}, http_opts,
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, ref} ->
        max_bytes = Keyword.get(opts, :max_body_bytes, @max_body_bytes)
        await_response(ref, deadline, max_bytes)

      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  defp conditional_header(_name, nil), do: []
  defp conditional_header(name, value), do: [{name, String.to_charlist(value)}]

  defp ssl_opts(%URI{scheme: "https", host: host}, opts) do
    [ssl: merge_tls_opts(default_tls_opts(host), Keyword.get(opts, :tls_opts, []))]
  end

  defp ssl_opts(_uri, _opts), do: []

  defp default_tls_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]
  end

  # `opts[:tls_opts]` is merged *over* the defaults. `:ssl` rejects
  # specifying both `cacerts` and `cacertfile` at once, so if the override
  # touches either key, the default `cacerts` is dropped rather than
  # coexisting with it — this is how a test substitutes the fixture CA
  # without ever touching `verify: :verify_peer` (the ImapClient seam,
  # verbatim).
  defp merge_tls_opts(defaults, override) do
    defaults =
      if Keyword.has_key?(override, :cacertfile) or Keyword.has_key?(override, :cacerts) do
        Keyword.delete(defaults, :cacerts)
      else
        defaults
      end

    Keyword.merge(defaults, override)
  end

  # First message decides the shape: a streamed 200 arrives as
  # `:stream_start`; every other status (304, redirects, errors) arrives
  # as one complete result.
  defp await_response(ref, deadline, max_bytes) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        case declared_length(headers) do
          length when is_integer(length) and length > max_bytes ->
            abort(ref, :too_large)

          _within_cap_or_unknown ->
            collect_stream(ref, deadline, max_bytes, [], 0, headers)
        end

      {:http, {^ref, {{_version, status, _phrase}, headers, body}}} ->
        complete_response(status, headers, body, max_bytes)

      {:http, {^ref, {:error, reason}}} ->
        {:error, transport_error(reason)}
    after
      remaining_or_zero(deadline) ->
        abort(ref, :timeout)
    end
  end

  defp collect_stream(ref, deadline, max_bytes, chunks, size, headers) do
    receive do
      {:http, {^ref, :stream, chunk}} ->
        size = size + byte_size(chunk)

        if size > max_bytes do
          abort(ref, :too_large)
        else
          collect_stream(ref, deadline, max_bytes, [chunk | chunks], size, headers)
        end

      {:http, {^ref, :stream_end, _trailers}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {:success, body, header(headers, "etag"), header(headers, "last-modified")}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, transport_error(reason)}
    after
      remaining_or_zero(deadline) ->
        abort(ref, :timeout)
    end
  end

  defp complete_response(status, headers, body, max_bytes) do
    cond do
      status == 304 ->
        {:ok, :unchanged}

      status in @redirect_statuses ->
        {:ok, {:redirect, header(headers, "location")}}

      status == 200 and byte_size(body) > max_bytes ->
        {:error, :too_large}

      status == 200 ->
        {:ok, {:success, body, header(headers, "etag"), header(headers, "last-modified")}}

      true ->
        {:error, {:http, status}}
    end
  end

  defp abort(ref, reason) do
    :ok = :httpc.cancel_request(ref)
    flush(ref)
    {:error, reason}
  end

  # `cancel_request/1` is asynchronous — a message already in flight for
  # this request may still land; drain it so it can't leak into a later
  # receive.
  defp flush(ref) do
    receive do
      {:http, {^ref, _payload}} -> flush(ref)
    after
      50 -> :ok
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if List.to_string(key) == name, do: List.to_string(value)
    end)
  end

  defp declared_length(headers) do
    case header(headers, "content-length") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {length, ""} -> length
          _other -> nil
        end
    end
  end

  # -- deadline --------------------------------------------------------------

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      ms when ms > 0 -> {:ok, ms}
      _expired -> {:error, :timeout}
    end
  end

  defp remaining_or_zero(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  # -- typed-atom error mapping ----------------------------------------------

  # Reason terms from :httpc/:ssl can embed request context, so none ever
  # escapes: a TLS-layer failure (any `:tls_alert` in the term) is `:tls`,
  # everything else is `:timeout` — the generic could-not-reach atom.
  defp transport_error(reason) do
    if tls_error?(reason), do: :tls, else: :timeout
  end

  defp tls_error?(:tls_alert), do: true

  defp tls_error?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&tls_error?/1)

  defp tls_error?(term) when is_list(term), do: Enum.any?(term, &tls_error?/1)
  defp tls_error?(_term), do: false
end
