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

  ## The IDLE trio (`idle_start/1`, `idle_await/3`, `idle_done/2`)

  ADDITIVE, and the only growth this behaviour has taken since that copy:
  the spec's §Transport behaviour predates the full-client plan's M5, whose
  `Valea.Mail.IdleWatcher` needs primitives the connect-per-pass callbacks
  above cannot express. No existing callback's shape changed.

  They are deliberately *session-threading* rather than stateful: `conn` is
  immutable and no callback but `connect/3` hands one back, so an IDLE — the
  one exchange where the server writes bytes nobody asked for, possibly
  splitting a response across two reads — carries its own opaque `idle()`
  session value (the pending-response buffer plus whatever the
  implementation needs to recognize its own tagged completion). Threading it
  through the caller keeps residual bytes from being silently dropped
  between awaits without giving `conn` a mutable read buffer that every
  other callback would then have to reason about.

  Gating is `supports?(conn, :idle)`, never a blind `idle_start/1`: RFC 2177
  requires the `IDLE` capability, and a server without it must be left on the
  poll loop rather than probed.
  """

  @type conn :: term()

  @typedoc """
  The connection-shaped settings `connect/3` reads — built by
  `Valea.Mail.Settings.imap_config/1`, which is what stamps `auth` (the
  account's SASL mode, M6 task 15) onto the `imap:` block. Optional in the
  type because every caller predating that mode passes the three-key map, and
  an implementation must read its absence as `:password`.
  """
  @type config :: %{
          :host => String.t(),
          :port => pos_integer(),
          :username => String.t(),
          optional(:auth) => Valea.Mail.Settings.auth()
        }

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

  @type capability :: :condstore | :qresync | :move | :uidplus | :gmail | :idle | :xoauth2

  @typedoc """
  One in-progress IDLE, opaque to callers — created by `idle_start/1`,
  threaded through `idle_await/3`, consumed by `idle_done/2`. Never inspected
  or constructed outside the implementation that returned it.
  """
  @type idle :: term()

  @typedoc """
  One untagged response observed while idling, already parsed off the wire by
  the implementation (the caller never sees IMAP bytes).

  `:exists`, `:expunge` and `:fetch` carry the message SEQUENCE number the
  server reported — the three untagged responses that mean "this mailbox
  changed" (a new message, a removed one, a flag change). Sequence numbers
  are useless to this codebase (every command it issues is UID-based), so
  they are carried for logging/diagnostics only; the watcher reacts to the
  event's KIND, then re-syncs by UID like everything else.

  `:other` is any other untagged line, verbatim and uninterpreted — a
  `* OK Still here` keepalive, a `* FLAGS (...)` re-announcement. It must
  never be read as mailbox change: a server that sends a periodic untagged OK
  would otherwise trigger a sync pass on every heartbeat, forever.
  """
  @type idle_event ::
          {:exists, pos_integer()}
          | {:expunge, pos_integer()}
          | {:fetch, pos_integer()}
          | {:other, String.t()}

  @doc """
  Opens an authenticated connection. `credential` is the account's password or
  — when `config.auth` is `:oauth2` — its OAuth2 access token; the
  implementation picks the SASL mechanism from that mode alone.

  Two error reasons are part of the contract because callers discriminate on
  them (`Valea.Mail.SyncPass`, `Valea.Mail.Engine`, `Valea.Mail.Doctor`):
  `{:error, :auth_failed}` for a rejected password and
  `{:error, :reauth_required}` for a rejected token. Both mean "the server
  spoke, and said no" — every other reason is a transport failure.
  """
  @callback connect(config, credential :: String.t(), opts :: keyword()) ::
              {:ok, conn} | {:error, :auth_failed} | {:error, :reauth_required} | {:error, term()}
  @callback capabilities(conn) :: {:ok, [String.t()]}
  @callback list_folders(conn) :: {:ok, [String.t()]} | {:error, term()}
  @callback create_folder(conn, String.t()) :: :ok | {:error, term()}

  @doc """
  Opens `folder` for reading and writing.

  ## The one named failure: `{:error, {:no_such_mailbox, folder}}`

  Every other failure reason is opaque, but this one is part of the
  contract, because callers discriminate on it: it is the server DEFINITELY
  ANSWERING "there is no such mailbox", as opposed to the mailbox's contents
  being merely unknown right now. The distinction is load-bearing for
  `Valea.Mail.OpsExecutor`'s search-first idempotency guards — an
  unanswerable question can never be read as "not present" (it would
  duplicate an append), while a mailbox the server says does not exist
  provably holds nothing.

  So the bar is deliberately HIGH, and an implementation must report this
  reason only on a definite answer. `Valea.Mail.ImapClient` draws it at a
  tagged `NO` carrying a machine-readable response code that names
  nonexistence — `[NONEXISTENT]` (RFC 5530) or `[TRYCREATE]` (RFC 3501
  §6.3.11) — and NOTHING else: a bare `NO` with no response code, a `BAD`, a
  timeout, a dropped connection and every transport failure stay opaque.
  When in doubt, an implementation reports an opaque reason; the cost of
  that is one deferred retry, whereas a wrong `:no_such_mailbox` risks a
  duplicated message.
  """
  @callback select(conn, String.t()) ::
              {:ok, select_info()} | {:error, {:no_such_mailbox, String.t()}} | {:error, term()}
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

  Reports `{:error, {:no_such_mailbox, folder}}` under exactly the same
  definite-answer rule as `select/2` — see its docs.
  """
  @callback examine(conn, String.t()) ::
              {:ok, select_info()} | {:error, {:no_such_mailbox, String.t()}} | {:error, term()}

  @doc "Whether the connected server advertises `capability`."
  @callback supports?(conn, capability()) :: boolean()

  @callback logout(conn) :: :ok

  @doc """
  Enters IDLE (RFC 2177) on the CURRENTLY SELECTED folder — the caller must
  have run `examine/2` (read-only by design: an IDLE connection never needs
  `select/2`'s write access, and `examine/2` cannot disturb `\\Recent`) first.

  Sends `IDLE` and returns only once the server has answered with its `+`
  continuation, so `{:ok, idle}` means the connection is genuinely idling. A
  server that answers the IDLE with a tagged `NO`/`BAD` instead (it can, even
  while advertising the capability — an over-quota or read-only-mode mailbox)
  is `{:error, {status, text}}`, not a hang.

  Untagged responses that arrive BEFORE the continuation (a server flushing a
  pending `EXISTS` as it enters IDLE) are not discarded — they ride in the
  returned session and come back out of the first `idle_await/3`.
  """
  @callback idle_start(conn) :: {:ok, idle()} | {:error, term()}

  @doc """
  Waits up to `timeout_ms` for untagged activity on an idling connection.

  Returns as soon as at least one complete untagged response has arrived —
  `{:ok, events, idle}` with the threaded session — or, when the timeout
  elapses first, `{:ok, [], idle}`. An empty list is therefore a normal
  deadline, NOT an error: it is how the caller's re-issue timer surfaces.

  `{:error, reason}` is a genuinely dead or hijacked connection: a socket
  error, or the server terminating the IDLE on its own (a tagged completion
  arriving with no `DONE` sent). Either way the session is over — the caller
  must reconnect rather than await again.
  """
  @callback idle_await(conn, idle(), timeout_ms :: non_neg_integer()) ::
              {:ok, [idle_event()], idle()} | {:error, term()}

  @doc """
  Leaves IDLE: sends `DONE` and reads through the tagged completion.

  Returns the untagged events that arrived inside that handshake window
  (`{:ok, events}`) — never dropping them. The window is real: a message can
  land in the microseconds between `DONE` leaving the client and the server's
  completion, and those events are the caller's only notice of it.

  The connection is left in the selected state, usable for another
  `idle_start/1` or an ordinary command.
  """
  @callback idle_done(conn, idle()) :: {:ok, [idle_event()]} | {:error, term()}
end
