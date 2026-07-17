defmodule Valea.Mail.Transport do
  @moduledoc """
  The IMAP operations `Valea.Mail.Engine` needs, independent of the
  underlying wire client. `Valea.Mail.ImapClient` is the real (`:ssl`
  socket) implementation; tests inject a fake per `FakeMailTransport`.

  Copied verbatim from the mail design spec (§Transport behaviour) — every
  later task types against this exact callback list and these exact
  signatures. Do not change a callback's shape here without updating every
  consumer.

  One deliberate deviation from that original copy: `list_folders/1`'s
  return type is widened to admit `{:error, term()}` — `ImapClient.list_folders/1`
  already surfaces a failed `LIST` command that way (via `command_error/1`),
  so the callback type now matches what the real implementation actually
  does rather than promising unconditional success.
  """

  @type conn :: term()
  @type config :: %{host: String.t(), port: pos_integer(), username: String.t()}

  @type select_info :: %{
          uidvalidity: integer(),
          uidnext: integer() | nil,
          highestmodseq: integer() | nil
        }

  @type fetch_flags_result :: %{
          uid: pos_integer(),
          flags: [String.t()],
          modseq: integer() | nil,
          gm_msgid: String.t() | nil
        }

  @type capability :: :condstore | :qresync | :move | :uidplus | :gmail

  @callback connect(config, credential :: String.t(), opts :: keyword()) ::
              {:ok, conn} | {:error, term()}
  @callback capabilities(conn) :: {:ok, [String.t()]}
  @callback list_folders(conn) :: {:ok, [String.t()]} | {:error, term()}
  @callback create_folder(conn, String.t()) :: :ok | {:error, term()}
  @callback select(conn, String.t()) :: {:ok, select_info()} | {:error, term()}
  @callback uid_search(conn, String.t()) :: {:ok, [pos_integer()]} | {:error, term()}
  @callback uid_fetch_meta(conn, [pos_integer()]) ::
              {:ok, [%{uid: pos_integer(), size: non_neg_integer()}]} | {:error, term()}
  @callback uid_fetch_headers(conn, [pos_integer()]) ::
              {:ok, [%{uid: pos_integer(), header: binary()}]} | {:error, term()}
  @callback uid_fetch_full(conn, pos_integer()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Fetches `UID FLAGS` for `uid_set`, an IMAP sequence-set string ("1:*" or
  "5,9,12") sent verbatim as a single command. `MODSEQ` is additionally
  requested — and `modseq` populated in the result — only when the
  connection is `:condstore`-capable (a non-CONDSTORE server may `BAD` the
  whole FETCH over an attribute it doesn't understand); otherwise every
  result's `modseq` is `nil`. `X-GM-MSGID` is likewise requested (and
  populated) only when the server is `:gmail`-capable.
  """
  @callback uid_fetch_flags(conn, uid_set :: String.t()) ::
              {:ok, [fetch_flags_result()]} | {:error, term()}

  @doc """
  `UID STORE <uid> [(UNCHANGEDSINCE <n>)] +FLAGS/-FLAGS (...)`.
  `opts[:unchangedsince]`, when present, adds the CONDSTORE precondition; a
  server response reporting the message as `MODIFIED` (precondition failed)
  is `{:ok, :modified}` rather than an error — the caller treats it as a
  changed baseline, not a failure.

  When BOTH `add` and `remove` are non-empty AND `opts[:unchangedsince]` is
  set, this cannot be issued as two sequential guarded STOREs: the first
  one's own successful apply would bump the message's modseq, making the
  second deterministically fail its own precondition against a baseline it
  just invalidated. In that case the callback instead REQUIRES
  `opts[:base_flags]` (the message's current IMAP flags, as known by the
  caller from its own execution-time verification) and issues ONE atomic
  replace — `UID STORE <uid> (UNCHANGEDSINCE <n>) FLAGS (<final>)` where
  `final = (base_flags ++ add) -- remove`, deduped — reporting `:modified`
  or `:applied` from that single command exactly as above. If
  `opts[:base_flags]` is absent in that combined+guarded case, the callback
  raises `ArgumentError` rather than guessing at a wire form that could
  silently corrupt the flag set. Single-direction calls (only `add` or only
  `remove` non-empty) and combined calls WITHOUT `unchangedsince` are
  unaffected by this and behave as a plain `+FLAGS`/`-FLAGS` store (or two
  sequential unguarded ones).
  """
  @callback uid_store_flags(
              conn,
              pos_integer(),
              add :: [String.t()],
              remove :: [String.t()],
              opts :: keyword()
            ) :: {:ok, :applied} | {:ok, :modified} | {:error, term()}

  @doc """
  NARROWED to native `UID MOVE` only (the `MOVE` capability). Without it,
  `{:unsupported, _}` — no `UID COPY` + `STORE` + `EXPUNGE` fallback ladder
  inside this callback; that ladder lives in the ops executor (Task 13),
  which needs per-step control to confirm before expunging. `dest_uid` comes
  from the `COPYUID` response code on the tagged OK, when present — and is
  `nil` (unknown, not a guess) when that response code's destination
  uid-set is a range/list shape (e.g. `90:92`) rather than a single uid.
  """
  @callback uid_move(conn, pos_integer(), String.t()) ::
              {:ok, %{dest_uid: pos_integer() | nil}}
              | {:error, term()}
              | {:unsupported, String.t()}

  @doc """
  `UID COPY <uid> <dest>`; `dest_uid` from the `COPYUID` response code, or
  `nil` when absent or when the destination uid-set is a range/list shape
  rather than a single uid (the caller falls back to search-based
  confirmation in that case).
  """
  @callback uid_copy(conn, pos_integer(), String.t()) ::
              {:ok, %{dest_uid: pos_integer() | nil}} | {:error, term()}

  @doc """
  The ONE sanctioned place in the codebase that stores `\\Deleted`
  (`UID STORE <uid> +FLAGS (\\Deleted)`) — callable only by the executor's
  move ladder (Task 13), never elsewhere.
  """
  @callback uid_mark_deleted(conn, pos_integer()) :: :ok | {:error, term()}

  @doc "Targeted `UID EXPUNGE <uid>` (UIDPLUS) — never a bare `EXPUNGE`."
  @callback uid_expunge(conn, pos_integer()) :: :ok | {:error, term()}

  @doc """
  CHANGED return: `dest_uid` from the `APPENDUID` response code when the
  server is UIDPLUS-capable, else `nil` — also `nil` when that response
  code's destination uid-set is a range/list shape rather than a single
  uid.
  """
  @callback append(conn, folder :: String.t(), flags :: [String.t()], rfc822 :: binary()) ::
              {:ok, %{dest_uid: pos_integer() | nil}} | {:error, term()}

  @doc """
  Read-only `EXAMINE` (never `SELECT`) — required by the ops executor
  (Task 13) for write-through destination watermarks and Gmail membership
  proofs; never alters `\\Recent` or any other server state.
  """
  @callback examine(conn, String.t()) :: {:ok, select_info()} | {:error, term()}

  @doc "Whether the connected server advertises `capability`."
  @callback supports?(conn, capability()) :: boolean()

  @callback logout(conn) :: :ok
end
