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
    * **Connect-per-pass.** No persistent connections, no IDLE. `connect/3`
      reads the greeting, logs in, then re-queries `CAPABILITY` (some
      servers advertise a different set once authenticated) — the cached
      set on `conn` is always the post-login one.
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
      variable. This is safe because the protocol here is strictly
      request/response with no pipelining and no IDLE: the server only
      ever writes bytes in reaction to the command it just received, so a
      given call's socket reads can never contain bytes belonging to a
      future call's response.
  """

  @behaviour Valea.Mail.Transport

  alias Valea.Mail.Imap.Wire

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
             {:ok, conn} <- login(conn, username, credential),
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
    attr_spec =
      if supports?(conn, :gmail),
        do: "(UID FLAGS MODSEQ X-GM-MSGID)",
        else: "(UID FLAGS MODSEQ)"

    case send_command(conn, ["UID", "FETCH", uid_set, attr_spec]) do
      {:ok, :ok, _text, untagged} -> {:ok, collect_fetch_flags(untagged)}
      other -> command_error(other)
    end
  end

  @impl true
  def uid_store_flags(conn, uid, add, remove, opts \\ []) do
    unchangedsince = Keyword.get(opts, :unchangedsince)
    uid_str = Integer.to_string(uid)

    with {:ok, add_status} <- maybe_store(conn, uid_str, "+FLAGS", add, unchangedsince),
         {:ok, remove_status} <- maybe_store(conn, uid_str, "-FLAGS", remove, unchangedsince) do
      {:ok, combine_store_status(add_status, remove_status)}
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

  # -- COPYUID / APPENDUID response-code parsing -------------------------
  #
  # Per RFC 4315 (UIDPLUS) and RFC 6851 (MOVE), the destination UID rides in
  # the TEXT of the tagged OK response, never as a separate untagged line:
  # `A3 OK [COPYUID <uidvalidity> <src-uid-set> <dest-uid-set>] ...` or
  # `A3 OK [APPENDUID <uidvalidity> <dest-uid>] ...`. Absent (a server that
  # doesn't report it) parses to `nil` rather than erroring — the caller
  # still has a successful move/copy/append, just without a known dest UID.

  defp parse_copyuid_dest(text) do
    case Regex.run(~r/COPYUID \d+ \S+ (\d+)/, text) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp parse_appenduid_dest(text) do
    case Regex.run(~r/APPENDUID \d+ (\d+)/, text) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  # -- UID STORE (flags) helpers -------------------------------------------

  # A STORE command carries either `+FLAGS` or `-FLAGS`, never both — so a
  # combined add+remove call issues up to two sequential commands. An empty
  # flag list issues no command at all (nothing to apply) and is trivially
  # `:applied`.
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
