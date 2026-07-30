defmodule Valea.Mail.ImapClient do
  @moduledoc """
  Minimal `Valea.Mail.Transport` implementation over a real `:ssl` socket.

  Implements exactly the subset of IMAP the mail engine needs — see the
  mail design spec (§ImapClient / §Transport behaviour) for the full
  rationale. Ground rules enforced here:

    * **UIDs only.** Sequence numbers are never used in any command.
    * **`BODY.PEEK[...]`** for every fetch — reading a message here never
      sets `\\Seen` on the server.
    * **Safe move, never bare `EXPUNGE`.** `uid_move/3` is narrowed to
      native `UID MOVE` only (the `MOVE` capability) — without it, it
      reports `{:unsupported, _}` and mutates nothing. The `UID COPY` +
      `UID STORE +FLAGS (\\Deleted)` + `UID EXPUNGE <uid>` fallback ladder
      (RFC 4315, `UIDPLUS`) lives OUTSIDE this module, in the ops executor,
      which needs per-step control to confirm before expunging; this module
      only exposes the primitives (`uid_copy/3`, `uid_mark_deleted/2`,
      `uid_expunge/2`). `uid_mark_deleted/2` is the ONE sanctioned place in
      the codebase that stores `\\Deleted`, and `uid_expunge/2` always
      issues a targeted `UID EXPUNGE <uid>`, never a bare `EXPUNGE` — a bare
      one would purge every `\\Deleted` message in the mailbox, including
      ones the user's own client marked (grep for the literal string
      `"EXPUNGE"`: the only match is the `"UID", "EXPUNGE"` pair below).
    * **Connect-per-pass.** Every sync pass, ops batch, push and send opens
      its own connection and logs out at the end — no connection pool, no
      long-lived command socket. `connect/3` reads the greeting, logs in,
      then re-queries `CAPABILITY` (some servers advertise a different set
      once authenticated) — the cached set on `conn` is always the post-login
      one. The ONE long-lived exception is `Valea.Mail.IdleWatcher`, which
      holds a connection open for the sole purpose of IDLE (see the IDLE
      section below); it issues `EXAMINE` and `IDLE` and nothing else.
    * **TLS is mandatory and verified.** `connect/3` always passes
      `verify: :verify_peer` plus hostname verification and SNI; the only
      thing a caller can override via `opts[:tls_opts]` is which trust
      root is used (tests substitute a fixture CA via `cacertfile:`). This
      override must never be used in production code to weaken or disable
      `verify_peer` — its only sanctioned use is injecting a test fixture
      CA.

  ## Conn shape

  `conn :: term()` per `Valea.Mail.Transport` is opaque to callers; this
  module returns a `%Valea.Mail.ImapClient.Conn{}`. Notably, only
  `connect/3` returns an updated conn — every other callback takes `conn`
  and does *not* hand back a new value (per the `Transport` behaviour).
  Two consequences of that shape drove the internals:

    * The command tag counter lives in an `:counters` reference (a
      genuinely mutable cell), not a plain integer, so it can advance
      across calls without a new conn ever being returned.
    * No per-call read buffer is threaded through `conn` either — each
      command's response-reading loop keeps its buffer as a purely local
      variable. This is safe because the COMMAND protocol here is strictly
      request/response with no pipelining: the server only ever writes bytes
      in reaction to the command it just received, so a given call's socket
      reads can never contain bytes belonging to a future call's response.

  ## IDLE

  IDLE (RFC 2177) is the one exchange that breaks the assumption above — the
  server writes unsolicited bytes, and a burst of them can leave a *partial*
  response in the buffer when a read returns. Rather than give `conn` a
  mutable read buffer (which would then have to be reasoned about by all
  twenty other callbacks), the IDLE trio threads an opaque session value:
  `idle_start/1` returns `%{tag: ..., buffer: ..., pending: ...}`,
  `idle_await/3` hands back the advanced session, `idle_done/2` consumes it.
  Residual bytes therefore survive between awaits by construction.

  Nothing here mutates the mailbox: the watcher's connection reaches only
  `examine/2`, this trio, and `logout/1`.

  ## Authentication (`auth: :password | :oauth2`)

  `connect/3` branches on the account's SASL mode, which rides in the config
  map (`Valea.Mail.Settings.imap_config/1`) — never on anything sniffed off
  the server:

    * `:password` (the default) — `LOGIN` with both arguments as
      synchronizing literals.
    * `:oauth2` — `AUTHENTICATE XOAUTH2 <response>` (mail full-client plan,
      M6 task 15), the `credential` being an OAuth2 access token rather than
      a password.

  The two never mix and neither falls back to the other: a server that
  refuses XOAUTH2 is an error, not a reason to retry `LOGIN` with a bearer
  token in the password field. An XOAUTH2 rejection is
  `{:error, :reauth_required}`, deliberately distinct from `LOGIN`'s
  `{:error, :auth_failed}` — the remedy differs (a fresh token, not a
  re-typed password), and `Valea.Mail.Engine` keeps them as two states.
  """

  @behaviour Valea.Mail.Transport

  alias Valea.Mail.Imap.Wire
  alias Valea.Mail.Xoauth2

  @default_recv_timeout 30_000

  defmodule Conn do
    @moduledoc false
    defstruct [:socket, :capabilities, :tag, :recv_timeout]
  end

  # -- Transport callbacks --------------------------------------------------

  @impl true
  def connect(config, credential, opts \\ []) do
    host = to_string(config.host)
    port = config.port
    username = config.username
    # Resolved BEFORE the socket exists: an auth mode this client cannot honor
    # must fail without a connection to leak (see `auth_mode/1`).
    auth = auth_mode(config)
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)
    tls_opts = merge_tls_opts(default_tls_opts(host), Keyword.get(opts, :tls_opts, []))
    connect_opts = tls_opts ++ [active: false, mode: :binary, packet: :raw]

    case :ssl.connect(String.to_charlist(host), port, connect_opts) do
      {:ok, socket} ->
        conn = %Conn{
          socket: socket,
          capabilities: MapSet.new(),
          tag: :counters.new(1, []),
          recv_timeout: recv_timeout
        }

        with {:ok, conn} <- read_greeting(conn),
             {:ok, conn} <- authenticate(conn, auth, username, credential),
             {:ok, conn} <- refresh_capabilities(conn) do
          {:ok, conn}
        else
          {:error, reason} ->
            :ssl.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def capabilities(%Conn{capabilities: caps}), do: {:ok, MapSet.to_list(caps)}

  @impl true
  def list_folders(conn) do
    case send_command(conn, ["LIST", "", "*"]) do
      {:ok, :ok, _text, untagged} ->
        folders =
          Enum.flat_map(untagged, fn
            {:untagged, "LIST " <> rest} -> List.wrap(parse_list_mailbox(rest))
            _ -> []
          end)

        {:ok, folders}

      other ->
        command_error(other)
    end
  end

  @impl true
  def create_folder(conn, name) do
    case send_command(conn, ["CREATE", name]) do
      {:ok, :ok, _text, _untagged} -> :ok
      other -> command_error(other)
    end
  end

  @impl true
  def select(conn, folder) do
    case send_command(conn, ["SELECT", folder]) do
      {:ok, :ok, _text, untagged} -> {:ok, parse_select(untagged)}
      other -> command_error(other)
    end
  end

  @impl true
  def examine(conn, folder) do
    case send_command(conn, ["EXAMINE", folder]) do
      {:ok, :ok, _text, untagged} -> {:ok, parse_select(untagged)}
      other -> command_error(other)
    end
  end

  @impl true
  def uid_search(conn, criteria) do
    case send_command(conn, ["UID", "SEARCH" | String.split(criteria)]) do
      {:ok, :ok, _text, untagged} ->
        uids =
          Enum.flat_map(untagged, fn
            {:untagged, "SEARCH" <> rest} -> parse_search_uids(rest)
            _ -> []
          end)

        {:ok, uids}

      other ->
        command_error(other)
    end
  end

  @impl true
  def uid_fetch_meta(conn, uids) do
    fetch_each(conn, uids, "(UID RFC822.SIZE)", fn attrs ->
      %{uid: attrs.uid, size: attrs.size}
    end)
  end

  @impl true
  def uid_fetch_headers(conn, uids) do
    fetch_each(conn, uids, "(UID BODY.PEEK[HEADER])", fn attrs ->
      %{uid: attrs.uid, header: attrs.header}
    end)
  end

  @impl true
  def uid_fetch_full(conn, uid) do
    case send_command(conn, ["UID", "FETCH", Integer.to_string(uid), "(BODY.PEEK[])"]) do
      {:ok, :ok, _text, untagged} ->
        case find_fetch_attrs(untagged) do
          %{body: body} when is_binary(body) -> {:ok, body}
          _ -> {:error, {:no_fetch_data, uid}}
        end

      other ->
        command_error(other)
    end
  end

  @impl true
  def uid_fetch_flags(conn, uid_set) do
    # MODSEQ is only requested when the server is CONDSTORE-capable — a
    # non-CONDSTORE server may BAD the whole FETCH over an attribute it
    # doesn't understand. Without it, `collect_fetch_flags/1` naturally
    # reports `modseq: nil` for every item (the server never sends the
    # MODSEQ attr, so `Wire`'s per-item attrs map keeps its default `nil`).
    attr_spec =
      case {supports?(conn, :condstore), supports?(conn, :gmail)} do
        {true, true} -> "(UID FLAGS MODSEQ X-GM-MSGID)"
        {true, false} -> "(UID FLAGS MODSEQ)"
        {false, true} -> "(UID FLAGS X-GM-MSGID)"
        {false, false} -> "(UID FLAGS)"
      end

    case send_command(conn, ["UID", "FETCH", uid_set, attr_spec]) do
      {:ok, :ok, _text, untagged} -> {:ok, collect_fetch_flags(untagged)}
      other -> command_error(other)
    end
  end

  @impl true
  def uid_store_flags(conn, uid, add, remove, opts \\ []) do
    unchangedsince = Keyword.get(opts, :unchangedsince)
    uid_str = Integer.to_string(uid)

    if add != [] and remove != [] and unchangedsince != nil do
      atomic_replace_flags(conn, uid_str, add, remove, unchangedsince, opts)
    else
      with {:ok, add_status} <- maybe_store(conn, uid_str, "+FLAGS", add, unchangedsince),
           {:ok, remove_status} <- maybe_store(conn, uid_str, "-FLAGS", remove, unchangedsince) do
        {:ok, combine_store_status(add_status, remove_status)}
      end
    end
  end

  @impl true
  def uid_move(conn, uid, dest_folder) do
    if supports?(conn, :move) do
      case send_command(conn, ["UID", "MOVE", Integer.to_string(uid), dest_folder]) do
        {:ok, :ok, text, _untagged} -> {:ok, %{dest_uid: parse_copyuid_dest(text)}}
        other -> command_error(other)
      end
    else
      {:unsupported, "server does not advertise the MOVE capability"}
    end
  end

  @impl true
  def uid_copy(conn, uid, dest_folder) do
    case send_command(conn, ["UID", "COPY", Integer.to_string(uid), dest_folder]) do
      {:ok, :ok, text, _untagged} -> {:ok, %{dest_uid: parse_copyuid_dest(text)}}
      other -> command_error(other)
    end
  end

  @impl true
  def uid_mark_deleted(conn, uid) do
    case send_command(conn, ["UID", "STORE", Integer.to_string(uid), "+FLAGS", "(\\Deleted)"]) do
      {:ok, :ok, _text, _untagged} -> :ok
      other -> command_error(other)
    end
  end

  @impl true
  def uid_expunge(conn, uid) do
    case send_command(conn, ["UID", "EXPUNGE", Integer.to_string(uid)]) do
      {:ok, :ok, _text, _untagged} -> :ok
      other -> command_error(other)
    end
  end

  @impl true
  def append(conn, folder, flags, rfc822) do
    flags_arg = "(" <> Enum.join(flags, " ") <> ")"

    case send_command(conn, ["APPEND", folder, flags_arg, {:literal, rfc822}]) do
      {:ok, :ok, text, _untagged} -> {:ok, %{dest_uid: parse_appenduid_dest(text)}}
      {:ok, status, text, _untagged} -> {:error, {status, text}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def supports?(conn, capability) do
    MapSet.member?(conn.capabilities, capability_wire_name(capability))
  end

  @impl true
  def logout(conn) do
    _ = send_command(conn, ["LOGOUT"])
    :ssl.close(conn.socket)
    :ok
  end

  # -- IDLE (RFC 2177) -------------------------------------------------------

  @impl true
  def idle_start(conn) do
    tag = next_tag(conn)

    case :ssl.send(conn.socket, [tag, " IDLE\r\n"]) do
      :ok -> await_idle_continuation(conn, tag, "", [])
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  # Events the IDLE handshake already collected are handed over before the
  # socket is touched at all — they arrived, so reporting them cannot wait on
  # a deadline that may be 25 minutes away.
  def idle_await(_conn, %{pending: [_ | _] = pending} = idle, _timeout_ms),
    do: {:ok, pending, %{idle | pending: []}}

  def idle_await(conn, idle, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    collect_idle(conn, idle, now_ms() + timeout_ms)
  end

  @impl true
  def idle_done(conn, idle) do
    # `DONE` is the one client line in IMAP that carries no tag (RFC 2177) —
    # the IDLE's own tag is what its completion comes back under.
    case :ssl.send(conn.socket, "DONE\r\n") do
      :ok -> read_idle_completion(conn, idle.tag, idle.buffer, Enum.reverse(idle.pending))
      {:error, reason} -> {:error, reason}
    end
  end

  # Reads through to the server's `+` continuation — the only proof the
  # connection is genuinely idling. Untagged responses flushed on the way in
  # are collected into the session's `pending` rather than dropped; a tagged
  # response under our own tag is the server REFUSING the IDLE (it may, even
  # while advertising the capability).
  defp await_idle_continuation(conn, tag, buffer, events) do
    case read_until_response(conn.socket, conn.recv_timeout, buffer) do
      {:ok, {:continuation, _text}, rest} ->
        {:ok, %{tag: tag, buffer: rest, pending: Enum.reverse(events)}}

      {:ok, {:tagged, ^tag, status, text}, _rest} ->
        {:error, {status, text}}

      {:ok, response, rest} ->
        await_idle_continuation(conn, tag, rest, prepend_idle_event(response, events))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Drains every COMPLETE response already buffered before reading more, so a
  # burst that arrived in one TLS record is reported as one batch. A partial
  # tail stays in the returned session and is completed by a later recv —
  # this is the whole reason the session exists.
  defp collect_idle(conn, idle, deadline) do
    case pull_idle_events(idle.buffer, []) do
      {:ok, [_ | _] = events, rest} ->
        {:ok, events, %{idle | buffer: rest}}

      {:ok, [], rest} ->
        idle = %{idle | buffer: rest}
        remaining = deadline - now_ms()

        if remaining <= 0 do
          {:ok, [], idle}
        else
          recv_idle(conn, idle, deadline, remaining)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recv_idle(conn, idle, deadline, remaining) do
    case :ssl.recv(conn.socket, 0, remaining) do
      {:ok, data} -> collect_idle(conn, %{idle | buffer: idle.buffer <> data}, deadline)
      # A deadline is not a failure: it is how the caller's re-issue timer
      # surfaces (RFC 2177 asks a client to re-issue IDLE before the server's
      # own 29-minute cutoff).
      {:error, :timeout} -> {:ok, [], idle}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_idle_completion(conn, tag, buffer, acc) do
    case read_until_response(conn.socket, conn.recv_timeout, buffer) do
      {:ok, {:tagged, ^tag, :ok, _text}, _rest} ->
        {:ok, Enum.reverse(acc)}

      {:ok, {:tagged, ^tag, status, text}, _rest} ->
        {:error, {status, text}}

      # Untagged lines still arriving after DONE went out — a message can land
      # in exactly that window, and this is the caller's only notice of it.
      {:ok, response, rest} ->
        read_idle_completion(conn, tag, rest, prepend_idle_event(response, acc))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A tagged response arriving with no `DONE` sent is the server ending the
  # IDLE on its own (an idle cutoff, a shutdown): the session is over, so this
  # is an error rather than an event. Already-collected events are dropped
  # with it — the caller reconnects, and the poll loop remains the backstop
  # that makes a missed IDLE event a delay, never a loss.
  defp pull_idle_events(buffer, acc) do
    case Wire.pull(buffer) do
      :incomplete ->
        {:ok, Enum.reverse(acc), buffer}

      {:ok, {:tagged, _tag, status, text}, _rest} ->
        {:error, {:idle_terminated, status, text}}

      {:ok, response, rest} ->
        pull_idle_events(rest, prepend_idle_event(response, acc))
    end
  end

  # `Wire` already routes a parenthesized untagged FETCH to its own `:fetch`
  # response; the regex below catches the other two change notifications (and
  # a FETCH shape `Wire` didn't claim). Anything else — a `* OK Still here`
  # keepalive, a `* FLAGS (...)` re-announcement — is `:other`, which the
  # watcher must not read as mailbox change.
  @idle_change_re ~r/^(\d+) (EXISTS|EXPUNGE|FETCH)\b/

  defp prepend_idle_event({:untagged, line}, acc), do: [untagged_idle_event(line) | acc]
  defp prepend_idle_event({:fetch, seq, _attrs}, acc), do: [{:fetch, seq} | acc]
  defp prepend_idle_event({:continuation, _text}, acc), do: acc
  # Structurally unreachable (a tagged response is handled by every caller
  # before it gets here) — dropped rather than mis-reported as a change.
  defp prepend_idle_event(_other, acc), do: acc

  defp untagged_idle_event(line) do
    case Regex.run(@idle_change_re, line) do
      [_, seq, "EXISTS"] -> {:exists, String.to_integer(seq)}
      [_, seq, "EXPUNGE"] -> {:expunge, String.to_integer(seq)}
      [_, seq, "FETCH"] -> {:fetch, String.to_integer(seq)}
      nil -> {:other, line}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # -- connect helpers -------------------------------------------------------

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
  # without ever touching `verify: :verify_peer`.
  defp merge_tls_opts(defaults, override) do
    defaults =
      if Keyword.has_key?(override, :cacertfile) or Keyword.has_key?(override, :cacerts) do
        Keyword.delete(defaults, :cacerts)
      else
        defaults
      end

    Keyword.merge(defaults, override)
  end

  defp read_greeting(conn) do
    case read_until_response(conn.socket, conn.recv_timeout) do
      {:ok, {:untagged, _line}, _rest} -> {:ok, conn}
      {:ok, other, _rest} -> {:error, {:unexpected_greeting, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The account's SASL mode, as `Valea.Mail.Settings.imap_config/1` stamps it
  # onto the config map. A config map WITHOUT the key is `:password` — the
  # shape every caller predating M6 task 15 passes — but an unrecognized value
  # deliberately has no clause: a mode this client cannot honor must fail the
  # connect, never silently degrade to sending an access token as a password.
  defp auth_mode(config) do
    case Map.get(config, :auth, :password) do
      :password -> :password
      :oauth2 -> :oauth2
    end
  end

  defp authenticate(conn, :password, username, password),
    do: login(conn, username, password)

  defp authenticate(conn, :oauth2, username, access_token),
    do: xoauth2(conn, username, access_token)

  # Username AND password go as IMAP synchronizing literals (`{:literal, _}`),
  # never as bare/quoted args. A literal carries raw bytes verbatim, so a
  # value containing 8-bit bytes (non-ASCII passwords), spaces, or quotes logs
  # in correctly — and, critically, never flows through `Wire.encode_arg`,
  # whose CR/LF/8-bit guard would otherwise raise and land the credential in a
  # crash report.
  defp login(conn, username, password) do
    case send_command(conn, ["LOGIN", {:literal, username}, {:literal, password}]) do
      {:ok, :ok, _text, _untagged} -> {:ok, conn}
      {:ok, :no, _text, _untagged} -> {:error, :auth_failed}
      {:ok, status, text, _untagged} -> {:error, {status, text}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `AUTHENTICATE XOAUTH2 <response>` — the SASL initial-response form, sent as
  # ONE literal-free line so it burns exactly the tag `LOGIN` would have (a
  # command that consumed two would shift every subsequent tag and silently
  # invalidate every script this client is tested against).
  #
  # Written straight to the socket rather than through `Wire.encode_command/2`
  # on purpose: `encode_arg/1`'s astring rules would QUOTE a base64 blob (its
  # alphabet is not in the unquoted-safe set), and `AUTHENTICATE`'s argument is
  # a bare base64 token — a quoted one is a protocol error. Nothing is smuggled
  # by doing so: `Base.encode64/1` output is `[A-Za-z0-9+/=]` only, so the
  # response structurally cannot carry the CR/LF that guard exists to stop.
  # Same posture as `idle_start/1`, which writes its own tagged line too.
  defp xoauth2(conn, username, access_token) do
    tag = next_tag(conn)
    line = [tag, " AUTHENTICATE XOAUTH2 ", Xoauth2.response(username, access_token), "\r\n"]

    case :ssl.send(conn.socket, line) do
      :ok -> drive_xoauth2(conn, tag, "", false)
      {:error, reason} -> {:error, reason}
    end
  end

  # The XOAUTH2 exchange has TWO shapes. On success the server answers the
  # initial response with the tagged completion directly. On failure it first
  # sends a `+ <base64 error>` continuation carrying the provider's error JSON,
  # and the mechanism REQUIRES the client to acknowledge it with an empty line
  # before the tagged `NO` is sent — a client that just waits for the tag
  # instead hangs until its recv timeout on every expired token.
  #
  # `answered` makes that acknowledgement single-shot: a second continuation is
  # a server this client cannot converse with, not an invitation to trade blank
  # lines with it forever.
  defp drive_xoauth2(conn, tag, buffer, answered) do
    case read_until_response(conn.socket, conn.recv_timeout, buffer) do
      {:ok, {:tagged, ^tag, :ok, _text}, _rest} ->
        {:ok, conn}

      # A `NO` is the token being refused (expired, revoked, wrong scope): the
      # remedy is a fresh token, never a re-typed password, which is why this
      # is not `:auth_failed`. The error text is DROPPED rather than carried —
      # it is the base64 payload's decoded twin, and this reason reaches
      # `last_error`, i.e. the UI.
      {:ok, {:tagged, ^tag, :no, _text}, _rest} ->
        {:error, :reauth_required}

      # A `BAD` is the server rejecting the COMMAND (no XOAUTH2 support, no
      # SASL-IR) — re-authenticating cannot fix it, so it stays a plain
      # protocol error.
      {:ok, {:tagged, ^tag, status, text}, _rest} ->
        {:error, {status, text}}

      {:ok, {:continuation, _base64_error}, rest} when not answered ->
        case :ssl.send(conn.socket, "\r\n") do
          :ok -> drive_xoauth2(conn, tag, rest, true)
          {:error, reason} -> {:error, reason}
        end

      {:ok, {:continuation, _base64_error}, _rest} ->
        {:error, :unexpected_sasl_continuation}

      # Untagged chatter (a server flushing `* OK` or a capability line into
      # the exchange) is read past, exactly as every other command does.
      {:ok, _other, rest} ->
        drive_xoauth2(conn, tag, rest, answered)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_capabilities(conn) do
    case send_command(conn, ["CAPABILITY"]) do
      {:ok, :ok, _text, untagged} -> {:ok, %{conn | capabilities: extract_capabilities(untagged)}}
      other -> command_error(other)
    end
  end

  defp extract_capabilities(untagged) do
    untagged
    |> Enum.flat_map(fn
      {:untagged, "CAPABILITY " <> rest} -> String.split(rest)
      _ -> []
    end)
    |> MapSet.new()
  end

  # -- capability probing -------------------------------------------------

  defp capability_wire_name(:condstore), do: "CONDSTORE"
  defp capability_wire_name(:qresync), do: "QRESYNC"
  defp capability_wire_name(:move), do: "MOVE"
  defp capability_wire_name(:uidplus), do: "UIDPLUS"
  defp capability_wire_name(:gmail), do: "X-GM-EXT-1"
  defp capability_wire_name(:idle), do: "IDLE"
  # SASL mechanisms are advertised as `AUTH=<mech>` capabilities (RFC 3501
  # §6.1.1), not as bare keywords.
  defp capability_wire_name(:xoauth2), do: "AUTH=XOAUTH2"

  # -- COPYUID / APPENDUID response-code parsing -------------------------
  #
  # Per RFC 4315 (UIDPLUS) and RFC 6851 (MOVE), the destination UID rides in
  # the TEXT of the tagged OK response, never as a separate untagged line:
  # `A3 OK [COPYUID <uidvalidity> <src-uid-set> <dest-uid-set>] ...` or
  # `A3 OK [APPENDUID <uidvalidity> <dest-uid>] ...`. Absent (a server that
  # doesn't report it) parses to `nil` rather than erroring — the caller
  # still has a successful move/copy/append, just without a known dest UID.
  #
  # The dest token itself can be a uid-set (RFC 4315 allows COPYUID/APPENDUID
  # to report a range like `90:92` or a list like `90,92` — not just a bare
  # uid) when the underlying command actually affected multiple messages.
  # This single-uid client only ever issues single-uid COPY/MOVE/APPEND, but
  # some servers still echo a range/list shape back. Truncating to the
  # leading number in that case (the old behavior) hands back a
  # wrong-but-plausible dest_uid; parsing to `nil` instead is the honest
  # "unknown" the caller's search-based confirmation fallback already
  # handles.

  defp parse_copyuid_dest(text) do
    case Regex.run(~r/COPYUID \d+ \S+ ([^\]\s]+)/, text) do
      [_, token] -> parse_dest_uid_token(token)
      nil -> nil
    end
  end

  defp parse_appenduid_dest(text) do
    case Regex.run(~r/APPENDUID \d+ ([^\]\s]+)/, text) do
      [_, token] -> parse_dest_uid_token(token)
      nil -> nil
    end
  end

  defp parse_dest_uid_token(token) do
    if String.contains?(token, ":") or String.contains?(token, ",") do
      nil
    else
      case Integer.parse(token) do
        {n, ""} -> n
        _ -> nil
      end
    end
  end

  # -- UID STORE (flags) helpers -------------------------------------------

  # A STORE command carries either `+FLAGS` or `-FLAGS`, never both — so a
  # combined add+remove call issues up to two sequential commands, UNLESS
  # `unchangedsince` is also set (see `atomic_replace_flags/6` below): two
  # sequential *guarded* STOREs would have the first one's own successful
  # apply bump the message's modseq, making the second deterministically
  # fail its own precondition against a baseline it just invalidated. An
  # empty flag list issues no command at all (nothing to apply) and is
  # trivially `:applied`.
  defp maybe_store(_conn, _uid_str, _sign, [], _unchangedsince), do: {:ok, :applied}

  defp maybe_store(conn, uid_str, sign, flags, unchangedsince) do
    flags_arg = "(" <> Enum.join(flags, " ") <> ")"

    parts =
      case unchangedsince do
        nil -> ["UID", "STORE", uid_str, sign, flags_arg]
        modseq -> ["UID", "STORE", uid_str, "(UNCHANGEDSINCE #{modseq})", sign, flags_arg]
      end

    case send_command(conn, parts) do
      {:ok, :ok, text, _untagged} -> {:ok, store_result(text)}
      other -> command_error(other)
    end
  end

  # A combined add+remove call under `unchangedsince` cannot be split into
  # two sequential guarded STOREs (see `maybe_store/5` above) — the only
  # correct wire form is ONE atomic `FLAGS` replace. That requires knowing
  # the message's full current flag set going in, which the future ops
  # executor has from its own execution-time verification (`opts[:base_flags]`);
  # without it there is no safe way to compute the replacement set, so this
  # raises rather than silently picking a wrong wire form.
  defp atomic_replace_flags(conn, uid_str, add, remove, unchangedsince, opts) do
    case Keyword.get(opts, :base_flags) do
      nil ->
        raise ArgumentError, """
        uid_store_flags/5: combining a non-empty add list AND a non-empty \
        remove list under opts[:unchangedsince] requires opts[:base_flags] \
        (the message's current IMAP flags, from execution-time verification) \
        so a single atomic FLAGS replace can be computed. Without it, issuing \
        two sequential guarded STOREs would have the first one's own \
        successful apply bump the message's modseq, making the second \
        deterministically fail its own UNCHANGEDSINCE precondition.\
        """

      base_flags ->
        flags_arg = "(" <> Enum.join(replace_flags(base_flags, add, remove), " ") <> ")"

        parts = [
          "UID",
          "STORE",
          uid_str,
          "(UNCHANGEDSINCE #{unchangedsince})",
          "FLAGS",
          flags_arg
        ]

        case send_command(conn, parts) do
          {:ok, :ok, text, _untagged} -> {:ok, store_result(text)}
          other -> command_error(other)
        end
    end
  end

  # `final = (base_flags ++ add) -- remove`, deduped and sorted so the
  # resulting `FLAGS (...)` argument is deterministic regardless of
  # `base_flags`/`add` ordering or duplicates.
  defp replace_flags(base_flags, add, remove) do
    remove_set = MapSet.new(remove)

    (base_flags ++ add)
    |> Enum.reject(&MapSet.member?(remove_set, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A CONDSTORE precondition failure (RFC 4551) still comes back as a tagged
  # OK, just with a `MODIFIED` response code in its TEXT rather than a bare
  # completion string — never a `NO`.
  defp store_result(text) do
    if Regex.match?(~r/\[MODIFIED[^\]]*\]/, text), do: :modified, else: :applied
  end

  defp combine_store_status(:modified, _), do: :modified
  defp combine_store_status(_, :modified), do: :modified
  defp combine_store_status(:applied, :applied), do: :applied

  # -- fetch helpers -------------------------------------------------------

  # uid_fetch_meta/uid_fetch_headers take a list of uids but each FETCH is
  # issued one uid at a time: IMAP sequence-set syntax needs the uid list
  # comma-joined as one bare token, and `Wire.encode/2`'s astring/atom
  # quoting rules (deliberately) don't treat comma as unquoted-safe, so a
  # joined "3,5,9" would get wrapped in quotes and become invalid syntax.
  # Looping keeps every argument a single, safely-bare integer.
  defp fetch_each(conn, uids, attr_spec, mapper) do
    uids
    |> Enum.reduce_while({:ok, []}, fn uid, {:ok, acc} ->
      case fetch_one(conn, uid, attr_spec, mapper) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp fetch_one(conn, uid, attr_spec, mapper) do
    case send_command(conn, ["UID", "FETCH", Integer.to_string(uid), attr_spec]) do
      {:ok, :ok, _text, untagged} ->
        case find_fetch_attrs(untagged) do
          nil -> {:error, {:no_fetch_data, uid}}
          attrs -> {:ok, mapper.(attrs)}
        end

      other ->
        command_error(other)
    end
  end

  defp find_fetch_attrs(untagged) do
    Enum.find_value(untagged, fn
      {:fetch, _seq, attrs} -> attrs
      _ -> nil
    end)
  end

  # uid_fetch_flags/2 issues ONE command over a whole sequence-set, so —
  # unlike fetch_each/fetch_one above — every untagged FETCH line in the
  # response is a distinct message and must be collected, not just the
  # first.
  defp collect_fetch_flags(untagged) do
    Enum.flat_map(untagged, fn
      {:fetch, _seq, attrs} ->
        [%{uid: attrs.uid, flags: attrs.flags, modseq: attrs.modseq, gm_msgid: attrs.gm_msgid}]

      _ ->
        []
    end)
  end

  # -- SELECT / SEARCH / LIST response parsing -------------------------

  defp parse_select(untagged) do
    Enum.reduce(untagged, %{uidvalidity: nil, uidnext: nil, highestmodseq: nil}, fn
      {:untagged, line}, acc ->
        acc
        |> put_matched_int(:uidvalidity, line)
        |> put_matched_int(:uidnext, line)
        |> put_matched_int(:highestmodseq, line)

      _, acc ->
        acc
    end)
  end

  defp put_matched_int(acc, :uidvalidity, line) do
    case Regex.run(~r/UIDVALIDITY (\d+)/, line) do
      [_, n] -> %{acc | uidvalidity: String.to_integer(n)}
      nil -> acc
    end
  end

  defp put_matched_int(acc, :uidnext, line) do
    case Regex.run(~r/UIDNEXT (\d+)/, line) do
      [_, n] -> %{acc | uidnext: String.to_integer(n)}
      nil -> acc
    end
  end

  defp put_matched_int(acc, :highestmodseq, line) do
    case Regex.run(~r/HIGHESTMODSEQ (\d+)/, line) do
      [_, n] -> %{acc | highestmodseq: String.to_integer(n)}
      nil -> acc
    end
  end

  defp parse_search_uids(rest) do
    rest
    |> String.split(" ", trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  @list_line_re ~r/^\([^)]*\)\s+(?:"(?:[^"\\]|\\.)*"|\S+)\s+("(?:[^"\\]|\\.)*"|\S+)\s*$/

  defp parse_list_mailbox(rest) do
    case Regex.run(@list_line_re, rest) do
      [_, token] -> unquote_mailbox(token)
      _ -> nil
    end
  end

  defp unquote_mailbox(<<"\"", _::binary>> = token) do
    token
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp unquote_mailbox(token), do: token

  # -- command/response plumbing -------------------------------------------

  defp next_tag(conn) do
    :counters.add(conn.tag, 1, 1)
    "A" <> Integer.to_string(:counters.get(conn.tag, 1))
  end

  # Sends a command as its ordered wire segments (`Wire.encode_command/2`),
  # pausing for a server `{:continuation, _}` before every segment that
  # follows a literal, then reads through to the tagged response. A
  # literal-free command is a single segment and issues no continuation wait,
  # so this is the one code path for every command (LOGIN and APPEND included).
  defp send_command(conn, parts) do
    tag = next_tag(conn)
    segments = Wire.encode_command(tag, parts)
    drive_segments(conn.socket, tag, conn.recv_timeout, segments, "")
  end

  defp drive_segments(socket, tag, timeout, [last], buffer) do
    case :ssl.send(socket, last) do
      :ok -> read_until_tagged(socket, tag, timeout, buffer)
      {:error, reason} -> {:error, reason}
    end
  end

  defp drive_segments(socket, tag, timeout, [segment | rest], buffer) do
    with :ok <- :ssl.send(socket, segment),
         {:ok, _text, buffer} <- read_continuation(socket, timeout, buffer) do
      drive_segments(socket, tag, timeout, rest, buffer)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp command_error({:ok, status, text, _untagged}), do: {:error, {status, text}}
  defp command_error({:error, reason}), do: {:error, reason}

  # Reads responses off `socket` until the one tagged `tag` arrives,
  # returning its status/text plus every response read before it. `buffer`
  # is purely local to this call (see moduledoc "Conn shape").
  defp read_until_tagged(socket, tag, timeout, buffer, acc \\ []) do
    case read_until_response(socket, timeout, buffer) do
      {:ok, {:tagged, ^tag, status, text}, _rest} -> {:ok, status, text, Enum.reverse(acc)}
      {:ok, other, rest} -> read_until_tagged(socket, tag, timeout, rest, [other | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_continuation(socket, timeout, buffer) do
    case read_until_response(socket, timeout, buffer) do
      {:ok, {:continuation, text}, rest} -> {:ok, text, rest}
      {:ok, other, _rest} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Pulls exactly one response off `buffer`, recv'ing more bytes as needed.
  defp read_until_response(socket, timeout, buffer \\ "") do
    case Wire.pull(buffer) do
      {:ok, response, rest} ->
        {:ok, response, rest}

      :incomplete ->
        case :ssl.recv(socket, 0, timeout) do
          {:ok, data} -> read_until_response(socket, timeout, buffer <> data)
          {:error, :timeout} -> {:error, :timeout}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
