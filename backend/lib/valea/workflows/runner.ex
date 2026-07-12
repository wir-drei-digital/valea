defmodule Valea.Workflows.Runner do
  @moduledoc """
  Executes one workflow with a SERVER-OWNED run identity: `run/2` generates
  the run id, the staging directory, the exact proposal output path, and
  the workflow/input hashes — none of this is agent-controlled. It then
  starts an agent session scoped (via `policy_ctx.write_paths`) to write
  only that exact staging path, and asks the session to call back into
  `finalize/2` once its first turn ends.

  The run record needed by `finalize/2` is never kept in process memory —
  it is written once, at run start, as a JSON sidecar
  (`queue/staging/<run_id>/run.json`, the `queue_item/v1` envelope minus
  `payload`). This lets `finalize/2` be a pure function of `(run_id,
  workspace)`, callable from the session's `on_turn_end` callback,
  crash-recovery, or a test — and idempotent, since it only ever acts on
  what it finds on disk.

  `workflow_path` is an OPAQUE workspace-relative string throughout this
  module — it is hashed, embedded in the prompt, and carried verbatim into
  the sidecar/queue envelope/audit entries, but never itself parsed or
  glob-matched. That means the Plan A mount refactor (`Valea.Mounts`, T2)
  needed NO change here: `Valea.Workflows.list/0`'s `path` field is now
  `mounts/<name>/Workflows/<file>.md` instead of the old single hardcoded
  `icm/Workflows/<file>.md`, and this module carries the new shape through
  coherently by construction.

  This module also does NOT resolve a workflow contract's `sources:`
  frontmatter (the `%{id, type, path}` list of ICM pages the contract
  declares) — confirmed by inspection: the only `"sources"` this module
  touches is the AGENT-PRODUCED proposal's `sources` field (a flat list of
  strings the agent self-reports having read, checked by
  `valid_proposal?/1`), never the contract's own `sources:` list. Resolving
  the contract's `sources:` paths is entirely agent-facing: the agent reads
  the workflow `.md` file itself (named opaquely in the prompt below) over
  its ACP session and interprets `sources:` per the ICM-relative-first
  convention `Valea.ICM.References` already established (T4) — relative to
  the CONTRACT'S OWN mount root, not the workspace root. That convention
  will be spelled out for the agent in the mount's own `AGENTS.md`
  (`A-T7`/`A-T8`, not yet built); nothing to change here until then.
  """

  alias Valea.Workflows
  alias Valea.Workspace.Manager

  @staging_dir ["queue", "staging"]
  @pending_dir ["queue", "pending"]

  @doc """
  Runs `workflow_path` (as returned by `Valea.Workflows.list/0`'s `path`
  field) against `input_path` (workspace-relative). Starts the agent
  session; the proposal is finalized asynchronously once the session's
  first turn ends (see `finalize/2`).
  """
  @spec run(String.t(), String.t()) ::
          {:ok, %{run_id: String.t(), session_id: String.t()}}
          | {:error,
             :not_found | :workflow_disabled | :input_not_found | :harness_unavailable | term()}
  def run(workflow_path, input_path) do
    with {:ok, %{path: workspace}} <- current_workspace(),
         {:ok, wf} <- Workflows.get(workflow_path),
         :ok <- ensure_enabled(wf),
         {:ok, workflow_bytes} <- read_workflow(workspace, workflow_path),
         {:ok, input_bytes} <- read_input(workspace, input_path) do
      start_run(workspace, wf, workflow_path, workflow_bytes, input_path, input_bytes)
    end
  end

  @doc """
  Idempotent finalize for `run_id` in `workspace`: reads ONLY the exact
  staging proposal path.

    * missing → audit `workflow_run_finished` outcome `"no_proposal"`
    * unparseable/invalid per proposal/v1 → audit outcome `"invalid_proposal"`,
      staging is LEFT in place for inspection
    * valid → write `queue/pending/<run_id>.json` (atomic tmp+rename), audit
      `queue_item_created` then `workflow_run_finished` outcome
      `"proposal_created"`, remove the staging dir

  Safe to call more than once: a second call after success finds no staging
  file (already removed) and is a `"no_proposal"` no-op — the pending item
  is never duplicated.
  """
  @spec finalize(String.t(), String.t()) :: :ok
  def finalize(run_id, workspace) do
    staging_dir = staging_dir(workspace, run_id)
    proposal_path = Path.join(staging_dir, "proposal.json")

    case File.read(proposal_path) do
      {:error, _reason} ->
        # No proposal was written (a died-pre-turn session or a genuinely empty
        # turn). Nothing to inspect, so clear the staging dir too — this gives
        # the run a terminus AND stops `recover_staging/1` from re-sweeping the
        # leftover run.json on the next workspace open.
        File.rm_rf(staging_dir)
        audit_finished(run_id, "no_proposal")

      {:ok, bytes} ->
        finalize_bytes(run_id, workspace, staging_dir, bytes)
    end

    :ok
  end

  @doc """
  Crash-recovery backstop for `finalize/2`: at workspace open, every
  `queue/staging/<run_id>/` left behind by a HARD crash (the BEAM died before
  the session's `on_turn_end` death-path could run) has no live session and no
  terminus. Give each one a terminus by running `finalize/2` — which audits
  `no_proposal` / `invalid_proposal` / `proposal_created` from whatever the
  agent managed to write — then clear the dir so it is swept exactly once
  across reboots (an invalid proposal's terminus is preserved in the audit
  trail).

  Runs from `Valea.Workspace.Runtime` startup, BEFORE any session can be
  created for the newly opening workspace, so nothing under staging is live.
  """
  @spec recover_staging(String.t()) :: :ok
  def recover_staging(workspace) do
    workspace
    |> Path.join(Path.join(@staging_dir))
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.each(fn dir ->
      run_id = Path.basename(dir)
      finalize(run_id, workspace)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp finalize_bytes(run_id, workspace, staging_dir, bytes) do
    with {:ok, payload} <- Jason.decode(bytes),
         true <- valid_proposal?(payload),
         {:ok, run} <- read_sidecar(staging_dir) do
      write_pending!(workspace, run_id, run, payload)
      audit("queue_item_created", %{"run_id" => run_id, "kind" => payload["kind"]})
      File.rm_rf(staging_dir)
      audit_finished(run_id, "proposal_created")
    else
      _ -> audit_finished(run_id, "invalid_proposal")
    end
  end

  ## run/2 helpers

  defp current_workspace do
    case Manager.current() do
      {:ok, ws} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :not_found}
    end
  end

  defp ensure_enabled(%{enabled: true}), do: :ok
  defp ensure_enabled(_wf), do: {:error, :workflow_disabled}

  # Containment-gated: `resolve_real/2` rejects any `..`/symlink traversal
  # that would escape `workspace` (realpath semantics, mirroring
  # `PermissionPolicy`), and the read goes through the RESOLVED absolute
  # path so the check actually gates what gets read.
  defp read_workflow(workspace, workflow_path) do
    with {:ok, real} <- Valea.Paths.resolve_real(workflow_path, workspace),
         {:ok, bytes} <- File.read(real) do
      {:ok, bytes}
    else
      _ -> {:error, :not_found}
    end
  end

  defp read_input(workspace, input_path) do
    with {:ok, real} <- Valea.Paths.resolve_real(input_path, workspace),
         {:ok, bytes} <- File.read(real) do
      {:ok, bytes}
    else
      _ -> {:error, :input_not_found}
    end
  end

  defp start_run(workspace, wf, workflow_path, workflow_bytes, input_path, input_bytes) do
    run_id = generate_run_id()
    staging_dir = staging_dir(workspace, run_id)
    File.mkdir_p!(staging_dir)
    staging_rel = Path.join([staging_dir_rel(run_id), "proposal.json"])
    staging_abs = Path.join(workspace, staging_rel)

    run = %{
      "run_id" => run_id,
      "workflow" => workflow_path,
      "workflow_hash" => sha256(workflow_bytes),
      "input" => input_path,
      "input_hash" => sha256(input_bytes),
      "risk_level" => wf.risk_level,
      "approval" => wf.approval,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    audit("workflow_run_started", %{
      "run_id" => run_id,
      "workflow" => workflow_path,
      "input" => input_path,
      "workflow_hash" => run["workflow_hash"],
      "input_hash" => run["input_hash"]
    })

    session_opts = %{
      kind: "workflow",
      title: wf.name,
      workspace: workspace,
      generation: Manager.generation(),
      run: %{id: run_id, workflow: workflow_path},
      policy_ctx: %{
        workspace: workspace,
        session_kind: "workflow",
        write_paths: [staging_abs]
      },
      initial_prompt: prompt(workflow_path, input_path, staging_rel),
      on_turn_end: fn _stop -> finalize(run_id, workspace) end
    }

    case Valea.Agents.start_session(session_opts) do
      {:ok, %{id: session_id}} ->
        write_sidecar(staging_dir, Map.put(run, "session_id", session_id))
        {:ok, %{run_id: run_id, session_id: session_id}}

      {:error, reason} ->
        File.rm_rf(staging_dir)

        # `workflow_run_started` was already audited above — every started
        # run must have a terminus, so compensate with a paired
        # `workflow_run_finished` before returning the error.
        audit("workflow_run_finished", %{
          "run_id" => run_id,
          "outcome" => "start_failed",
          "reason" => inspect(reason)
        })

        {:error, reason}
    end
  end

  # `yyyymmddThhmmssZ-xxxxxx`: whole-second UTC basic timestamp (no
  # fractional seconds) + a 6-hex-char random suffix (3 random bytes).
  defp generate_run_id do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    stamp <> "-" <> suffix
  end

  defp prompt(workflow_path, input_path, staging_rel) do
    """
    Read AGENTS.md first if you have not already. Then execute the workflow
    contract at "#{workflow_path}" against the input file "#{input_path}".
    Follow the contract's Process steps. Read only the pages its Inputs and
    sources name. Write exactly one proposal/v1 JSON file to
    "#{staging_rel}" and nothing else. When the file is written, state
    in one sentence what you prepared, and stop.
    """
  end

  defp write_sidecar(staging_dir, run) do
    File.write!(Path.join(staging_dir, "run.json"), Jason.encode!(run))
  end

  ## finalize/2 helpers

  defp read_sidecar(staging_dir) do
    with {:ok, bytes} <- File.read(Path.join(staging_dir, "run.json")),
         {:ok, %{} = run} <- Jason.decode(bytes) do
      {:ok, run}
    end
  end

  defp write_pending!(workspace, run_id, run, payload) do
    envelope = %{
      "schema" => "queue_item/v2",
      "run_id" => run["run_id"],
      "session_id" => run["session_id"],
      "workflow" => run["workflow"],
      "workflow_hash" => run["workflow_hash"],
      "input" => run["input"],
      "input_hash" => run["input_hash"],
      "risk_level" => run["risk_level"],
      "approval" => run["approval"],
      "created_at" => run["created_at"],
      # The source message that triggered this run — the seed for the
      # post-approval mailbox-op intents Queue.approve/reject stamp onto the
      # decided envelope (queue_item/v2).
      "source_message" => run["input"],
      "payload" => payload
    }

    path = Path.join(pending_dir(workspace), run_id <> ".json")
    File.mkdir_p!(pending_dir(workspace))
    atomic_write!(path, Jason.encode!(envelope))
  end

  defp atomic_write!(abs, bytes) do
    tmp = abs <> ".tmp"
    File.write!(tmp, bytes)
    File.rename!(tmp, abs)
  end

  defp valid_proposal?(p) when is_map(p) do
    p["schema"] == "proposal/v1" and
      p["kind"] == "email_draft" and
      nonempty_string?(p["title"]) and
      nonempty_string?(p["summary"]) and
      nonempty_string?(p["reasoning"]) and
      list_of_strings?(p["sources"]) and
      valid_action?(p["proposed_action"])
  end

  defp valid_proposal?(_p), do: false

  defp nonempty_string?(s), do: is_binary(s) and String.trim(s) != ""

  defp list_of_strings?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp list_of_strings?(_list), do: false

  defp valid_action?(%{
         "type" => "create_email_draft",
         "to" => to,
         "subject" => subject,
         "body_markdown" => body
       })
       when is_binary(to) and is_binary(subject) and is_binary(body),
       do: no_control_chars?(to) and no_control_chars?(subject)

  defp valid_action?(_action), do: false

  # `to`/`subject` are interpolated straight into the draft's YAML frontmatter
  # (`Valea.Queue.draft_markdown/2`). A control char — newline, CR, or any
  # other C0/DEL — would let an agent inject arbitrary frontmatter keys (e.g. a
  # second `to:`) so the executed draft diverges from what the human approved.
  # Reject at the proposal boundary so a malformed item never reaches the
  # queue. `body_markdown` is the frontmatter BODY (below `---`), so it is not
  # subject to this check.
  defp no_control_chars?(s) do
    not Enum.any?(String.to_charlist(s), &(&1 < 0x20 or &1 == 0x7F))
  end

  ## paths

  defp staging_dir_rel(run_id), do: Path.join(@staging_dir ++ [run_id])
  defp staging_dir(workspace, run_id), do: Path.join(workspace, staging_dir_rel(run_id))
  defp pending_dir(workspace), do: Path.join([workspace | @pending_dir])

  ## misc

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp audit(type, fields) do
    if Process.whereis(Valea.Audit), do: Valea.Audit.append(type, fields)
    :ok
  end

  defp audit_finished(run_id, outcome) do
    audit("workflow_run_finished", %{"run_id" => run_id, "outcome" => outcome})
  end
end
