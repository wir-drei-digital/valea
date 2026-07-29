defmodule Valea.Mail.Store do
  @moduledoc """
  The mail sync engine's SQLite cache — `Valea.Repo` (per-workspace,
  `AshSqlite.DataLayer`) backed by occurrence-based tables plus a durable
  ops ledger:

    * `mail_sync_state` (`SyncState`) — per-`(account, folder)` watermark
      and lifecycle bits (`UIDVALIDITY`, high-water `UID`,
      `HIGHESTMODSEQ`, `backfill_complete`, `held`).
    * `mail_uid_map` (`UidMap`) — per-`(account, folder, uid)` identity map
      (which `msg_id` a `UID` resolves to, and the flags last synced).
    * `mail_messages` (`MessageIndex`) — per-`(account, folder, uid)`
      OCCURRENCE row (the same `msg_id` can legitimately appear in more
      than one folder; see that resource's moduledoc).
    * `mail_pending_ops` (`PendingOp`) — the durable ops ledger. NOT pure
      cache like the other three: it is the record of in-flight/at-most-once
      side effects against the remote mailbox (see its moduledoc).
    * `mail_search` — the FTS5 full-text index, one row per `(account,
      msg_id)` MESSAGE (not per occurrence). No Ash resource: it is a
      virtual table, so it is reached through raw parameterized SQL in the
      "search index" section at the bottom of this module.

  `mail_sync_state`, `mail_uid_map`, `mail_messages`, and `mail_search` are
  pure cache: rebuildable from `sources/mail/` (+ an IMAP resync) — losing
  `app.sqlite` must never lose data. `mail_pending_ops` is the one
  exception, by design.

  No `AshTypescript` extension — this domain is internal-only, never
  exposed over RPC. The resources under `Valea.Mail.Store.*` stay
  deliberately minimal (one `:upsert`/`:create` action apiece plus one
  narrow `:update` where needed, no timestamps/soft-deletes/relationships
  beyond what's hand-declared); the friendly, task-brief-shaped API below
  is hand-written on top of them rather than generated `code_interface`
  `define`s, because several of these operations (occurrence flag
  conversion, pagination, the ops-ledger claim/transition dance) are small
  pieces of logic, not bare CRUD.

  Task 7 (the `SyncPass` rewrite) retired the `mail_uid_outcomes` bridge
  (`record_outcome/4`, `outcomes/1`, the v3 outcome resource, and the old
  single-argument `clear_folder/1` that wiped it): the pull engine no longer
  tracks per-UID sync outcomes in SQLite (the maildir tree + `mail_uid_map`
  are the durable record now), and nothing else referenced them. Task 10
  retired the last of the pre-occurrence bridge surface the same way: the
  msg_id-keyed message functions (`upsert_message/1`, `get_message/1`,
  `message_by_message_id/1`, `list_messages/0`, `set_message_status/2`) and
  the `mail_inbox_headers`-backed inbox-header family (`put_inbox_header/1`,
  `inbox_headers/0`, `prune_inbox_headers/1`, the v3 header-cache resource)
  are gone — `api/mail.ex`'s account-scoped `list_mail_messages`/
  `get_mail_message` and the deleted v3 inbox action replaced their only
  callers. The final-review fix wave dropped both orphaned tables'
  `create table` statements from the v2 migration (no resource, no caller);
  `up/0` still `drop_if_exists`es them so an existing dev DB is cleaned up.
  """
  use Ash.Domain

  require Ash.Query

  alias Valea.Mail.Store.MessageIndex
  alias Valea.Mail.Store.PendingOp
  alias Valea.Mail.Store.SyncState
  alias Valea.Mail.Store.UidMap

  resources do
    resource SyncState
    resource UidMap
    resource MessageIndex
    resource PendingOp
  end

  # -- sync_state ------------------------------------------------------------

  @doc "The full `mail_sync_state` row for `(account, folder)`."
  @spec get_sync_state(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_sync_state(account, folder) do
    case Ash.get(SyncState, %{account: account, folder: folder}) do
      {:ok, state} -> {:ok, sync_state_map(state)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Upserts (a subset of) `(account, folder)`'s sync-state columns — only the
  keys in `attrs` change; every other column keeps its stored value.

  Ash's `:upsert` action lists every default-bearing column
  (`backfill_complete`, `held`) in `upsert_fields`, and a `:create`
  changeset fills in an attribute's `default:` the moment it's omitted from
  `attrs` — so handing the changeset `attrs` alone would re-apply
  `default: false` for whichever of those two THIS call didn't mention,
  clobbering it back to `false` even though the row already held `true`
  (`mark_held/3` only ever passes `held`; `Valea.Mail.Index.bind_sync_state!`
  only ever passes `dir` + `backfill_complete: false` — either one would
  reset the OTHER flag). Read-modify-write instead: merge `attrs` OVER the
  existing row (defaults only apply when there's no existing row for a key
  to fall back on, i.e. a brand-new `(account, folder)`), so an omitted key
  always preserves what's actually stored.
  """
  @spec put_sync_state(String.t(), String.t(), map()) :: :ok
  def put_sync_state(account, folder, attrs) when is_map(attrs) do
    existing =
      case Ash.get(SyncState, %{account: account, folder: folder}) do
        {:ok, row} -> sync_state_map(row)
        {:error, _} -> %{}
      end

    SyncState
    |> Ash.Changeset.for_create(
      :upsert,
      existing |> Map.merge(attrs) |> Map.merge(%{account: account, folder: folder})
    )
    |> Ash.create!()

    :ok
  end

  @doc "Every `mail_sync_state` row for `account`."
  @spec folders(String.t()) :: [map()]
  def folders(account) do
    SyncState
    |> Ash.Query.filter(account == ^account)
    |> Ash.read!()
    |> Enum.map(&sync_state_map/1)
  end

  @doc "Flips `(account, folder)`'s `held` bit, leaving every other column untouched."
  @spec mark_held(String.t(), String.t(), boolean()) :: :ok
  def mark_held(account, folder, held) do
    put_sync_state(account, folder, %{held: held})
  end

  defp sync_state_map(row) do
    %{
      account: row.account,
      folder: row.folder,
      dir: row.dir,
      uidvalidity: row.uidvalidity,
      high_water_uid: row.high_water_uid,
      highestmodseq: row.highestmodseq,
      backfill_complete: row.backfill_complete,
      held: row.held,
      last_pass_at: row.last_pass_at,
      last_error: row.last_error
    }
  end

  # -- occurrences (UID identity map) -----------------------------------------

  @doc "Upserts `(account, folder, uid)`'s identity-map row. `flags` is a `MapSet` of maildir flag letters."
  @spec put_occurrence(String.t(), String.t(), map()) :: :ok
  def put_occurrence(
        account,
        folder,
        %{uid: uid, uidvalidity: uidvalidity, msg_id: msg_id} = attrs
      ) do
    UidMap
    |> Ash.Changeset.for_create(:upsert, %{
      account: account,
      folder: folder,
      uid: uid,
      uidvalidity: uidvalidity,
      msg_id: msg_id,
      last_synced_flags: flags_to_string(attrs[:flags])
    })
    |> Ash.create!()

    :ok
  end

  defp flags_to_string(nil), do: nil
  defp flags_to_string(%MapSet{} = flags), do: flags |> Enum.sort() |> Enum.join()

  defp flags_from_string(nil), do: MapSet.new()
  defp flags_from_string(""), do: MapSet.new()
  defp flags_from_string(str), do: str |> String.graphemes() |> MapSet.new()

  @doc "Destroys `(account, folder, uid)`'s identity-map row, if any."
  @spec delete_occurrence(String.t(), String.t(), integer()) :: :ok
  def delete_occurrence(account, folder, uid) do
    case Ash.get(UidMap, %{account: account, folder: folder, uid: uid}) do
      {:ok, row} -> Ash.destroy!(row)
      {:error, _} -> :ok
    end

    :ok
  end

  @doc "Every `mail_uid_map` row for `(account, folder)`."
  @spec occurrences(String.t(), String.t()) :: [map()]
  def occurrences(account, folder) do
    UidMap
    |> Ash.Query.filter(account == ^account and folder == ^folder)
    |> Ash.read!()
    |> Enum.map(&occurrence_map/1)
  end

  @doc "Every `mail_uid_map` row for `account` with the given `msg_id`, across every folder."
  @spec occurrences_by_msg_id(String.t(), String.t()) :: [map()]
  def occurrences_by_msg_id(account, msg_id) do
    UidMap
    |> Ash.Query.filter(account == ^account and msg_id == ^msg_id)
    |> Ash.read!()
    |> Enum.map(&occurrence_map/1)
  end

  defp occurrence_map(row) do
    %{
      account: row.account,
      folder: row.folder,
      uid: row.uid,
      uidvalidity: row.uidvalidity,
      msg_id: row.msg_id,
      flags: flags_from_string(row.last_synced_flags)
    }
  end

  # -- index rows (mail_messages occurrences) ---------------------------------

  @doc "Upserts a `mail_messages` occurrence row from `attrs` (must include `account`, `folder`, `uid`)."
  @spec upsert_index_row(map()) :: :ok
  def upsert_index_row(attrs) do
    MessageIndex
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create!()

    :ok
  end

  @doc "Destroys every `mail_messages` row for `(account, folder)`."
  @spec delete_index_rows(String.t(), String.t()) :: :ok
  def delete_index_rows(account, folder) do
    MessageIndex
    |> Ash.Query.filter(account == ^account and folder == ^folder)
    |> Ash.bulk_destroy!(:destroy, %{})

    :ok
  end

  @doc "Destroys the single `mail_messages` row for `(account, folder, uid)`, if any."
  @spec delete_index_row(String.t(), String.t(), integer()) :: :ok
  def delete_index_row(account, folder, uid) do
    case Ash.get(MessageIndex, %{account: account, folder: folder, uid: uid}) do
      {:ok, row} -> Ash.destroy!(row)
      {:error, _} -> :ok
    end

    :ok
  end

  @doc """
  Up to `limit` `mail_messages` rows for `(account, folder)`, newest `date`
  first. `before`, when given, restricts to rows with `date` strictly
  earlier than it (the pagination cursor: pass the last page's oldest
  `date` to fetch the next page).
  """
  @spec list_messages(String.t(), String.t(), pos_integer(), String.t() | nil) :: [map()]
  def list_messages(account, folder, limit \\ 100, before \\ nil) do
    MessageIndex
    |> Ash.Query.filter(account == ^account and folder == ^folder)
    |> then(fn query -> if before, do: Ash.Query.filter(query, date < ^before), else: query end)
    |> Ash.Query.sort(date: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.map(&index_row_map/1)
  end

  @doc "Every `mail_messages` row for `account` with the given `msg_id`, across every folder."
  @spec message_rows_by_msg_id(String.t(), String.t()) :: [map()]
  def message_rows_by_msg_id(account, msg_id) do
    MessageIndex
    |> Ash.Query.filter(account == ^account and msg_id == ^msg_id)
    |> Ash.read!()
    |> Enum.map(&index_row_map/1)
  end

  defp index_row_map(row) do
    %{
      account: row.account,
      folder: row.folder,
      uid: row.uid,
      msg_id: row.msg_id,
      message_id: row.message_id,
      from_name: row.from_name,
      from_email: row.from_email,
      subject: row.subject,
      date: row.date,
      flags: row.flags,
      has_attachments: row.has_attachments,
      path: row.path,
      in_reply_to: row.in_reply_to,
      references: row.references
    }
  end

  # -- folder reset ------------------------------------------------------------

  @doc """
  Wipes `(account, folder)`'s sync watermark, identity map, and message
  occurrence rows — the reset a `UIDVALIDITY` mismatch (or a folder
  replacement) demands. Other folders/accounts are untouched.
  """
  @spec clear_folder(String.t(), String.t()) :: :ok
  def clear_folder(account, folder) do
    SyncState
    |> Ash.Query.filter(account == ^account and folder == ^folder)
    |> Ash.bulk_destroy!(:destroy, %{})

    UidMap
    |> Ash.Query.filter(account == ^account and folder == ^folder)
    |> Ash.bulk_destroy!(:destroy, %{})

    MessageIndex
    |> Ash.Query.filter(account == ^account and folder == ^folder)
    |> Ash.bulk_destroy!(:destroy, %{})

    :ok
  end

  # -- search index (mail_search, FTS5) ----------------------------------------

  # Column ordinals of the `mail_search` virtual table, in declaration order
  # (`20260729000001_mail_search_index.exs`): 0 account, 1 msg_id,
  # 2 from_text, 3 subject, 4 body. `snippet/6` addresses a column by
  # ordinal, so this number and that migration move together.
  @body_column 4

  # A snippet is a reading aid, not the message: ~16 tokens of body around
  # the best-matching window, ellipsed on both sides. No highlight markers —
  # the search UI (task 9) decides its own presentation.
  @snippet_tokens 16

  # Hard caps on what a single query may ask for. `@max_query_bytes` and
  # `@max_terms` bound the work one MATCH can demand (a 50k-character
  # paste, a thousand prefix terms); `@max_limit` bounds the rows a caller
  # can pull back regardless of what it passes.
  @max_query_bytes 256
  @max_terms 16
  @max_limit 200

  @search_sql """
  SELECT msg_id, snippet(mail_search, #{@body_column}, '', '', '…', #{@snippet_tokens})
  FROM mail_search
  WHERE mail_search MATCH ?1 AND account = ?2
  ORDER BY rank
  LIMIT ?3
  """

  @doc """
  Up to `limit` full-text hits for `query` within `account`, best match
  first (FTS5's default `bm25` `rank`), as `%{msg_id:, snippet:}` maps.
  `snippet` is a body excerpt around the match.

  `query` is USER INPUT and is never FTS5 query syntax: it goes through
  `match_expression/1` (below), which is the only thing that ever builds
  the `MATCH` argument. An empty query, one that tokenizes to nothing
  (`"!!!"`), or one longer than #{@max_query_bytes} bytes short-circuits to
  `[]` without touching the database. `limit` is clamped to
  1..#{@max_limit}.

  Rows are deduped by `msg_id` — the writers below keep one row per
  `(account, msg_id)`, and this is belt-and-braces so a duplicate that
  somehow survived (an interrupted re-land, see `insert_search_row/3`)
  never surfaces as the same message twice.
  """
  @spec search(String.t(), String.t(), integer()) :: [%{msg_id: String.t(), snippet: String.t()}]
  def search(account, query, limit \\ 40) when is_binary(account) and is_binary(query) do
    case match_expression(query) do
      :none ->
        []

      {:ok, match} ->
        %{rows: rows} = Valea.Repo.query!(@search_sql, [match, account, clamp_limit(limit)])

        rows
        |> Enum.map(fn [msg_id, snippet] -> %{msg_id: msg_id, snippet: snippet} end)
        |> Enum.uniq_by(& &1.msg_id)
    end
  end

  @doc """
  The ONE place an FTS5 `MATCH` expression is built, and the reason no FTS5
  query syntax is reachable from user input: `query` is TOKENIZED here (runs
  of letters/digits, matching what the table's `unicode61` tokenizer indexes)
  and each token is re-emitted as a double-quoted prefix term — `foo bar`
  becomes `"foo"* "bar"*`, which FTS5 reads as an implicit AND of two prefix
  matches.

  Because a token can only ever contain letters and digits, nothing that
  means something to the FTS5 query parser can survive the transform:

    * boolean/proximity keywords (`OR`, `AND`, `NOT`, `NEAR`) come back out
      as ordinary quoted terms (`"OR"*` matches the literal word "or");
    * a column filter (`subject:foo`) splits into `"subject"* "foo"*`;
    * `-`, `^`, `(`, `)`, `*`, `:` and `"` are all separators, so they are
      dropped rather than escaped — an unbalanced or embedded quote cannot
      close the quoting this function opens, because no quote reaches it;
    * an all-punctuation query yields no tokens at all and returns `:none`.

  `:none` is "there is nothing to search for" — an empty/blank query, a
  query with no alphanumeric content, or one over #{@max_query_bytes} bytes.
  At most #{@max_terms} terms are kept.
  """
  @spec match_expression(String.t()) :: {:ok, String.t()} | :none
  def match_expression(query) when is_binary(query) do
    if byte_size(query) > @max_query_bytes do
      :none
    else
      query
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.take(@max_terms)
      |> case do
        [] -> :none
        terms -> {:ok, Enum.map_join(terms, " ", &~s["#{&1}"*])}
      end
    end
  end

  def match_expression(_query), do: :none

  # `Kernel.max/2`/`Kernel.min/2` spelled out: `use Ash.Domain` defines
  # local `max/2`/`min/2` (the aggregate builders), which shadow the
  # auto-imported Kernel pair inside this module.
  defp clamp_limit(limit) when is_integer(limit),
    do: limit |> Kernel.max(1) |> Kernel.min(@max_limit)

  defp clamp_limit(_limit), do: @max_limit

  @doc """
  Inserts `(account, msg_id)`'s search row WITHOUT first deleting any
  existing one — for callers that have just established there can't be one:
  `Valea.Mail.Views.land/4` landing a msg_id that held nothing before, and
  `Valea.Mail.Index.rebuild/2` re-feeding a just-truncated index.

  The distinction is not micro-optimization. `msg_id` is `UNINDEXED`, so a
  `DELETE ... WHERE account = ? AND msg_id = ?` is a FULL SCAN of the FTS
  content (see `replace_search_row/3`) — doing one per landed message would
  make an initial backfill quadratic in the size of the mailbox. Landing is
  the one path that runs once per message in the account, so it must not
  pay for a row it knows isn't there.

  `attrs` is `%{from_text:, subject:, body:}`; a `nil` field stores `""`.
  """
  @spec insert_search_row(String.t(), String.t(), map()) :: :ok
  def insert_search_row(account, msg_id, attrs)
      when is_binary(account) and is_binary(msg_id) and is_map(attrs) do
    with_repo(fn ->
      Valea.Repo.query!(
        """
        INSERT INTO mail_search (account, msg_id, from_text, subject, body)
        VALUES (?1, ?2, ?3, ?4, ?5)
        """,
        [account, msg_id, text(attrs[:from_text]), text(attrs[:subject]), text(attrs[:body])]
      )
    end)
  end

  @doc """
  Replaces `(account, msg_id)`'s search row: deletes whatever is stored for
  that pair, then inserts `attrs`. The general, always-correct upsert — used
  where a view file is REWRITTEN under a msg_id that may already carry a row.

  Both statements run in one transaction, so an interrupted replace can
  never leave the message unsearchable or doubly-indexed.
  """
  @spec replace_search_row(String.t(), String.t(), map()) :: :ok
  def replace_search_row(account, msg_id, attrs)
      when is_binary(account) and is_binary(msg_id) and is_map(attrs) do
    with_repo(fn ->
      Valea.Repo.transaction(fn ->
        delete_search_row!(account, msg_id)

        Valea.Repo.query!(
          """
          INSERT INTO mail_search (account, msg_id, from_text, subject, body)
          VALUES (?1, ?2, ?3, ?4, ?5)
          """,
          [account, msg_id, text(attrs[:from_text]), text(attrs[:subject]), text(attrs[:body])]
        )
      end)
    end)
  end

  @doc """
  Deletes `(account, msg_id)`'s search row, if any. Called on the FINAL
  removal of a message (`Valea.Mail.Views.remove_occurrence/4` with
  `remaining: 0`) — a message that still occurs in another folder keeps its
  view file and stays searchable.
  """
  @spec delete_search_row(String.t(), String.t()) :: :ok
  def delete_search_row(account, msg_id) when is_binary(account) and is_binary(msg_id) do
    with_repo(fn -> delete_search_row!(account, msg_id) end)
  end

  @doc "Deletes every `mail_search` row for `account` — `Valea.Mail.Index.rebuild/2`'s truncate."
  @spec clear_search_rows(String.t()) :: :ok
  def clear_search_rows(account) when is_binary(account) do
    with_repo(fn ->
      Valea.Repo.query!("DELETE FROM mail_search WHERE account = ?1", [account])
    end)
  end

  defp delete_search_row!(account, msg_id) do
    Valea.Repo.query!("DELETE FROM mail_search WHERE account = ?1 AND msg_id = ?2", [
      account,
      msg_id
    ])
  end

  # The search index is DERIVED state and its writers sit on the file-first
  # landing path (`Valea.Mail.Views`), which must keep working when there is
  # no open workspace database to write to — a straggler land as a workspace
  # closes, or a pure-filesystem caller (`views_test.exs`) that never starts
  # a repo. Those write a view file and simply leave the index unfed;
  # `Valea.Mail.Index.rebuild/2` is the repair path. A repo that IS running
  # and then fails is NOT swallowed: the `query!` raises, exactly like every
  # other write in this module.
  defp with_repo(fun) do
    if is_pid(Process.whereis(Valea.Repo)), do: fun.()
    :ok
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  # -- pending ops ledger ------------------------------------------------------

  @doc """
  Creates a `mail_pending_ops` row. `id` is generated (`Ash.UUID`) unless
  already present in `attrs`. Returns `{:error, :duplicate_active}` when
  `attrs` would violate the one-non-terminal-outbound-op-per-`(account,
  origin)` partial unique index (`mail_pending_ops_active_outbound`, which
  spans `append` AND `send` — a draft can never be pushed and sent at
  once, nor sent twice from two tabs).
  """
  @spec create_pending_op(map()) :: {:ok, map()} | {:error, :duplicate_active}
  def create_pending_op(attrs) do
    now = now_iso8601()

    full_attrs =
      attrs
      |> Map.put_new_lazy(:id, &Ash.UUID.generate/0)
      |> Map.put_new(:inserted_at, now)
      |> Map.put_new(:updated_at, now)

    PendingOp
    |> Ash.Changeset.for_create(:create, full_attrs)
    |> Ash.create()
    |> case do
      {:ok, op} ->
        {:ok, pending_op_map(op)}

      {:error, error} ->
        # ONLY the atomic-claim violation maps to :duplicate_active; any
        # other create failure (a NOT NULL violation, a bad type, ...) is a
        # programmer error and must stay loud, not masquerade as a
        # legitimately-contended claim.
        if duplicate_active?(error), do: {:error, :duplicate_active}, else: raise(error)
    end
  rescue
    # Belt-and-braces: a raw unique-index violation should already come back
    # as `{:error, _}` from `Ash.create/1` (ash_sqlite parses the SQLite
    # "UNIQUE constraint failed" message itself), but this table's
    # uniqueness rule is a hand-written partial index with no matching Ash
    # `identity` declaration — catch the underlying driver exception too, in
    # case some future ash_sqlite version stops normalizing it.
    error in [Exqlite.Error] ->
      if error.message =~ "UNIQUE constraint failed",
        do: {:error, :duplicate_active},
        else: reraise(error, __STACKTRACE__)
  end

  # ash_sqlite turns "UNIQUE constraint failed: mail_pending_ops.account,
  # mail_pending_ops.origin" into one `InvalidAttribute` per parsed column
  # (`:account`, `:origin`) with the default "has already been taken"
  # message (no identity/custom-index declaration matches the partial
  # index, so no custom message applies) — that exact shape, wrapped in an
  # error-class struct with an `errors` list, is the claim violation.
  defp duplicate_active?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &duplicate_active?/1)

  defp duplicate_active?(%Ash.Error.Changes.InvalidAttribute{field: field})
       when field in [:account, :origin],
       do: true

  defp duplicate_active?(_error), do: false

  @doc """
  Transitions `id`'s `mail_pending_ops` row to `state`, merging any of
  `error`/`uid`/`dest_watermark`/`dest_uidvalidity`/`updated_at` present in
  `extra`. `updated_at` defaults to now unless `extra` overrides it. A
  silent no-op (not an error) when `id` isn't found.
  """
  @spec transition_op(String.t(), String.t(), map()) :: :ok
  def transition_op(id, state, extra \\ %{}) do
    case Ash.get(PendingOp, id) do
      {:ok, op} ->
        attrs =
          extra
          |> Map.take([
            :error,
            :uid,
            :dest_watermark,
            :dest_uidvalidity,
            :spool_path,
            :payload_sha256,
            :content_hash,
            :wire_sha256,
            :record_sha256,
            :envelope_rcpt,
            :updated_at
          ])
          |> Map.put_new(:updated_at, now_iso8601())
          |> Map.put(:state, state)

        op
        |> Ash.Changeset.for_update(:transition, attrs)
        |> Ash.update!()

        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Every `mail_pending_ops` row for `account` still in flight. The states
  are exactly the non-terminal ones the claim index treats as active:
  `claimed`/`pending`/`executing`/`needs_review` plus the send-only
  `transmitted` (out, Sent copy not filed yet) and `send_review` (outcome
  unknowable, parked for the human) — both of which the recovery paths
  must keep seeing until they resolve.
  """
  @spec pending_ops(String.t()) :: [map()]
  def pending_ops(account) do
    PendingOp
    |> Ash.Query.filter(
      account == ^account and
        state in [
          "claimed",
          "pending",
          "executing",
          "needs_review",
          "transmitted",
          "send_review"
        ]
    )
    |> Ash.read!()
    |> Enum.map(&pending_op_map/1)
  end

  @doc """
  Every `mail_pending_ops` row for `(account, origin)`, ANY state, NEWEST
  FIRST — the push flow's corroboration lookup (a non-`draft` frontmatter
  status is allowed only when a prior engine-written op for this draft
  exists) and `list_mail_drafts`'s ledger-derived display projection, both
  of which must see terminal (`complete`/`rejected`) rows the active-only
  `pending_ops/1` filters out.

  The ordering is load-bearing for the projection (spec G, §Display
  projection): with two op kinds sharing one origin, the NEWEST terminal
  send op governs the displayed state — a push completed last week must
  not outrank a send rejected a minute ago.
  """
  @spec ops_by_origin(String.t(), String.t()) :: [map()]
  def ops_by_origin(account, origin) do
    PendingOp
    |> Ash.Query.filter(account == ^account and origin == ^origin)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!()
    |> Enum.map(&pending_op_map/1)
  end

  @doc """
  Every `mail_pending_ops` move row for `(account, msg_id, source_folder)`, in
  ANY state — the ops-file move-replay status lookup, which must distinguish a
  resolved terminal (`complete`/`rejected`) move from one whose row is genuinely
  MISSING (the active-only `pending_ops/1` hides terminal rows, conflating the
  two). After database loss the orphan-manifest sweep recreates the row before
  this runs, so a `[]` here means there was never a durable record to reconcile.
  """
  @spec move_ops(String.t(), String.t(), String.t()) :: [map()]
  def move_ops(account, msg_id, source_folder) do
    PendingOp
    |> Ash.Query.filter(
      account == ^account and kind == "move" and msg_id == ^msg_id and
        source_folder == ^source_folder
    )
    |> Ash.read!()
    |> Enum.map(&pending_op_map/1)
  end

  @doc "The `mail_pending_ops` row for `id`."
  @spec op_by_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def op_by_id(id) do
    case Ash.get(PendingOp, id) do
      {:ok, op} -> {:ok, pending_op_map(op)}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp pending_op_map(row) do
    %{
      id: row.id,
      kind: row.kind,
      account: row.account,
      source_folder: row.source_folder,
      target_folder: row.target_folder,
      uid: row.uid,
      source_uidvalidity: row.source_uidvalidity,
      dest_watermark: row.dest_watermark,
      dest_uidvalidity: row.dest_uidvalidity,
      message_id: row.message_id,
      msg_id: row.msg_id,
      origin: row.origin,
      spool_path: row.spool_path,
      payload_sha256: row.payload_sha256,
      content_hash: row.content_hash,
      wire_sha256: row.wire_sha256,
      record_sha256: row.record_sha256,
      envelope_rcpt: row.envelope_rcpt,
      state: row.state,
      error: row.error,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
