defmodule Valea.Mail.Store do
  @moduledoc """
  The mail sync engine's SQLite cache — `Valea.Repo` (per-workspace,
  `AshSqlite.DataLayer`) backed by `mail_sync_state`, `mail_uid_outcomes`,
  `mail_messages`, and `mail_inbox_headers`. Every one of these tables is
  pure cache: rebuildable from `sources/mail/` (+ an IMAP resync) —
  losing `app.sqlite` must never lose data, so this module owns no
  business logic beyond that reconstruction contract.

  No `AshTypescript` extension — this domain is internal-only, never
  exposed over RPC. The four resources under `Valea.Mail.Store.*` stay
  deliberately minimal (one `:upsert` create action apiece, no
  timestamps/soft-deletes/relationships); the friendly, task-brief-shaped
  API below (`get_sync_state/1`, `record_outcome/4`, `outcomes/1`, ...) is
  hand-written on top of them rather than generated `code_interface`
  `define`s, because several of these operations (the failed-attempts
  counter, the synced/skipped/retryable partition, newest-first sort,
  keep-newest-N pruning) are small pieces of logic, not bare CRUD.
  """
  use Ash.Domain

  require Ash.Query

  alias Valea.Mail.Store.InboxHeader
  alias Valea.Mail.Store.MessageIndex
  alias Valea.Mail.Store.SyncState
  alias Valea.Mail.Store.UidOutcome

  resources do
    resource SyncState
    resource UidOutcome
    resource MessageIndex
    resource InboxHeader
  end

  # -- sync_state ------------------------------------------------------------

  @doc "The last-seen `UIDVALIDITY` + high-water `UID` for `folder`."
  @spec get_sync_state(String.t()) ::
          {:ok, %{uidvalidity: integer() | nil, high_water_uid: integer() | nil}}
          | {:error, :not_found}
  def get_sync_state(folder) do
    case Ash.get(SyncState, folder) do
      {:ok, state} ->
        {:ok, %{uidvalidity: state.uidvalidity, high_water_uid: state.high_water_uid}}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "Upserts the `folder`'s sync watermark."
  @spec put_sync_state(String.t(), integer() | nil, integer() | nil) :: :ok
  def put_sync_state(folder, uidvalidity, high_water_uid) do
    SyncState
    |> Ash.Changeset.for_create(:upsert, %{
      folder: folder,
      uidvalidity: uidvalidity,
      high_water_uid: high_water_uid
    })
    |> Ash.create!()

    :ok
  end

  # -- uid outcomes ------------------------------------------------------------

  @doc """
  Upserts the outcome of syncing `uid` in `folder`. `attempts` increments
  every time `outcome` is `:failed` (or `"failed"`); any other outcome
  leaves the counter where it was — a later `:synced`/`:skipped` outcome
  simply stops the UID from ever being read as retryable again (see
  `outcomes/1`), there is nothing left to count.
  """
  @spec record_outcome(String.t(), integer(), atom() | String.t(), String.t() | nil) :: :ok
  def record_outcome(folder, uid, outcome, msg_id \\ nil) do
    outcome_str = to_string(outcome)

    existing_attempts =
      case Ash.get(UidOutcome, %{folder: folder, uid: uid}) do
        {:ok, %{attempts: attempts}} -> attempts
        {:error, _} -> 0
      end

    attempts = if outcome_str == "failed", do: existing_attempts + 1, else: existing_attempts

    UidOutcome
    |> Ash.Changeset.for_create(:upsert, %{
      folder: folder,
      uid: uid,
      outcome: outcome_str,
      attempts: attempts,
      msg_id: msg_id
    })
    |> Ash.create!()

    :ok
  end

  @doc """
  Partitions every recorded outcome for `folder`. `skipped` covers
  `skipped_oversize` — the string the sync pass actually records, so an
  oversized message is never re-fetched — as well as plain `skipped`.
  `retryable` is every UID last recorded `failed` with fewer than 3
  attempts — at 3 it drops out (permanently skipped rather than retried
  forever).
  """
  @spec outcomes(String.t()) :: %{synced: MapSet.t(), skipped: MapSet.t(), retryable: [integer()]}
  def outcomes(folder) do
    UidOutcome
    |> Ash.Query.filter(folder == ^folder)
    |> Ash.read!()
    |> Enum.reduce(%{synced: MapSet.new(), skipped: MapSet.new(), retryable: []}, &add_outcome/2)
  end

  defp add_outcome(%{outcome: "synced", uid: uid}, acc),
    do: %{acc | synced: MapSet.put(acc.synced, uid)}

  defp add_outcome(%{outcome: outcome, uid: uid}, acc)
       when outcome in ["skipped", "skipped_oversize"],
       do: %{acc | skipped: MapSet.put(acc.skipped, uid)}

  defp add_outcome(%{outcome: "failed", attempts: attempts, uid: uid}, acc) when attempts < 3,
    do: %{acc | retryable: [uid | acc.retryable]}

  defp add_outcome(_row, acc), do: acc

  # -- messages ------------------------------------------------------------

  @doc """
  Upserts a `mail_messages` row from `attrs` (as produced by
  `Valea.Mail.Index.rebuild/1` from a parsed message file's frontmatter, or
  by the sync engine from a `Valea.Mail.Message`). `from` may be an
  atom-keyed `%{name:, email:}` map (the `Message` shape) or a
  string-keyed `%{"name" => , "email" => }` map (frontmatter parsed as
  YAML) — either is accepted. `date` may be a `DateTime`, an already-ISO8601
  string, or `nil`.
  """
  @spec upsert_message(map()) :: :ok
  def upsert_message(attrs) do
    from = attrs[:from] || %{}

    MessageIndex
    |> Ash.Changeset.for_create(:upsert, %{
      msg_id: attrs[:msg_id],
      message_id: attrs[:message_id],
      path: attrs[:path],
      from_name: address_field(from, :name),
      from_email: address_field(from, :email),
      subject: attrs[:subject],
      date: normalize_date(attrs[:date]),
      status: attrs[:status],
      has_attachments: !!attrs[:has_attachments],
      uid: attrs[:uid]
    })
    |> Ash.create!()

    :ok
  end

  defp address_field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp normalize_date(nil), do: nil
  defp normalize_date(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_date(str) when is_binary(str), do: str

  @doc "First `mail_messages` row (there is no uniqueness constraint on `message_id`) matching it."
  @spec message_by_message_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def message_by_message_id(message_id) do
    MessageIndex
    |> Ash.Query.filter(message_id == ^message_id)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [row] -> {:ok, message_map(row)}
      [] -> {:error, :not_found}
    end
  end

  @doc "Every `mail_messages` row, newest `date` first."
  @spec list_messages() :: [map()]
  def list_messages do
    MessageIndex
    |> Ash.Query.sort(date: :desc)
    |> Ash.read!()
    |> Enum.map(&message_map/1)
  end

  @spec get_message(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_message(msg_id) do
    case Ash.get(MessageIndex, msg_id) do
      {:ok, row} -> {:ok, message_map(row)}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "No-op (not an error) when `msg_id` isn't cached — the file on disk stays the source of truth."
  @spec set_message_status(String.t(), String.t()) :: :ok
  def set_message_status(msg_id, status) do
    case Ash.get(MessageIndex, msg_id) do
      {:ok, row} ->
        row
        |> Ash.Changeset.for_update(:set_status, %{status: status})
        |> Ash.update!()

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp message_map(row) do
    %{
      msg_id: row.msg_id,
      message_id: row.message_id,
      path: row.path,
      from_name: row.from_name,
      from_email: row.from_email,
      subject: row.subject,
      date: row.date,
      status: row.status,
      has_attachments: row.has_attachments,
      uid: row.uid
    }
  end

  # -- folder reset ------------------------------------------------------------

  @doc """
  Wipes `folder`'s sync watermark and every recorded outcome — the reset a
  `UIDVALIDITY` mismatch demands (everything must be treated as unseen and
  re-fetched). `mail_messages` rows are untouched: the landed files on disk
  are still valid, dedupe-by-`message_id` will find them again on resync.
  """
  @spec clear_folder(String.t()) :: :ok
  def clear_folder(folder) do
    SyncState |> Ash.Query.filter(folder == ^folder) |> Ash.bulk_destroy!(:destroy, %{})
    UidOutcome |> Ash.Query.filter(folder == ^folder) |> Ash.bulk_destroy!(:destroy, %{})

    :ok
  end

  # -- inbox headers ------------------------------------------------------------

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

  @doc "Every `mail_inbox_headers` row, newest `date` first."
  @spec inbox_headers() :: [map()]
  def inbox_headers do
    InboxHeader
    |> Ash.Query.sort(date: :desc)
    |> Ash.read!()
    |> Enum.map(fn row ->
      %{uid: row.uid, from_text: row.from_text, subject: row.subject, date: row.date}
    end)
  end

  @doc "Drops every `mail_inbox_headers` row past the newest `limit` (by `date`)."
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
