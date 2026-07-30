defmodule Valea.Mail.SmtpClient do
  @moduledoc """
  `Valea.Mail.SmtpTransport` over a real socket — hand-written on
  `:ssl`/`:gen_tcp`, deliberately NOT on gen_smtp's own SMTP client
  (gen_smtp stays MIME-only here). Two reasons, both structural: that
  client's `network_failure` taxonomy cannot localize a failure relative to
  the DATA dot, so the tri-state contract is inexpressible in it; and its
  `retries` host-loop re-runs the whole session *including DATA* on
  temporary failures, which is retransmission — the one thing this stack
  must never do.

  Ground rules enforced here:

    * **One shot.** `send/5` opens a connection, transmits at most once, and
      returns. There is no retry, no reconnect, no second `DATA`.
    * **TLS is mandatory and verified**, in both security modes:
      `verify: :verify_peer`, the system CA store, SNI, and hostname
      verification. The only thing that can vary is WHICH trust root is
      used — the account's pinned `config.cacertfile`
      (`Settings.smtp_config/1` stamping `tls_cacert_file:`, e.g. ProtonMail
      Bridge's exported certificate), or `opts[:tls_opts]` (tests substitute
      the fixture CA, and keep the final say over the config value). Neither
      may ever be used to weaken or disable `verify_peer`. This is the same
      posture and the same merge convention as `Valea.Mail.ImapClient` — the
      two constructions are intentionally identical and must stay in
      lockstep.
    * **AUTH only over TLS.** On `:starttls` the credential is never even
      formatted before the upgrade succeeds, and the mechanism list is taken
      ONLY from the post-upgrade `EHLO` (RFC 3207 §4.2 — pre-TLS extensions
      are discarded, and any bytes buffered across the upgrade are treated
      as an injection attempt, not as protocol).
    * **The account's `auth` mode picks the mechanism family**, not the
      advertisement: `:password` → `PLAIN`/`LOGIN`, `:oauth2` → `XOAUTH2` and
      nothing else (M6 task 15). No fallback crosses that line — see
      `Valea.Mail.SmtpTransport`'s §AUTH mechanism selection.
    * **All-or-nothing recipients.** Every `RCPT TO` must be accepted; one
      rejection aborts with `RSET` + `QUIT` before `DATA`.
    * **Credentials never leak.** They are never logged, never interpolated
      into a message, and every returned reason is passed through
      `Valea.Mail.Redact` — server reply text that echoes the secret
      included.

  See `Valea.Mail.SmtpTransport` for the tri-state contract this implements;
  the `354` boundary is implemented in `send_payload/2` + `final_reply/3` and
  nowhere else.
  """

  @behaviour Valea.Mail.SmtpTransport

  alias Valea.Mail.Redact
  alias Valea.Mail.Xoauth2

  @default_timeout 30_000

  # `send_timeout` matters here in a way it doesn't for IMAP: a send payload
  # can be megabytes, so a stalled peer must surface as a timeout rather than
  # blocking the executor forever. A timed-out write lands AFTER the 354 and
  # is classified `:unknown`, which is the honest answer.
  @socket_opts [
    active: false,
    mode: :binary,
    packet: :raw,
    send_timeout: @default_timeout,
    send_timeout_close: true
  ]

  defmodule Session do
    @moduledoc false
    # `mod` is `:ssl` once TLS is up (always, before AUTH), `:gen_tcp` only
    # during a STARTTLS session's pre-upgrade phase. `extensions` is the
    # EHLO keyword list currently in force — reset to `[]` by the upgrade.
    defstruct [:mod, :socket, :timeout, buffer: "", extensions: []]
  end

  # -- SmtpTransport callbacks ------------------------------------------------

  @impl true
  def send(config, credential, envelope, data, opts \\ []) do
    case open_session(config, credential, opts) do
      {:ok, session} -> transmit(session, envelope, data, credential)
      {:error, reason} -> {:error, Redact.reason(reason, credential)}
    end
  end

  @impl true
  def check_auth(config, credential, opts \\ []) do
    case open_session(config, credential, opts) do
      {:ok, session} ->
        quit(session)
        :ok

      {:error, reason} ->
        {:error, Redact.reason(reason, credential)}
    end
  end

  # -- session setup ------------------------------------------------------------

  # Connect → greeting → (EHLO [→ STARTTLS → EHLO]) → AUTH. Every failure here
  # is before the 354 and therefore provably unsent.
  defp open_session(config, credential, opts) do
    # Resolved BEFORE the socket exists: an auth mode this client cannot honor
    # must fail without a session to leak (see `auth_mode/1`).
    auth = auth_mode(config)

    with {:ok, session} <- connect(config, opts),
         {:ok, session} <- greeting(session),
         {:ok, session} <- secure(session, config, opts),
         {:ok, session} <- authenticate(session, auth, config.username, credential) do
      {:ok, session}
    else
      {:error, session, reason} ->
        close(session)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(%{security: :tls} = config, opts) do
    host = to_string(config.host)
    tls_opts = merge_tls_opts(default_tls_opts(host), tls_override(config, opts))
    timeout = timeout(opts)

    case :ssl.connect(String.to_charlist(host), config.port, tls_opts ++ @socket_opts, timeout) do
      {:ok, socket} -> {:ok, %Session{mod: :ssl, socket: socket, timeout: timeout}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(%{security: :starttls} = config, opts) do
    host = to_string(config.host)
    timeout = timeout(opts)

    case :gen_tcp.connect(String.to_charlist(host), config.port, @socket_opts, timeout) do
      {:ok, socket} -> {:ok, %Session{mod: :gen_tcp, socket: socket, timeout: timeout}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp greeting(session) do
    case read_reply(session) do
      {:ok, %{code: code}, session} when code in 200..299 -> {:ok, session}
      {:ok, reply, session} -> {:error, session, {:greeting, reply.code, reply.text}}
      {:error, session, reason} -> {:error, session, reason}
    end
  end

  # `:tls` — TLS was already up before the greeting, so ONE EHLO settles the
  # extension set and AUTH follows. STARTTLS never appears on this path.
  defp secure(session, %{security: :tls}, _opts), do: ehlo(session)

  # `:starttls` — EHLO, require the advertisement, upgrade, then EHLO again.
  # The pre-upgrade extension set is DISCARDED by `upgrade_tls/3` (RFC 3207),
  # so the mechanisms AUTH selects from can only have come from the second
  # EHLO. A server that never advertises STARTTLS is refused outright: there
  # is no plaintext fallback, and the credential has not been formatted yet.
  defp secure(session, %{security: :starttls} = config, opts) do
    with {:ok, session} <- ehlo(session),
         :ok <- require_starttls(session),
         {:ok, session} <- command_2xx(session, "STARTTLS"),
         {:ok, session} <- upgrade_tls(session, config, opts) do
      ehlo(session)
    else
      :starttls_unsupported -> {:error, session, :starttls_unsupported}
      {:error, _session, _reason} = error -> error
    end
  end

  defp require_starttls(session) do
    if has_extension?(session, "STARTTLS"), do: :ok, else: :starttls_unsupported
  end

  defp upgrade_tls(%Session{buffer: buffer} = session, _config, _opts) when buffer != "" do
    # Bytes sitting in the buffer when the handshake is about to start were
    # written by whoever holds the plaintext socket BEFORE the TLS layer
    # exists — i.e. an injector, not the authenticated server. Fail; never
    # silently discard and carry on.
    {:error, session, :pretls_data_injection}
  end

  defp upgrade_tls(%Session{} = session, config, opts) do
    host = to_string(config.host)
    tls_opts = merge_tls_opts(default_tls_opts(host), tls_override(config, opts))

    case :ssl.connect(session.socket, tls_opts ++ @socket_opts, session.timeout) do
      {:ok, socket} ->
        {:ok, %Session{session | mod: :ssl, socket: socket, buffer: "", extensions: []}}

      {:error, reason} ->
        {:error, session, reason}
    end
  end

  defp ehlo(session) do
    case command(session, "EHLO " <> ehlo_domain()) do
      {:ok, %{code: code} = reply, %Session{} = session} when code in 200..299 ->
        {:ok, %Session{session | extensions: extensions(reply.lines)}}

      {:ok, reply, session} ->
        {:error, session, {:ehlo_failed, reply.code, reply.text}}

      {:error, session, reason} ->
        {:error, session, reason}
    end
  end

  # RFC 5321 §4.1.4 wants the client's own FQDN; submission servers do not
  # validate it. The local hostname is the honest answer, with a literal
  # fallback for a host that cannot name itself.
  defp ehlo_domain do
    case :inet.gethostname() do
      {:ok, name} when name != ~c"" -> to_string(name)
      _ -> "localhost"
    end
  end

  # The first EHLO line is the server's greeting/domain; the rest are
  # extension keyword lines (`AUTH PLAIN LOGIN`, `SIZE 1000000`, ...).
  defp extensions([_greeting | keywords]), do: Enum.map(keywords, &String.upcase/1)
  defp extensions(_lines), do: []

  defp has_extension?(session, keyword) do
    Enum.any?(session.extensions, fn line ->
      line == keyword or String.starts_with?(line, keyword <> " ")
    end)
  end

  # -- AUTH ----------------------------------------------------------------------

  # The account's `auth` mode picks the mechanism FAMILY; the server's
  # advertisement only picks within it. A config map without the key is
  # `:password` (every caller predating M6 task 15), but an unrecognized value
  # deliberately has no clause — a mode this client cannot honor must fail the
  # session rather than degrade to offering the credential as a password.
  defp auth_mode(config) do
    case Map.get(config, :auth, :password) do
      :password -> :password
      :oauth2 -> :oauth2
    end
  end

  defp authenticate(session, :password, username, credential),
    do: auth_password(session, username, credential)

  defp authenticate(session, :oauth2, username, access_token),
    do: auth_xoauth2(session, username, access_token)

  defp auth_password(session, username, credential) do
    case auth_mechanisms(session) do
      [] ->
        {:error, session, :auth_not_offered}

      mechs ->
        cond do
          "PLAIN" in mechs -> auth_plain(session, username, credential)
          "LOGIN" in mechs -> auth_login(session, username, credential)
          true -> {:error, session, {:auth_unsupported, mechs}}
        end
    end
  end

  # `XOAUTH2` or nothing: there is no PLAIN/LOGIN fallback on this path, ever.
  # Falling back would offer the ACCESS TOKEN as a password — to a server that
  # by definition never asked for one, and (on a misconfigured host) is not the
  # provider the token was minted for.
  defp auth_xoauth2(session, username, access_token) do
    case auth_mechanisms(session) do
      [] ->
        {:error, session, :auth_not_offered}

      mechs ->
        if "XOAUTH2" in mechs do
          offer_xoauth2(session, username, access_token)
        else
          {:error, session, {:auth_unsupported, mechs}}
        end
    end
  end

  defp offer_xoauth2(session, username, access_token) do
    case command(session, "AUTH XOAUTH2 " <> Xoauth2.response(username, access_token)) do
      {:ok, %{code: code}, session} when code in 200..299 ->
        {:ok, session}

      # THE failure round. A server rejecting XOAUTH2 answers the initial
      # response with `334 <base64 error>` and waits for a (mandatory, empty)
      # client line before it will send its 535 — so this is not "an
      # unexpected continuation", it is how the rejection is spelled, and a
      # client that returns here leaves the session mid-exchange.
      {:ok, %{code: 334}, session} ->
        finish_failed_xoauth2(session, access_token)

      {:ok, reply, session} ->
        {:error, session, reauth_required(reply, access_token)}

      {:error, session, reason} ->
        {:error, session, reason}
    end
  end

  # `command(session, "")` writes exactly the empty line the mechanism asks
  # for. A 2xx here cannot happen against a conforming server (the 334 above
  # only ever precedes a rejection) but is honored rather than second-guessed.
  defp finish_failed_xoauth2(session, access_token) do
    case command(session, "") do
      {:ok, %{code: code}, session} when code in 200..299 ->
        {:ok, session}

      {:ok, reply, session} ->
        {:error, session, reauth_required(reply, access_token)}

      {:error, session, reason} ->
        {:error, session, reason}
    end
  end

  defp auth_mechanisms(session) do
    Enum.find_value(session.extensions, [], fn
      "AUTH " <> mechs -> String.split(mechs, " ", trim: true)
      _ -> nil
    end)
  end

  defp auth_plain(session, username, credential) do
    blob = Base.encode64(<<0>> <> username <> <<0>> <> credential)

    case command(session, "AUTH PLAIN " <> blob) do
      {:ok, %{code: code}, session} when code in 200..299 -> {:ok, session}
      {:ok, reply, session} -> {:error, session, auth_failed(reply, credential)}
      {:error, session, reason} -> {:error, session, reason}
    end
  end

  defp auth_login(session, username, credential) do
    with {:ok, session} <- command_334(session, "AUTH LOGIN", credential),
         {:ok, session} <- command_334(session, Base.encode64(username), credential) do
      case command(session, Base.encode64(credential)) do
        {:ok, %{code: code}, session} when code in 200..299 -> {:ok, session}
        {:ok, reply, session} -> {:error, session, auth_failed(reply, credential)}
        {:error, session, reason} -> {:error, session, reason}
      end
    end
  end

  defp command_334(session, line, credential) do
    case command(session, line) do
      {:ok, %{code: 334}, session} -> {:ok, session}
      {:ok, reply, session} -> {:error, session, auth_failed(reply, credential)}
      {:error, session, reason} -> {:error, session, reason}
    end
  end

  # The reply TEXT is scrubbed here rather than only at the outer boundary, so
  # a server that echoes the password back keeps the `{:auth_failed, _}` shape
  # the doctor pattern-matches on (`Redact.reason/2` would collapse the whole
  # term to a string).
  defp auth_failed(reply, credential) do
    {:auth_failed, Redact.text(full_text(reply), credential)}
  end

  # The XOAUTH2 counterpart, scrubbed the same way and kept a DISTINCT shape:
  # the doctor and the send pipeline both want to say "this sign-in expired,
  # reconnect the account" rather than "check your password", and an expired
  # token is the overwhelmingly common case here.
  defp reauth_required(reply, access_token) do
    {:reauth_required, Redact.text(full_text(reply), access_token)}
  end

  # -- transmit -------------------------------------------------------------------

  defp transmit(session, envelope, data, credential) do
    case envelope_phase(session, envelope) do
      {:ok, session} ->
        send_payload(session, data, credential)

      {:rejected, session, rejected} ->
        # Abort BEFORE DATA: nothing was transmitted, and RSET leaves the
        # session clean for the QUIT that follows.
        {:ok, session} = reset(session)
        quit(session)
        {:error, Redact.reason({:rejected_recipients, rejected}, credential)}

      {:error, session, reason} ->
        quit(session)
        {:error, Redact.reason(reason, credential)}
    end
  end

  defp envelope_phase(session, envelope) do
    with {:ok, session} <- command_2xx(session, "MAIL FROM:<#{envelope.from}>") do
      rcpt_all(session, envelope.rcpt, [])
    end
  end

  defp rcpt_all(session, [], []), do: {:ok, session}
  defp rcpt_all(session, [], rejected), do: {:rejected, session, Enum.reverse(rejected)}

  defp rcpt_all(session, [addr | rest], rejected) do
    case command(session, "RCPT TO:<#{addr}>") do
      {:ok, %{code: code}, session} when code in 200..299 ->
        rcpt_all(session, rest, rejected)

      {:ok, reply, session} ->
        # Every recipient is offered even after the first refusal, so the
        # human sees ALL the bad addresses at once instead of one per click.
        rcpt_all(session, rest, [{addr, full_text(reply)} | rejected])

      {:error, session, reason} ->
        {:error, session, reason}
    end
  end

  defp reset(session) do
    case command(session, "RSET") do
      {:ok, _reply, session} -> {:ok, session}
      {:error, session, _reason} -> {:ok, session}
    end
  end

  # THE 354 BOUNDARY. Everything above returns `{:error, _}` (provably
  # unsent); from the moment the server says 354, every failure without a
  # parseable final reply is `{:unknown, _}` — the payload's terminating dot
  # may already have been flushed by TCP even if our own write errored.
  defp send_payload(session, data, credential) do
    case command(session, "DATA") do
      {:ok, %{code: 354}, session} ->
        write_and_finish(session, prepare_payload(data), credential)

      {:ok, reply, session} ->
        quit(session)
        {:error, Redact.reason({:data_refused, reply.code, reply.text}, credential)}

      {:error, session, reason} ->
        close(session)
        {:error, Redact.reason(reason, credential)}
    end
  end

  defp write_and_finish(session, payload, credential) do
    with :ok <- write(session, payload),
         :ok <- write(session, ".\r\n") do
      final_reply(session, credential)
    else
      {:error, reason} ->
        close(session)
        {:unknown, Redact.reason(reason, credential)}
    end
  end

  defp final_reply(session, credential) do
    case read_reply(session) do
      {:ok, %{code: code}, session} when code in 200..299 ->
        quit(session)
        {:ok, :accepted}

      {:ok, reply, session} ->
        quit(session)
        {:error, Redact.reason({:refused, reply.code, reply.text}, credential)}

      {:error, session, reason} ->
        close(session)
        {:unknown, Redact.reason(reason, credential)}
    end
  end

  # RFC 5321 §4.5.2 transparency, applied to canonical CRLF lines: a body line
  # starting with `.` is doubled so it can never be read as the terminator.
  defp prepare_payload(data) do
    data
    |> String.replace(~r/\r\n|\r|\n/, "\r\n")
    |> String.replace(~r/^\./m, "..")
    |> ensure_trailing_crlf()
  end

  defp ensure_trailing_crlf(""), do: ""

  defp ensure_trailing_crlf(payload) do
    if String.ends_with?(payload, "\r\n"), do: payload, else: payload <> "\r\n"
  end

  # QUIT is best-effort and its reply is deliberately NOT read: by the time it
  # is sent the outcome is already decided, and waiting on a 221 could only
  # add latency (or hang on a server that never answers).
  defp quit(session) do
    _ = write(session, "QUIT\r\n")
    close(session)
  end

  defp close(%Session{mod: :ssl, socket: socket}), do: :ssl.close(socket)
  defp close(%Session{mod: :gen_tcp, socket: socket}), do: :gen_tcp.close(socket)

  # -- command / reply plumbing ----------------------------------------------------

  defp command(session, line) do
    case write(session, line <> "\r\n") do
      :ok -> read_reply(session)
      {:error, reason} -> {:error, session, reason}
    end
  end

  defp command_2xx(session, line) do
    case command(session, line) do
      {:ok, %{code: code}, session} when code in 200..299 ->
        {:ok, session}

      {:ok, reply, session} ->
        {:error, session, {:command_failed, line_verb(line), reply.code, reply.text}}

      {:error, session, reason} ->
        {:error, session, reason}
    end
  end

  # Only the VERB reaches an error term — never the arguments (a MAIL FROM
  # carries an address, and no command's arguments belong in a reason).
  defp line_verb(line), do: line |> String.split([" ", ":"], parts: 2) |> hd()

  defp write(%Session{mod: :ssl, socket: socket}, data), do: :ssl.send(socket, data)
  defp write(%Session{mod: :gen_tcp, socket: socket}, data), do: :gen_tcp.send(socket, data)

  # Reads one complete reply: `NNN-text` continuation lines followed by one
  # `NNN text` final line (RFC 5321 §4.2). A line that is not a reply line at
  # all is `{:unparseable, line}` — a distinct outcome from a socket error,
  # because after the dot the two mean the same thing (`:unknown`) but before
  # it the caller still wants the raw line in the reason.
  defp read_reply(session, acc \\ []) do
    case read_line(session) do
      {:ok, line, session} ->
        case parse_reply_line(line) do
          {:ok, code, true, text} -> read_reply(session, [{code, text} | acc])
          {:ok, code, false, text} -> {:ok, build_reply(code, [{code, text} | acc]), session}
          :error -> {:error, session, {:unparseable, line}}
        end

      {:error, session, reason} ->
        {:error, session, reason}
    end
  end

  defp parse_reply_line(<<d1, d2, d3, sep, text::binary>>)
       when d1 in ?2..?5 and d2 in ?0..?9 and d3 in ?0..?9 and sep in [?\s, ?-] do
    {:ok, (d1 - ?0) * 100 + (d2 - ?0) * 10 + (d3 - ?0), sep == ?-, text}
  end

  defp parse_reply_line(<<d1, d2, d3>>)
       when d1 in ?2..?5 and d2 in ?0..?9 and d3 in ?0..?9 do
    {:ok, (d1 - ?0) * 100 + (d2 - ?0) * 10 + (d3 - ?0), false, ""}
  end

  defp parse_reply_line(_line), do: :error

  # The code of the FINAL line decides (a well-behaved server repeats one code
  # across the group); `lines` keeps the per-line text in wire order, which is
  # what EHLO extension parsing reads.
  defp build_reply(code, reversed) do
    lines = reversed |> Enum.reverse() |> Enum.map(fn {_code, text} -> text end)
    %{code: code, lines: lines, text: Enum.join(lines, " ")}
  end

  defp full_text(%{code: code, text: text}), do: "#{code} #{text}"

  defp read_line(%Session{} = session) do
    case :binary.match(session.buffer, "\r\n") do
      {idx, _len} ->
        line = binary_part(session.buffer, 0, idx)
        rest_offset = idx + 2
        rest = binary_part(session.buffer, rest_offset, byte_size(session.buffer) - rest_offset)
        {:ok, line, %Session{session | buffer: rest}}

      :nomatch ->
        case recv(session) do
          {:ok, data} -> read_line(%Session{session | buffer: session.buffer <> data})
          {:error, reason} -> {:error, session, reason}
        end
    end
  end

  defp recv(%Session{mod: :ssl, socket: socket, timeout: t}), do: :ssl.recv(socket, 0, t)
  defp recv(%Session{mod: :gen_tcp, socket: socket, timeout: t}), do: :gen_tcp.recv(socket, 0, t)

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  # -- TLS options ------------------------------------------------------------------
  #
  # Byte-for-byte the construction in `Valea.Mail.ImapClient` (`default_tls_opts/1`
  # + `merge_tls_opts/2`): `verify_peer`, the system CA store, SNI, and HTTPS-style
  # hostname matching, with `opts[:tls_opts]` merged OVER the defaults so a test can
  # substitute a fixture trust root — and ONLY a trust root — without ever touching
  # `verify: :verify_peer`. Both clients must stay in lockstep; weakening either is
  # a security regression.

  defp default_tls_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]
  end

  # The account's pinned trust root (`Settings.smtp_config/1`'s `cacertfile`,
  # i.e. `tls_cacert_file:` in `config/mail.yaml` — e.g. ProtonMail Bridge's
  # exported certificate), merged UNDER `opts[:tls_opts]` so a test's explicit
  # override keeps the final say. Substitutes WHICH root is trusted and
  # nothing else — `verify: :verify_peer` stays untouched. Same construction
  # as `Valea.Mail.ImapClient.tls_override/2` (see the pinning comment there:
  # OTP refuses a self-signed PEER cert even out of the trust store, so the
  # pin carries a verify_fun accepting a byte-identical self-signed peer and
  # nothing else).
  defp tls_override(config, opts) do
    config_override =
      case Map.get(config, :cacertfile) do
        nil -> []
        path -> pinned_trust_opts(path)
      end

    Keyword.merge(config_override, Keyword.get(opts, :tls_opts, []))
  end

  defp pinned_trust_opts(path) do
    [cacertfile: path, verify_fun: {&pinned_verify/3, pinned_ders(path)}]
  end

  defp pinned_ders(path) do
    case File.read(path) do
      {:ok, pem} ->
        for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der

      {:error, _reason} ->
        []
    end
  end

  defp pinned_verify(peer_cert, {:bad_cert, :selfsigned_peer} = event, ders) do
    if :public_key.pkix_encode(:OTPCertificate, peer_cert, :otp) in ders,
      do: {:valid, ders},
      else: {:fail, event}
  end

  defp pinned_verify(_peer, {:bad_cert, _} = event, _ders), do: {:fail, event}
  defp pinned_verify(_peer, {:extension, _}, ders), do: {:unknown, ders}
  defp pinned_verify(_peer, :valid, ders), do: {:valid, ders}
  defp pinned_verify(_peer, :valid_peer, ders), do: {:valid, ders}

  # `:ssl` rejects specifying both `cacerts` and `cacertfile` at once, so if the
  # override touches either key the default `cacerts` is dropped rather than
  # coexisting with it.
  defp merge_tls_opts(defaults, override) do
    defaults =
      if Keyword.has_key?(override, :cacertfile) or Keyword.has_key?(override, :cacerts) do
        Keyword.delete(defaults, :cacerts)
      else
        defaults
      end

    Keyword.merge(defaults, override)
  end
end
