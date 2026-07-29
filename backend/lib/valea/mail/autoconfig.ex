defmodule Valea.Mail.Autoconfig do
  @moduledoc """
  Best-effort IMAP/SMTP settings discovery for the account-setup form,
  Thunderbird-style: given `you@example.com`, guess the server host/port so
  the user reviews prefilled fields instead of hunting for provider docs.

  Strategy chain — first source that yields an IMAP server wins:

    1. **ISPDB by address domain** — `https://autoconfig.thunderbird.net/
       v1.1/<domain>` (Thunderbird's curated provider database).
    2. **Domain autoconfig** — `https://autoconfig.<domain>/mail/
       config-v1.1.xml` (the provider's own published file). Deliberately
       WITHOUT the `emailaddress=` query parameter Thunderbird appends: the
       full address is never sent anywhere, only the domain.
    3. **MX-derived ISPDB** — DNS MX for the domain, then ISPDB for the MX
       host's parent domains (a custom domain hosted at a known provider:
       `wirdrei.digital` → MX `mta-gw.infomaniak.ch` → ISPDB
       `infomaniak.ch` → `imap.infomaniak.com`).
    4. **DNS SRV (RFC 6186)** — `_imaps._tcp.<domain>` /
       `_submissions._tcp.<domain>` / `_submission._tcp.<domain>`.
    5. **Heuristic** — `imap.<domain>:993` / `smtp.<domain>:587`, offered
       only when the hostname actually resolves.

  Constraint from `Valea.Mail.ImapClient` (TLS mandatory, implicit): only
  SSL-type incoming servers are usable — a STARTTLS-only IMAP entry (port
  143) is skipped rather than suggested. SMTP keeps both flavors
  (`starttls`/`tls`), matching `Valea.Mail.Settings`' vocabulary.

  Every network step is short-timeout and failure-tolerant — any error just
  falls through to the next source; the whole discovery returning
  `%{imap: nil, smtp: nil}` simply leaves the form for the user to fill.
  The HTTP and DNS primitives are injectable (`opts[:http_get]` /
  `opts[:dns_lookup]`) so the chain is unit-testable without a network.
  """

  @type server :: %{host: String.t(), port: pos_integer(), security: String.t()}
  @type result :: %{imap: server() | nil, smtp: server() | nil, source: String.t() | nil}

  @http_timeout 4_000
  @connect_timeout 3_000

  @doc """
  Discovers likely IMAP/SMTP settings for `email`. `{:error, :invalid_email}`
  when the address has no usable domain part; otherwise always `{:ok, result}`
  — with `imap: nil, smtp: nil, source: nil` when every source came up empty.
  """
  @spec discover(String.t(), keyword()) :: {:ok, result()} | {:error, :invalid_email}
  def discover(email, opts \\ []) when is_binary(email) do
    with {:ok, domain} <- domain_of(email) do
      http_get = Keyword.get(opts, :http_get, &default_http_get/1)
      dns_lookup = Keyword.get(opts, :dns_lookup, &default_dns_lookup/2)

      result =
        first_hit([
          fn -> ispdb(domain, http_get) end,
          fn -> domain_autoconfig(domain, http_get) end,
          fn -> mx_ispdb(domain, http_get, dns_lookup) end,
          fn -> srv(domain, dns_lookup) end,
          fn -> heuristic(domain, dns_lookup) end
        ])

      {:ok, result || %{imap: nil, smtp: nil, source: nil}}
    end
  end

  defp first_hit([]), do: nil

  defp first_hit([probe | rest]) do
    case probe.() do
      %{imap: %{}} = hit -> hit
      _miss -> first_hit(rest)
    end
  end

  @doc "The domain part of an address, lowercased — `{:error, :invalid_email}` for anything without one."
  @spec domain_of(String.t()) :: {:ok, String.t()} | {:error, :invalid_email}
  def domain_of(email) do
    case String.split(String.trim(email), "@", parts: 2) do
      [local, domain] when local != "" ->
        domain = String.downcase(String.trim(domain))

        if domain =~ ~r/^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/ do
          {:ok, domain}
        else
          {:error, :invalid_email}
        end

      _no_at ->
        {:error, :invalid_email}
    end
  end

  # -- sources ---------------------------------------------------------------

  defp ispdb(domain, http_get) do
    fetch_config("https://autoconfig.thunderbird.net/v1.1/#{domain}", "ispdb:#{domain}", http_get)
  end

  defp domain_autoconfig(domain, http_get) do
    fetch_config(
      "https://autoconfig.#{domain}/mail/config-v1.1.xml",
      "autoconfig:#{domain}",
      http_get
    )
  end

  # MX host → try ISPDB AND the provider's own autoconfig endpoint for each
  # parent domain of it (never the full hostname itself —
  # `mta-gw.infomaniak.ch` is not a provider key, but `infomaniak.ch` is).
  # Both sources matter in practice: Infomaniak, for one, is NOT in ISPDB
  # but publishes `autoconfig.infomaniak.ch/mail/config-v1.1.xml` — which is
  # exactly how a custom domain hosted there resolves to its mail hosts.
  # Capped at a few candidates to keep this bounded.
  defp mx_ispdb(domain, http_get, dns_lookup) do
    with [_ | _] = mx_hosts <- mx_hosts(domain, dns_lookup) do
      mx_hosts
      |> Enum.flat_map(&parent_domains/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == domain))
      |> Enum.take(3)
      |> Enum.find_value(fn candidate ->
        ispdb(candidate, http_get) || domain_autoconfig(candidate, http_get)
      end)
    else
      _ -> nil
    end
  end

  defp mx_hosts(domain, dns_lookup) do
    domain
    |> dns_lookup.(:mx)
    |> Enum.sort()
    |> Enum.map(fn {_preference, host} -> host |> to_string() |> String.downcase() end)
  rescue
    _ -> []
  end

  # "mta-gw.infomaniak.ch" -> ["infomaniak.ch"]; already-registrable hosts
  # ("mx.example.com" -> ["example.com"]) yield their parent only. Naive on
  # multi-part public suffixes (co.uk) — acceptable for a guess source.
  defp parent_domains(host) do
    labels = String.split(host, ".", trim: true)

    case labels do
      [_ | rest] when length(rest) >= 2 -> [Enum.join(rest, ".")]
      _too_short -> []
    end
  end

  defp srv(domain, dns_lookup) do
    imap =
      case srv_record("_imaps._tcp.#{domain}", dns_lookup) do
        {host, port} -> %{host: host, port: port, security: "tls"}
        nil -> nil
      end

    smtp =
      case srv_record("_submissions._tcp.#{domain}", dns_lookup) do
        {host, port} ->
          %{host: host, port: port, security: "tls"}

        nil ->
          case srv_record("_submission._tcp.#{domain}", dns_lookup) do
            {host, port} -> %{host: host, port: port, security: "starttls"}
            nil -> nil
          end
      end

    if imap, do: %{imap: imap, smtp: smtp, source: "srv:#{domain}"}
  end

  defp srv_record(name, dns_lookup) do
    case dns_lookup.(name, :srv) do
      [_ | _] = records ->
        # Lowest priority wins; "." target means "service not offered".
        {_prio, _weight, port, host} = Enum.min_by(records, fn {p, w, _port, _h} -> {p, -w} end)
        host = host |> to_string() |> String.trim_trailing(".")
        if host in ["", "."], do: nil, else: {String.downcase(host), port}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp heuristic(domain, dns_lookup) do
    imap_host = "imap.#{domain}"
    smtp_host = "smtp.#{domain}"

    if resolves?(imap_host, dns_lookup) do
      smtp =
        if resolves?(smtp_host, dns_lookup),
          do: %{host: smtp_host, port: 587, security: "starttls"}

      %{
        imap: %{host: imap_host, port: 993, security: "tls"},
        smtp: smtp,
        source: "guess:#{domain}"
      }
    end
  end

  defp resolves?(host, dns_lookup) do
    Enum.any?([:a, :aaaa], fn type ->
      case dns_lookup.(host, type) do
        [_ | _] -> true
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  # -- config-v1.1.xml parsing ------------------------------------------------

  defp fetch_config(url, source, http_get) do
    with {:ok, body} <- http_get.(url),
         %{imap: %{}} = parsed <- parse_config(body) do
      Map.put(parsed, :source, source)
    else
      _ -> nil
    end
  end

  @doc """
  Parses a Thunderbird `config-v1.1.xml` document into `%{imap:, smtp:}`.
  Only SSL-type incoming servers are considered (see the moduledoc); the
  first usable entry of each kind wins. Public for tests.
  """
  @spec parse_config(binary()) :: %{imap: server() | nil, smtp: server() | nil}
  def parse_config(xml) when is_binary(xml) do
    case Floki.parse_document(xml) do
      {:ok, doc} ->
        imap =
          doc
          |> Floki.find(~s(incomingserver[type="imap"]))
          |> Enum.find_value(&server_entry(&1, "SSL"))

        smtp =
          doc
          |> Floki.find(~s(outgoingserver[type="smtp"]))
          |> Enum.find_value(&server_entry(&1, nil))

        %{imap: imap, smtp: smtp}

      _ ->
        %{imap: nil, smtp: nil}
    end
  end

  # `require_socket` narrows incoming servers to implicit-TLS only; `nil`
  # accepts both SMTP flavors. socketType→security uses `Settings`' words.
  defp server_entry(node, require_socket) do
    host = node |> Floki.find("hostname") |> Floki.text() |> String.trim()
    port = node |> Floki.find("port") |> Floki.text() |> String.trim()
    socket = node |> Floki.find("sockettype") |> Floki.text() |> String.trim() |> String.upcase()

    security =
      case socket do
        "SSL" -> "tls"
        "STARTTLS" -> "starttls"
        _ -> nil
      end

    with true <- host != "",
         {port, ""} <- Integer.parse(port),
         true <- port > 0,
         true <- security != nil,
         true <- require_socket in [nil, socket] do
      %{host: String.downcase(host), port: port, security: security}
    else
      _ -> nil
    end
  end

  # -- default network primitives ---------------------------------------------

  defp default_http_get(url) do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, cacerts} <- system_cacerts() do
      request = {String.to_charlist(url), [{~c"user-agent", ~c"valea-mail-autoconfig"}]}

      http_opts = [
        ssl: [
          verify: :verify_peer,
          cacerts: cacerts,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        timeout: @http_timeout,
        connect_timeout: @connect_timeout
      ]

      case :httpc.request(:get, request, http_opts, body_format: :binary) do
        {:ok, {{_http, 200, _reason}, _headers, body}} when is_binary(body) -> {:ok, body}
        _ -> :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp system_cacerts do
    {:ok, :public_key.cacerts_get()}
  rescue
    _ -> :error
  end

  defp default_dns_lookup(name, type) do
    :inet_res.lookup(String.to_charlist(name), :in, type, timeout: @connect_timeout)
  end
end
