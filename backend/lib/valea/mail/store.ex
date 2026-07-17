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

  `mail_sync_state`, `mail_uid_map`, and `mail_messages` are pure cache:
  rebuildable from `sources/mail/` (+ an IMAP resync) — losing `app.sqlite`
  must never lose data. `mail_pending_ops` is the one exception, by design.

  No `AshTypescript` extension — this domain is internal-only, never
  exposed over RPC. The resources under `Valea.Mail.Store.*` stay
  deliberately minimal (one `:upsert`/`:create` action apiece plus one
  narrow `:update` where needed, no timestamps/soft-deletes/relationships
  beyond what's hand-declared); the friendly, task-brief-shaped API below
  is hand-written on top of them rather than generated `code_interface`
  `define`s, because several of these operations (occurrence flag
  conversion, pagination, the ops-ledger claim/transition dance) are small
  pieces of logic, not bare CRUD.

  ## TEMP v3-bridge (mail-as-maildir rebuild, Task 3)

  `index.ex`, `engine.ex`, `api/mail.ex`, and `cockpit.ex` (rewritten in
  Tasks 9-10) still call the OLD, pre-occurrence Store API:
  `get_sync_state/1`, `put_sync_state/3` (3-arg, no `attrs` map),
  `upsert_message/1`, `get_message/1`, `message_by_message_id/1`,
  `list_messages/0`, `set_message_status/2`, `put_inbox_header/1`,
  `inbox_headers/0`, `prune_inbox_headers/1`. Every function below marked
  `# TEMP v3-bridge` keeps that old surface alive on top of the NEW tables
  (or, for the inbox-header family, on top of the OLD `mail_inbox_headers`
  table — see `Valea.Mail.Store.InboxHeader`'s moduledoc for why that
  table/resource is kept alive verbatim rather than emulated).

  Task 7 (the `SyncPass` rewrite) retired the `mail_uid_outcomes` bridge
  (`record_outcome/4`, `outcomes/1`, `UidOutcome`, and the old
  single-argument `clear_folder/1` that wiped it): the pull engine no longer
  tracks per-UID sync outcomes in SQLite (the maildir tree + `mail_uid_map`
  are the durable record now), and nothing else referenced them. The
  underlying `mail_uid_outcomes` table's hand-written migration is left in
  place (orphaned but harmless) — it is not this task's to drop.

  The message/sync-state bridge functions operate in a synthetic
  `account: "__legacy__", folder: "__legacy__"` scope on the new
  `mail_messages`/`mail_sync_state` tables (folder is real for sync-state —
  only `account` is synthetic there) and emulate the old msg_id-keyed
  upsert semantics (one row per `msg_id`, no per-folder occurrences) by
  using `msg_id` as a dedupe key within that scope: an `upsert_message/1`
  whose `msg_id` already has a row under a *different* `uid` deletes the
  stale occurrence row before inserting the new one (the new schema's
  primary key is `(account, folder, uid)`, so merely changing `uid` would
  otherwise leave two rows for the same logical message). The old API's
  `status` field has no column in the new occurrence schema (occurrence
  rows don't carry a review workflow status) — it rides along in `flags`,
  a plain string column with no other purpose at this synthetic scope,
  round-tripped transparently by `legacy_message_map/1`.

  `put_sync_state/3` collides in arity with the new
  `put_sync_state/3` (`account, folder, attrs`) — the old call shape is
  `(folder, uidvalidity, high_water_uid)`, so the two are told apart by an
  `is_map/1` guard on the third argument.
  """
  use Ash.Domain

  require Ash.Query

  alias Valea.Mail.Store.InboxHeader
  alias Valea.Mail.Store.MessageIndex
  alias Valea.Mail.Store.PendingOp
  alias Valea.Mail.Store.SyncState
  alias Valea.Mail.Store.UidMap

  resources do
    resource SyncState
    resource UidMap
    resource MessageIndex
    resource PendingOp
    # TEMP v3-bridge — see moduledoc.
    resource InboxHeader
  end

  # The synthetic scope every old-API bridge function operates in.
  @legacy "__legacy__"

  # -- sync_state ------------------------------------------------------------

  @doc "The full `mail_sync_state` row for `(account, folder)`."
  @spec get_sync_state(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_sync_state(account, folder) do
    case Ash.get(SyncState, %{account: account, folder: folder}) do
      {:ok, state} -> {:ok, sync_state_map(state)}
      {:error, _} -> {:error, :not_found}
    end
  end

  # TEMP v3-bridge: removed in Task 7/9. Old 1-arg call, synthetic account.
  @spec get_sync_state(String.t()) ::
          {:ok, %{uidvalidity: integer() | nil, high_water_uid: integer() | nil}}
          | {:error, :not_found}
  def get_sync_state(folder), do: get_sync_state(@legacy, folder)

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

  # TEMP v3-bridge: removed in Task 7/9. Old 3-arg call
  # `(folder, uidvalidity, high_water_uid)` — told apart from the new
  # `(account, folder, attrs)` shape by the `is_map/1` guard above (the old
  # third argument is always an integer or `nil`, never a map).
  @spec put_sync_state(String.t(), integer() | nil, integer() | nil) :: :ok
  def put_sync_state(folder, uidvalidity, high_water_uid) do
    put_sync_state(@legacy, folder, %{uidvalidity: uidvalidity, high_water_uid: high_water_uid})
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

  # -- pending ops ledger ------------------------------------------------------

  @doc """
  Creates a `mail_pending_ops` row. `id` is generated (`Ash.UUID`) unless
  already present in `attrs`. Returns `{:error, :duplicate_active}` when
  `attrs` would violate the one-non-terminal-append-per-`(account, origin)`
  partial unique index (`mail_pending_ops_active_append`).
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
          |> Map.take([:error, :uid, :dest_watermark, :dest_uidvalidity, :updated_at])
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

  @doc "Every `mail_pending_ops` row for `account` still in flight (`claimed`/`pending`/`executing`/`needs_review`)."
  @spec pending_ops(String.t()) :: [map()]
  def pending_ops(account) do
    PendingOp
    |> Ash.Query.filter(
      account == ^account and state in ["claimed", "pending", "executing", "needs_review"]
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
      state: row.state,
      error: row.error,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # -- TEMP v3-bridge: legacy msg_id-keyed messages -----------------------------
  # Removed in Task 6 (Index rewrite)/Task 7 (SyncPass rewrite). See the
  # moduledoc for the synthetic-scope + status/flags rationale.

  @doc false
  @spec upsert_message(map()) :: :ok
  def upsert_message(attrs) do
    from = attrs[:from] || %{}
    msg_id = attrs[:msg_id]
    uid = attrs[:uid] || fallback_uid(msg_id)

    case legacy_row_by_msg_id(msg_id) do
      {:ok, %{uid: existing_uid}} when existing_uid != uid ->
        delete_index_row(@legacy, @legacy, existing_uid)

      _ ->
        :ok
    end

    upsert_index_row(%{
      account: @legacy,
      folder: @legacy,
      uid: uid,
      msg_id: msg_id,
      message_id: attrs[:message_id],
      path: attrs[:path],
      from_name: address_field(from, :name),
      from_email: address_field(from, :email),
      subject: attrs[:subject],
      date: normalize_date(attrs[:date]),
      flags: attrs[:status],
      has_attachments: !!attrs[:has_attachments]
    })
  end

  # A real occurrence's `uid` is never `nil` (it comes straight off the IMAP
  # server), but the old msg_id-keyed API allowed it (a frontmatter file with
  # no `uid:` key, or a message that was never assigned one) — and the new
  # occurrence primary key is `(account, folder, uid)`, so two DIFFERENT
  # `nil`-uid messages naively falling back to the same literal (e.g. `0`)
  # would collide and one would silently clobber the other. Derive a
  # deterministic, msg_id-keyed synthetic uid instead — negative, so it can
  # never collide with a real (always positive) IMAP `UID` — collision
  # between two different msg_ids is astronomically unlikely at this
  # bridge's scale (a single dev workspace) and this whole path is removed
  # in Task 6/7 regardless.
  defp fallback_uid(msg_id), do: -(:erlang.phash2(msg_id, 1_000_000_000) + 1)

  defp address_field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp normalize_date(nil), do: nil
  defp normalize_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_date(str) when is_binary(str), do: str

  @doc false
  @spec message_by_message_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def message_by_message_id(message_id) do
    MessageIndex
    |> Ash.Query.filter(account == ^@legacy and message_id == ^message_id)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [row] -> {:ok, legacy_message_map(row)}
      [] -> {:error, :not_found}
    end
  end

  @doc false
  @spec list_messages() :: [map()]
  def list_messages do
    MessageIndex
    |> Ash.Query.filter(account == ^@legacy and folder == ^@legacy)
    |> Ash.Query.sort(date: :desc)
    |> Ash.read!()
    |> Enum.map(&legacy_message_map/1)
  end

  @doc false
  @spec get_message(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_message(msg_id) do
    case legacy_row_by_msg_id(msg_id) do
      {:ok, row} -> {:ok, legacy_message_map(row)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc false
  @spec set_message_status(String.t(), String.t()) :: :ok
  def set_message_status(msg_id, status) do
    case legacy_row_by_msg_id(msg_id) do
      {:ok, row} ->
        row
        |> Ash.Changeset.for_update(:set_flags, %{flags: status})
        |> Ash.update!()

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp legacy_row_by_msg_id(msg_id) do
    MessageIndex
    |> Ash.Query.filter(account == ^@legacy and folder == ^@legacy and msg_id == ^msg_id)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [row] -> {:ok, row}
      [] -> {:error, :not_found}
    end
  end

  defp legacy_message_map(row) do
    %{
      msg_id: row.msg_id,
      message_id: row.message_id,
      path: row.path,
      from_name: row.from_name,
      from_email: row.from_email,
      subject: row.subject,
      date: row.date,
      status: row.flags,
      has_attachments: row.has_attachments,
      uid: row.uid
    }
  end

  # -- TEMP v3-bridge: inbox headers --------------------------------------------
  # Removed in Task 10 (mail_rpc `mail_inbox` + api/mail.ex + cockpit.ex still
  # read `inbox_headers/0`) — see `InboxHeader`'s moduledoc. Unchanged from the
  # v1 Store: kept verbatim rather than emulated.

  @doc false
  @spec put_inbox_header(map()) :: :ok
  def put_inbox_header(attrs) do
    InboxHeader
    |> Ash.Changeset.for_create(:upsert, %{
      uid: attrs[:uid],
      from_text: attrs[:from_text],
      subject: attrs[:subject],
      date: normalize_date(attrs[:date])
    })
    |> Ash.create!()

    :ok
  end

  # Every `mail_inbox_headers` row, newest `date` first.
  @doc false
  @spec inbox_headers() :: [map()]
  def inbox_headers do
    InboxHeader
    |> Ash.Query.sort(date: :desc)
    |> Ash.read!()
    |> Enum.map(fn row ->
      %{uid: row.uid, from_text: row.from_text, subject: row.subject, date: row.date}
    end)
  end

  # Drops every `mail_inbox_headers` row past the newest `limit` (by `date`).
  @doc false
  @spec prune_inbox_headers(non_neg_integer()) :: :ok
  def prune_inbox_headers(limit) do
    InboxHeader
    |> Ash.Query.sort(date: :desc)
    |> Ash.read!()
    |> Enum.drop(limit)
    |> Enum.each(&Ash.destroy!/1)

    :ok
  end
end
