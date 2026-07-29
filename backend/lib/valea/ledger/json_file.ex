defmodule Valea.Ledger.JsonFile do
  @moduledoc """
  The read/write primitive under the per-ICM JSON ledgers (`tasks.json`,
  `schedules.json`) — tasks+schedules spec §Leniency contract and §Write
  discipline. Files-for-facts: these are **user-owned** documents that
  agents and humans edit with ordinary tools, so every operation here is
  built around two rules — never fail loudly on a file we didn't write, and
  never lose a key we don't understand.

  ## Leniency (read)

  `read/2` degrades, never raises: an absent file is `:absent` (the caller
  materializes a skeleton or shows an empty ledger), and anything we cannot
  make sense of — an I/O error, unparseable JSON, a top level that isn't a
  JSON object — is `{:error, :unreadable}`, which the UI renders as a calm
  "fix by hand" note. A readable doc yields three things:

    * `doc` — the decoded document **exactly as read**, unknown top-level
      keys included. Writers patch this map rather than rebuilding it, so
      `readme` and any future key a newer app (or a hand edit) put there
      survive a Valea write.
    * `entries` — `doc[list_key]` filtered to maps: the display/execution
      view. A missing or wrong-typed list key yields `[]` while `doc` keeps
      the offending value untouched, and non-map members (a stray `42`) are
      dropped from the view but stay in `doc` — dropping them from the
      *view* must never mean deleting them from the *file*.
    * `hash` — `:crypto.hash(:sha256, raw)` over the raw bytes, the
      optimistic-concurrency token to hand back to `write/3`.

  ## Optimistic concurrency (write)

  `write/3` encodes `doc` (pretty JSON + trailing newline, so the file stays
  a pleasant thing to read and diff), writes a `.tmp` sibling, then re-reads
  the current file and compares its hash with `expected` (`:absent` matches
  a file that does not exist — the "materialize it" case). On a match it
  `File.rename!/2`s the temp file into place: atomic for concurrent readers,
  and it replaces the directory entry rather than writing *through* a
  symlink an agent may have planted (same reasoning as
  `Valea.Mail.AgentsFile`). On a mismatch nothing is written, the temp file
  is removed, and the caller gets `{:error, :conflict}` — its cue to re-read
  and re-apply the patch (`Valea.Tasks` does this, bounded to 3 attempts).

  The window between that final hash check and the rename is
  **accepted residual risk #5** in the spec: a foreign writer landing inside
  it loses its write, and for an open entry that is plain data loss. Valea
  shrinks the window from "an entire UI interaction" to microseconds and
  serializes its own writes through `Valea.Ledger.Writer`; it does not claim
  to close it, and there are deliberately no lock files.

  The temp path is `path <> ".tmp"`, one per ledger: Valea-side writes are
  serialized by the Writer and no agent tool writes that name, so the only
  way to collide is two Valea instances over the same ICM — accepted risk #3
  (per-workspace runtimes), where the loser is the same lost write risk #5
  already covers.
  """

  @type read_result ::
          {:ok, %{doc: map(), entries: [map()], hash: binary()}}
          | :absent
          | {:error, :unreadable}

  @doc """
  Reads `path` as a JSON object and returns `%{doc:, entries:, hash:}` for
  the list under `list_key`. See the moduledoc for the leniency contract —
  `:absent` for a missing file, `{:error, :unreadable}` for anything we
  cannot decode into a JSON object.
  """
  @spec read(String.t(), String.t()) :: read_result()
  def read(path, list_key) when is_binary(path) and is_binary(list_key) do
    case File.read(path) do
      {:ok, raw} -> decode(raw, list_key)
      {:error, :enoent} -> :absent
      {:error, _io_error} -> {:error, :unreadable}
    end
  end

  defp decode(raw, list_key) do
    case Jason.decode(raw) do
      {:ok, %{} = doc} -> {:ok, %{doc: doc, entries: entries(doc[list_key]), hash: hash(raw)}}
      _not_a_json_object -> {:error, :unreadable}
    end
  end

  defp entries(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp entries(_missing_or_wrong_typed), do: []

  @doc """
  Writes `doc` to `path` if the file's current content still hashes to
  `expected` (`:absent` for "must not exist yet"), via temp + rename.

  Returns `{:error, :conflict}` — having written nothing — when the file
  changed under the caller, whose job is then to re-read and re-apply.
  Raises only on genuine I/O failure (unwritable directory, encode error):
  a ledger we cannot write is not something to swallow.
  """
  @spec write(String.t(), map(), binary() | :absent) :: :ok | {:error, :conflict}
  def write(path, doc, expected) when is_binary(path) and is_map(doc) do
    data = Jason.encode!(doc, pretty: true) <> "\n"
    tmp = path <> ".tmp"

    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, data)

    if current_hash(path) == expected do
      File.rename!(tmp, path)
      :ok
    else
      File.rm(tmp)
      {:error, :conflict}
    end
  end

  # The comparison is deliberately total: an unreadable current file matches
  # neither a hash nor `:absent`, so a ledger that turned into a directory
  # (or went permission-denied) fails closed as a conflict instead of being
  # clobbered.
  defp current_hash(path) do
    case File.read(path) do
      {:ok, raw} -> hash(raw)
      {:error, :enoent} -> :absent
      {:error, _io_error} -> :unreadable
    end
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
