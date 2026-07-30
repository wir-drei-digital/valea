defmodule Valea.Schedules.Edit do
  @moduledoc """
  Valea's disciplined writes to `schedules.json` — the mirror image of
  `Valea.Tasks`' mutation half, for the file that actually fires things
  (tasks+schedules spec §`schedules.json`, §Write discipline).

  Reads do NOT live here: `Valea.Schedules.File.load/1` is the read side (and
  the execution path's only view), deliberately uncached and writer-free. This
  module exists so the UI's pause toggle, "new schedule" composer and delete
  affordance touch the user's file with the same care the task ledger gets:

    * every mutation runs inside `Valea.Ledger.Writer.exec/1`, so Valea-side
      writes never interleave;
    * each is an optimistic read-patch-write against the file's content hash,
      re-applied on conflict, bounded to 3 attempts before surfacing
      `{:error, :conflict}`;
    * the document is PATCHED as read — `readme`, unknown top-level keys,
      unknown entry fields and non-map junk members in the array all survive
      (dropping them from the display view is leniency; dropping them from the
      file would be data loss);
    * a `schedules` key that isn't an array is refused (`{:error,
      :unreadable}`) rather than clobbered, exactly like the task ledger.

  ## Addressing is by TRIMMED id

  `Valea.Schedules.Entry` trims the id it exposes (`" s-1 "` and `"s-1"` are
  the same schedule and cannot slip past the duplicate gate as two rows), so a
  writer patching the file has to match it trimmed too — otherwise the UI could
  show a row it cannot address.

  ## Duplicates are refused, never resolved by order

  A `schedule_id` carried by more than one entry yields `{:error,
  :duplicate_id}` and writes nothing. The spec's rule for duplicates is "all
  carriers excluded from execution, visible reason; **order never decides**" —
  and first-occurrence-wins on a mutation is precisely order deciding: pausing
  "the first one" would silently pause a different payload after someone
  reorders the array. Tasks are inert and can afford first-wins addressing;
  schedules execute, so the repair here is a hand edit (or a delete of both),
  surfaced with the row's own reason.

  ## Test seam

  `:before_write` — `fun/0` or `fun/1` (the 1-based attempt number), called
  after the read and before the write, so a test can land a foreign write
  inside the optimistic window. Defaults to `nil`; no production caller passes
  it. Same contract as `Valea.Tasks`'.
  """

  alias Valea.Ledger.JsonFile
  alias Valea.Ledger.Writer

  @list_key "schedules"
  @readme "Schedules for this ICM. Fire only while Valea is running. Contract: .valea/briefing.md"
  @attempts 3

  @type error :: :not_found | :duplicate_id | :conflict | :unreadable

  @doc """
  Appends a schedule and returns the entry as written.

  `fields` are merged over Valea's defaults and win, so a caller may supply its
  own `id`, `paused` or `created_by`; keys may be atoms or strings and are
  normalized to strings. An absent ledger is materialized with the spec
  skeleton (`readme` + empty `schedules`).

  Nothing here validates the schedule: strictness belongs to the read side
  (`Valea.Schedules.Entry`), which is what the scheduler and the UI both see.
  A schedule written with a broken cron lands in the file and shows up
  `not_executable` with its reason — the same repair loop a hand edit gets.
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def create(icm_root, fields \\ %{}, opts \\ []) when is_map(fields) and is_list(opts) do
    Writer.exec(fn -> do_create(path(icm_root), stringify(fields), opts) end)
  end

  defp do_create(path, fields, opts) do
    with {:ok, %{doc: doc}} <- read_for_write(path),
         {:ok, list} <- writable_list(doc) do
      append(path, new_entry(fields, list), opts, 1)
    end
  end

  defp append(_path, _entry, _opts, attempt) when attempt > @attempts, do: {:error, :conflict}

  defp append(path, entry, opts, attempt) do
    with {:ok, %{doc: doc, hash: expected}} <- read_for_write(path),
         {:ok, list} <- writable_list(doc) do
      run_hook(opts[:before_write], attempt)

      case JsonFile.write(path, Map.put(doc, @list_key, list ++ [entry]), expected) do
        :ok -> {:ok, entry}
        {:error, :conflict} -> append(path, entry, opts, attempt + 1)
      end
    end
  end

  defp new_entry(fields, list) do
    %{
      "id" => generate_id(taken_ids(list)),
      "title" => "Untitled schedule",
      "paused" => false,
      "created_by" => "user",
      "created_at" => now_iso()
    }
    |> Map.merge(fields)
  end

  defp taken_ids(list) do
    list |> Enum.map(&trimmed/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  # Same shape as `Valea.Tasks.generate_id/2` with the schedule prefix: check
  # the ledger we just read a few times, then take the candidate anyway — a
  # duplicate degrades to a visible, repairable `duplicate id` disposition,
  # which is a better outcome than failing the creation outright.
  defp generate_id(taken, tries \\ 8) do
    candidate = "s-" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)

    if tries > 1 and MapSet.member?(taken, candidate),
      do: generate_id(taken, tries - 1),
      else: candidate
  end

  @doc """
  Patches the entry whose TRIMMED id is `schedule_id`, returning it as written.

  `patch` is merged over the entry, so unknown fields on both sides survive.
  `{:error, :not_found}` when the id isn't (or is no longer) there,
  `{:error, :duplicate_id}` when more than one entry carries it (see the
  moduledoc), `{:error, :conflict}` if contention persists — nothing is
  written in any of those cases.

  No timestamp stamping: unlike a task, a schedule's `updated_at` is not part
  of the spec's shape, and the fields that decide firing (`cron`, `payload`,
  `timezone`, `catchup`) already carry their own change detection through the
  execution fingerprint.
  """
  @spec patch(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def patch(icm_root, schedule_id, patch, opts \\ [])
      when is_binary(schedule_id) and is_map(patch) and is_list(opts) do
    Writer.exec(fn ->
      do_patch(path(icm_root), String.trim(schedule_id), stringify(patch), opts, 1)
    end)
  end

  defp do_patch(_path, _id, _patch, _opts, attempt) when attempt > @attempts,
    do: {:error, :conflict}

  defp do_patch(path, id, patch, opts, attempt) do
    with {:ok, %{doc: doc, hash: expected}} <- read_for_write(path),
         {:ok, list} <- writable_list(doc),
         :ok <- addressable(list, id) do
      entry = list |> Enum.find(&(trimmed(&1) == id)) |> Map.merge(patch)
      patched = Enum.map(list, fn e -> if trimmed(e) == id, do: entry, else: e end)

      run_hook(opts[:before_write], attempt)

      case JsonFile.write(path, Map.put(doc, @list_key, patched), expected) do
        :ok -> {:ok, entry}
        {:error, :conflict} -> do_patch(path, id, patch, opts, attempt + 1)
      end
    end
  end

  @doc """
  Removes the entry whose TRIMMED id is `schedule_id`, returning it as it was.

  Same addressing rules and error vocabulary as `patch/4`. Run history is NOT
  touched: `Valea.Schedules.Store` rows are keyed by `(icm_id, schedule_id)`
  and deliberately outlive the definition (spec §Audit), and the scheduler
  tombstones the vanished id on its next pass, so a later re-creation of the
  same id starts with fresh anchors.
  """
  @spec delete(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def delete(icm_root, schedule_id, opts \\ []) when is_binary(schedule_id) and is_list(opts) do
    Writer.exec(fn -> do_delete(path(icm_root), String.trim(schedule_id), opts, 1) end)
  end

  defp do_delete(_path, _id, _opts, attempt) when attempt > @attempts, do: {:error, :conflict}

  defp do_delete(path, id, opts, attempt) do
    with {:ok, %{doc: doc, hash: expected}} <- read_for_write(path),
         {:ok, list} <- writable_list(doc),
         :ok <- addressable(list, id) do
      entry = Enum.find(list, &(trimmed(&1) == id))
      kept = Enum.reject(list, &(trimmed(&1) == id))

      run_hook(opts[:before_write], attempt)

      case JsonFile.write(path, Map.put(doc, @list_key, kept), expected) do
        :ok -> {:ok, entry}
        {:error, :conflict} -> do_delete(path, id, opts, attempt + 1)
      end
    end
  end

  # -- shared plumbing ---------------------------------------------------------

  defp addressable(list, id) do
    case Enum.count(list, &(trimmed(&1) == id)) do
      1 -> :ok
      0 -> {:error, :not_found}
      _many -> {:error, :duplicate_id}
    end
  end

  defp trimmed(entry) when is_map(entry) do
    case entry["id"] do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: String.trim(id)
      _missing_or_wrong_typed -> nil
    end
  end

  defp trimmed(_junk_member), do: nil

  defp path(icm_root), do: Valea.Schedules.File.schedules_path(icm_root)

  # An absent ledger reads as the spec skeleton against an `:absent` hash, so
  # the first write materializes `readme` + `schedules` and still fails closed
  # if someone else created the file in the meantime.
  defp read_for_write(path) do
    case JsonFile.read(path, @list_key) do
      {:ok, read} ->
        {:ok, read}

      :absent ->
        {:ok, %{doc: %{"readme" => @readme, @list_key => []}, entries: [], hash: :absent}}

      # The hash of the unparseable bytes is the scheduler's business (one
      # audit notice per content hash); a write only needs "no".
      {:error, :unreadable, _hash} ->
        {:error, :unreadable}
    end
  end

  # The RAW list, junk members included — see `Valea.Tasks`' identical note.
  defp writable_list(doc) do
    case Map.get(doc, @list_key, []) do
      list when is_list(list) -> {:ok, list}
      _wrong_typed -> {:error, :unreadable}
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp stringify(fields), do: Map.new(fields, fn {key, value} -> {to_string(key), value} end)

  defp run_hook(nil, _arg), do: :ok
  defp run_hook(fun, arg) when is_function(fun, 1), do: fun.(arg)
  defp run_hook(fun, _arg) when is_function(fun, 0), do: fun.()
end
