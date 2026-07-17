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

  Task 7 (the `SyncPass` rewrite) retired the `mail_uid_outcomes` bridge
  (`record_outcome/4`, `outcomes/1`, `UidOutcome`, and the old
  single-argument `clear_folder/1` that wiped it): the pull engine no longer
  tracks per-UID sync outcomes in SQLite (the maildir tree + `mail_uid_map`
  are the durable record now), and nothing else referenced them. The
  underlying `mail_uid_outcomes` table's hand-written migration is left in
  place (orphaned but harmless) — it is not this task's to drop. Task 10
  retired the last of the pre-occurrence bridge surface the same way: the
  msg_id-keyed message functions (`upsert_message/1`, `get_message/1`,
  `message_by_message_id/1`, `list_messages/0`, `set_message_status/2`) and
  the `mail_inbox_headers`-backed inbox-header family (`put_inbox_header/1`,
  `inbox_headers/0`, `prune_inbox_headers/1`, `Valea.Mail.Store.InboxHeader`)
  are gone — `api/mail.ex`'s account-scoped `list_mail_messages`/
  `get_mail_message` and the deleted `mail_inbox` action replaced their only
  callers. The underlying `mail_inbox_headers` table's migration is
  likewise left in place (orphaned but harmless), same posture as
  `mail_uid_outcomes`.
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
          |> Map.take([
            :error,
            :uid,
            :dest_watermark,
            :dest_uidvalidity,
            :spool_path,
            :payload_sha256,
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

  @doc """
  Every `mail_pending_ops` row for `(account, origin)`, ANY state — the
  push flow's corroboration lookup (a non-`draft` frontmatter status is
  allowed only when a prior engine-written op for this draft exists) and
  `list_mail_drafts`'s ledger-derived status, both of which must see
  terminal (`complete`/`rejected`) rows the active-only `pending_ops/1`
  filters out.
  """
  @spec ops_by_origin(String.t(), String.t()) :: [map()]
  def ops_by_origin(account, origin) do
    PendingOp
    |> Ash.Query.filter(account == ^account and origin == ^origin)
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
end
