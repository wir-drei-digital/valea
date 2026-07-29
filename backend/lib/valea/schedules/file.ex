defmodule Valea.Schedules.File do
  @moduledoc """
  `schedules.json` at an ICM root, read into dispositioned entries — the
  execution path's only view of the file (tasks+schedules spec
  §`schedules.json`, §Leniency contract, §Firing rule step 1).

  `load/1` is a pure read and deliberately **uncached**: the scheduler calls it
  on every tick and again immediately before it fires, so a hand edit or an
  agent edit takes effect within one tick without the watcher being involved.
  Watcher events refresh the UI; they never gate a fire.

  It never raises and never surfaces an error tuple:

    * `:ok` — the file parsed. `entries` are `Valea.Schedules.Entry` structs in
      file order, each with its own disposition.
    * `:absent` — no file, no schedules. The ordinary state of a fresh ICM.
    * `:unreadable` — malformed JSON, a non-object top level, an I/O fault.
      `entries` is empty, so **nothing fires from a file Valea cannot parse**
      (spec: fail-safe). The UI shows one calm note; deletion is never inferred
      from an unreadable file.

  `hash` is the file's content hash from `Valea.Ledger.JsonFile` — the token a
  writer hands back for optimistic concurrency, and the key the audit notice for
  an unreadable file is deduped by.

  One housekeeping note for callers: a bare `alias Valea.Schedules.File` would
  shadow Elixir's `File` for the rest of that module. Call it qualified, or
  alias it `as: SchedulesFile`.

  ## Duplicate ids

  Ids are the addressing key, so a duplicate makes **every** carrier
  non-executable ("duplicate id") — never "first one wins". Array order must
  never decide what runs: with first-wins, moving two entries past each other
  silently swaps which payload fires. This pass runs after per-entry validation
  and overwrites the reason on carriers that had their own defect too, because
  a row nothing can address is the defect to fix first. Entries with no id at
  all are not duplicates of each other; they each keep "missing id".
  """

  alias Valea.Ledger.JsonFile
  alias Valea.Schedules.Entry

  @list_key "schedules"

  @type t :: %{
          status: :ok | :absent | :unreadable,
          entries: [Entry.t()],
          hash: binary() | nil
        }

  @doc "The schedules ledger path for an ICM root."
  @spec schedules_path(String.t()) :: String.t()
  def schedules_path(icm_root), do: Path.join(icm_root, "schedules.json")

  @doc """
  Reads and strict-validates the ICM's schedules. See the moduledoc — the three
  statuses, and why the duplicate-id pass excludes every carrier.
  """
  @spec load(String.t()) :: t()
  def load(icm_root) when is_binary(icm_root) do
    case JsonFile.read(schedules_path(icm_root), @list_key) do
      {:ok, %{entries: entries, hash: hash}} ->
        %{status: :ok, entries: dispositioned(entries), hash: hash}

      :absent ->
        %{status: :absent, entries: [], hash: nil}

      {:error, :unreadable} ->
        %{status: :unreadable, entries: [], hash: nil}
    end
  end

  defp dispositioned(entries) do
    entries |> Enum.map(&Entry.build/1) |> exclude_duplicate_ids()
  end

  defp exclude_duplicate_ids(entries) do
    duplicates =
      entries
      |> Enum.frequencies_by(& &1.id)
      |> Enum.filter(fn {id, count} -> not is_nil(id) and count > 1 end)
      |> MapSet.new(fn {id, _count} -> id end)

    Enum.map(entries, fn entry ->
      if MapSet.member?(duplicates, entry.id),
        do: %{entry | disposition: :not_executable, reason: "duplicate id"},
        else: entry
    end)
  end
end
