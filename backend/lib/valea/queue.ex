defmodule Valea.Queue do
  @moduledoc """
  The proposal queue: `queue/pending/<run_id>.json` items written by
  `Valea.Workflows.Runner`, and the HARDENED approval path that turns one
  into an executed side effect (today: an email draft file).

  Every mutating operation is a `File.rename/2` between sibling directories
  on the same workspace filesystem — atomic, so a claim can never be lost or
  duplicated by two callers racing the same item. The queue directory a file
  currently lives in IS the state machine:

      pending -> processing -> approved
      pending -> rejected

  `revision` (sha256 hex of the exact file bytes) is the optimistic-lock
  token: `get/1` hands it out, `approve/2` and `reject/2` re-read the file
  and re-hash it immediately before the claiming rename, so a caller acting
  on a stale view of the item (edited or already claimed since they fetched
  it) gets `{:error, :queue_item_changed}` instead of silently clobbering a
  concurrent decision.

  Execution itself (the draft write) happens strictly BETWEEN two audited
  steps — `approval_intent` before, `action_executed` after — and is
  idempotent (skips the write if the draft file already exists), so a crash
  between claim and completion is always safe to replay: `recover/1` finds
  the item still sitting in `processing/`, and either finishes it (draft
  exists — the write happened, only the final rename+audit did not) or
  returns it to `pending/` (draft absent — nothing observable happened yet).
  """

  alias Valea.Workspace.Manager

  @type revision :: String.t()

  @doc """
  Pending items, newest first (run ids are lexically sortable timestamps).
  Invalid files (bad JSON or a JSON value that fails the `queue_item/v1`
  shape check) are listed with `valid: false` and an `error` reason instead
  of being skipped or crashing the call.
  """
  @spec list() :: {:ok, [map()]} | {:error, :no_workspace}
  def list do
    with {:ok, workspace} <- workspace_root() do
      entries =
        workspace
        |> pending_dir()
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.map(&list_entry/1)
        |> Enum.sort_by(& &1.run_id, :desc)

      {:ok, entries}
    end
  end

  @doc """
  Fetches the pending item's full envelope plus its current revision (sha256
  hex of the raw file bytes). `revision` is only ever meaningful for the
  exact bytes it was computed from — pass it straight to `approve/2` or
  `reject/2`.
  """
  @spec get(String.t()) ::
          {:ok, %{item: map(), revision: revision()}}
          | {:error, :queue_item_gone | :queue_item_invalid}
  def get(run_id) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, bytes} <- read_pending(workspace, run_id) do
      case decode_envelope(bytes) do
        {:ok, item} -> {:ok, %{item: item, revision: sha256(bytes)}}
        {:error, _reason} -> {:error, :queue_item_invalid}
      end
    end
  end

  @doc """
  Approves `run_id`, EXACTLY in this order:

    1. re-read the pending file's bytes and re-hash — mismatch against
       `revision` returns `{:error, :queue_item_changed}` and touches
       nothing;
    2. atomic claim: `File.rename/2` `pending/<run_id>.json` ->
       `processing/<run_id>.json` (already moved/gone -> `:queue_item_gone`);
    3. audit `approval_intent`;
    4. idempotent execute: write `sources/mail/drafts/<run_id>.md` UNLESS it
       already exists (a replay after a crash between steps 3 and 5 must not
       re-send/re-write);
    5. audit `action_executed`;
    6. `File.rename/2` `processing/` -> `approved/`;
    7. audit `item_approved`.
  """
  @spec approve(String.t(), revision()) ::
          {:ok, %{draft_path: String.t()}}
          | {:error, :queue_item_gone | :queue_item_changed | :queue_item_invalid}
  def approve(run_id, revision) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, bytes} <- read_pending(workspace, run_id),
         :ok <- check_revision(bytes, revision),
         {:ok, item} <- decode_for_execute(bytes),
         :ok <- claim(workspace, run_id) do
      audit("approval_intent", %{"run_id" => run_id})
      ensure_draft(workspace, run_id, item)
      audit("action_executed", %{"run_id" => run_id})
      complete_approval(workspace, run_id)
      audit("item_approved", %{"run_id" => run_id})
      {:ok, %{draft_path: draft_rel_path(run_id)}}
    end
  end

  @doc """
  Rejects `run_id`: same revision guard as `approve/2`, then an atomic
  `pending/` -> `rejected/` rename and an `item_rejected` audit entry.
  """
  @spec reject(String.t(), revision()) ::
          {:ok, %{}} | {:error, :queue_item_gone | :queue_item_changed}
  def reject(run_id, revision) do
    with {:ok, workspace} <- resolve(run_id),
         {:ok, bytes} <- read_pending(workspace, run_id),
         :ok <- check_revision(bytes, revision),
         :ok <- move_to_rejected(workspace, run_id) do
      audit("item_rejected", %{"run_id" => run_id})
      {:ok, %{}}
    end
  end

  @doc """
  Crash recovery: for every file still sitting in `queue/processing/`
  (meaning the process died between the claiming rename and the final
  `approved/` rename), decide its fate from whether the draft was already
  written:

    * draft exists -> the execute step finished, only completion didn't —
      finish it (rename to `approved/`, audit `item_approved` with
      `recovered: true`);
    * draft absent -> nothing observable happened — hand it back to
      `pending/` (audit `approval_recovered`) so a human can approve/reject
      it again.

  `workspace` is the plain root path (NOT a `%{path: ...}` map): this runs
  from `Valea.Workspace.Runtime` startup, before `Valea.Workspace.Manager`
  has committed the new workspace as current.
  """
  @spec recover(String.t()) :: :ok
  def recover(workspace) do
    workspace
    |> processing_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(&recover_one(workspace, &1))

    :ok
  end

  ## resolution + validation

  defp resolve(run_id) do
    with true <- valid_run_id?(run_id),
         {:ok, workspace} <- workspace_root() do
      {:ok, workspace}
    else
      false -> {:error, :queue_item_gone}
      {:error, _} = err -> err
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: root}} -> {:ok, root}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # A safe basename: run ids come straight from filenames, so before any
  # path is built from one it must contain no separator or traversal
  # sequence.
  defp valid_run_id?(run_id) when is_binary(run_id) do
    run_id != "" and not String.contains?(run_id, "/") and not String.contains?(run_id, "..")
  end

  defp valid_run_id?(_run_id), do: false

  ## list/1 helpers

  defp list_entry(path) do
    run_id = Path.basename(path, ".json")

    case File.read(path) do
      {:error, reason} ->
        invalid_entry(run_id, reason)

      {:ok, bytes} ->
        case decode_envelope(bytes) do
          {:ok, item} -> summary(run_id, item)
          {:error, reason} -> invalid_entry(run_id, reason)
        end
    end
  end

  defp summary(run_id, item) do
    %{
      run_id: run_id,
      title: item["payload"]["title"],
      summary: item["payload"]["summary"],
      kind: item["payload"]["kind"],
      risk_level: item["risk_level"],
      created_at: item["created_at"],
      workflow: item["workflow"],
      valid: true
    }
  end

  defp invalid_entry(run_id, reason) do
    %{
      run_id: run_id,
      title: nil,
      summary: nil,
      kind: nil,
      risk_level: nil,
      created_at: nil,
      workflow: nil,
      valid: false,
      error: to_string(reason)
    }
  end

  ## get/1 + envelope validation (mirrors Runner's proposal/v1 checks, one
  ## level up: the whole queue_item/v1 envelope)

  defp read_pending(workspace, run_id) do
    case File.read(pending_path(workspace, run_id)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, :queue_item_gone}
    end
  end

  defp decode_for_execute(bytes) do
    case decode_envelope(bytes) do
      {:ok, item} -> {:ok, item}
      {:error, _reason} -> {:error, :queue_item_invalid}
    end
  end

  defp decode_envelope(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = item} ->
        if valid_envelope?(item), do: {:ok, item}, else: {:error, :invalid_schema}

      {:ok, _not_a_map} ->
        {:error, :invalid_schema}

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  defp valid_envelope?(item) do
    item["schema"] == "queue_item/v1" and
      nonempty_string?(item["run_id"]) and
      nonempty_string?(item["workflow"]) and
      nonempty_string?(item["risk_level"]) and
      nonempty_string?(item["created_at"]) and
      valid_payload?(item["payload"])
  end

  defp valid_payload?(%{} = payload) do
    nonempty_string?(payload["title"]) and
      nonempty_string?(payload["summary"]) and
      nonempty_string?(payload["kind"]) and
      list_of_strings?(payload["sources"]) and
      valid_action?(payload["proposed_action"])
  end

  defp valid_payload?(_payload), do: false

  defp valid_action?(%{
         "type" => "create_email_draft",
         "to" => to,
         "subject" => subject,
         "body_markdown" => body
       })
       when is_binary(to) and is_binary(subject) and is_binary(body),
       do: true

  defp valid_action?(_action), do: false

  defp nonempty_string?(s), do: is_binary(s) and String.trim(s) != ""

  defp list_of_strings?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp list_of_strings?(_list), do: false

  ## approve/2 + reject/2 helpers

  defp check_revision(bytes, revision) do
    if sha256(bytes) == revision, do: :ok, else: {:error, :queue_item_changed}
  end

  defp claim(workspace, run_id) do
    File.mkdir_p!(processing_dir(workspace))

    case File.rename(pending_path(workspace, run_id), processing_path(workspace, run_id)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :queue_item_gone}
    end
  end

  defp ensure_draft(workspace, run_id, item) do
    path = draft_path(workspace, run_id)

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, draft_markdown(run_id, item))
    end

    :ok
  end

  defp draft_markdown(run_id, item) do
    action = item["payload"]["proposed_action"]
    sources = item["payload"]["sources"] || []

    lines =
      [
        "---",
        "to: #{action["to"]}",
        "subject: #{action["subject"]}",
        "run_id: #{run_id}",
        "workflow: #{item["workflow"]}",
        "sources:"
      ] ++
        Enum.map(sources, &"  - #{&1}") ++
        ["---", "", action["body_markdown"]]

    Enum.join(lines, "\n")
  end

  defp complete_approval(workspace, run_id) do
    File.mkdir_p!(approved_dir(workspace))
    File.rename!(processing_path(workspace, run_id), approved_path(workspace, run_id))
  end

  defp move_to_rejected(workspace, run_id) do
    File.mkdir_p!(rejected_dir(workspace))

    case File.rename(pending_path(workspace, run_id), rejected_path(workspace, run_id)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :queue_item_gone}
    end
  end

  ## recover/1 helpers

  defp recover_one(workspace, path) do
    run_id = Path.basename(path, ".json")

    if File.exists?(draft_path(workspace, run_id)) do
      File.mkdir_p!(approved_dir(workspace))
      File.rename!(path, approved_path(workspace, run_id))
      audit("item_approved", %{"run_id" => run_id, "recovered" => true})
    else
      File.mkdir_p!(pending_dir(workspace))
      File.rename!(path, pending_path(workspace, run_id))
      audit("approval_recovered", %{"run_id" => run_id})
    end
  end

  ## paths

  defp pending_dir(ws), do: Path.join([ws, "queue", "pending"])
  defp processing_dir(ws), do: Path.join([ws, "queue", "processing"])
  defp approved_dir(ws), do: Path.join([ws, "queue", "approved"])
  defp rejected_dir(ws), do: Path.join([ws, "queue", "rejected"])
  defp drafts_dir(ws), do: Path.join([ws, "sources", "mail", "drafts"])

  defp pending_path(ws, run_id), do: Path.join(pending_dir(ws), run_id <> ".json")
  defp processing_path(ws, run_id), do: Path.join(processing_dir(ws), run_id <> ".json")
  defp approved_path(ws, run_id), do: Path.join(approved_dir(ws), run_id <> ".json")
  defp rejected_path(ws, run_id), do: Path.join(rejected_dir(ws), run_id <> ".json")
  defp draft_path(ws, run_id), do: Path.join(drafts_dir(ws), run_id <> ".md")
  defp draft_rel_path(run_id), do: Path.join(["sources", "mail", "drafts", run_id <> ".md"])

  ## misc

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end
end
