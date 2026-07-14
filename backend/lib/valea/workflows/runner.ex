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

  `workflow_path` is an OPAQUE string throughout this module for hashing,
  prompting, and the sidecar/queue envelope/audit entries — carried
  verbatim, never parsed for those purposes. That means the Plan A mount
  refactor (`Valea.Mounts`, T2) needed NO change here: `Valea.Workflows.
  list/0`'s `path` field is `mounts/<name>/Workflows/<file>.md` for an
  embedded mount instead of the old single hardcoded
  `icm/Workflows/<file>.md`, and this module carries the new shape through
  coherently by construction.

  ONE exception (A2-T5b): `read_workflow/2`'s containment check needs to
  know WHICH root to resolve `workflow_path` against — the workspace root
  for an embedded (workspace-relative) path, or the owning EXTERNAL mount's
  own absolute root for an absolute one (external content lives outside the
  workspace, so containing it against the workspace would always fail).
  `workflow_containment_root/2` answers that via `Valea.Mounts.mount_for/1`
  — the same attribution primitive `Valea.Workflows.get/1` already used
  moments earlier in this same call to resolve `wf`, so it is guaranteed to
  agree. This is the one place `workflow_path`'s SHAPE (not its content) is
  inspected; everything else about it downstream stays opaque.

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

  alias Valea.Agents.RiskTier
  alias Valea.Agents.SessionScope
  alias Valea.Mounts
  alias Valea.Workflows
  alias Valea.Workflows.MemoryProposal
  alias Valea.Workspace.Manager

  @staging_dir ["queue", "staging"]
  @pending_dir ["queue", "pending"]
  # The other three terminal/in-flight queue dirs (mirrors Valea.Queue's own
  # paths) — item_exists?/2 (B5 part 2) checks all four so a re-finalize can
  # tell "already created" apart from "genuinely new", regardless of which
  # of pending/processing/approved/rejected the item has since moved to.
  @processing_dir ["queue", "processing"]
  @approved_dir ["queue", "approved"]
  @rejected_dir ["queue", "rejected"]

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
         {:ok, wf} <- fetch_workflow(workflow_path),
         :ok <- ensure_enabled(wf),
         {:ok, workflow_bytes} <- read_workflow(workspace, workflow_path),
         {:ok, input_bytes} <- read_input(workspace, input_path) do
      start_run(workspace, wf, workflow_path, workflow_bytes, {:file, input_path, input_bytes})
    end
  end

  @doc """
  Same contract as `run/2`, except the input is not a file already on disk —
  `input_bytes` is written server-side to `queue/staging/<run_id>/<input_name>`
  BEFORE the session starts (so it exists before the session's first prompt
  ever fires), and `input_path` in the sidecar/queue-envelope/audit trail is
  that staging-relative path, exactly as if it had been a real input file.
  `input_hash` is `sha256(input_bytes)`, same as `run/2`.

  Built for `Valea.Workflows.Distill`'s decisions digest (B8): the digest is
  compiled in memory, not read off an existing source file, but the
  session still needs a named FILE to point its prompt at — the B3 staging
  read grant (`read_roots` extended with `queue/staging/<run_id>`) already
  lets the session read it back, so no read-boundary widening is needed
  here.
  """
  @spec run_generated(String.t(), String.t(), binary()) ::
          {:ok, %{run_id: String.t(), session_id: String.t()}}
          | {:error, :not_found | :workflow_disabled | :harness_unavailable | term()}
  def run_generated(workflow_path, input_name, input_bytes) do
    with {:ok, %{path: workspace}} <- current_workspace(),
         {:ok, wf} <- fetch_workflow(workflow_path),
         :ok <- ensure_enabled(wf),
         {:ok, workflow_bytes} <- read_workflow(workspace, workflow_path) do
      start_run(
        workspace,
        wf,
        workflow_path,
        workflow_bytes,
        {:generated, input_name, input_bytes}
      )
    end
  end

  @doc """
  Idempotent finalize for `run_id` in `workspace` — a pure function of
  `(run_id, workspace)`: reads ONLY what is on disk under
  `queue/staging/<run_id>/`, the exact primary `proposal.json` (proposal/v1,
  unchanged contract) AND, independently, every `proposals/<name>.json` +
  `<name>.md` memory-update pair (`Valea.Workflows.MemoryProposal`,
  memory_update/v1). Fans out into up to `1 + N` pending items: the primary
  proposal keeps its bare `<run_id>.json` id; each valid memory pair becomes
  its own `<run_id>-m<i>.json` (1-based over the FULL sorted pair list, so
  ids stay stable across calls even when some pairs are invalid). Every
  memory item's `risk_level` and target containment are computed HERE, from
  the target path alone, via `RiskTier.classify/2` +
  `MemoryProposal.check_target/2` — never taken from the agent's manifest.

    * outcome `"proposal_created"` — at least one item (primary or memory)
      was created; `queue_item_created` audited once per item created
    * outcome `"invalid_proposal"` — nothing was created and the primary
      proposal was invalid/unparseable, OR at least one memory pair was
      invalid (`memory_proposal_invalid` audited per invalid pair, carrying
      `run_id`/`file`/`reason`); staging is LEFT in place for inspection
    * outcome `"no_proposal"` — no primary proposal and no memory pairs at
      all

  A single `workflow_run_finished` is audited with the outcome above, and
  the staging dir is removed ONLY when nothing was invalid (a run that
  produced two valid memory items but one invalid third pair keeps its
  whole staging dir, not just the invalid pair's files — the same
  inspect-on-invalid contract the primary proposal always had).

  Idempotence holds UNCONDITIONALLY, including a run kept for inspection
  because some proposal was invalid: before writing ANY pending item
  (primary OR memory), `finalize/2` checks whether that item's id already
  exists in `queue/pending/`, `queue/processing/`, `queue/approved/`, or
  `queue/rejected/` (`item_exists?/2`) and skips it silently when it does —
  no envelope write, no `queue_item_created` audit, and the skip counts as
  NEITHER created nor invalid for THAT call's outcome. So a second call
  after all items were created — whether the staging dir is already gone, or
  kept because a sibling pair was invalid — never resurrects an
  already-decided item (the primary `<run_id>.json` id is guarded exactly
  like a memory item's `<run_id>-m<i>` id), and a re-finalize of a
  fully-created run with one still-invalid pair yields outcome
  `"invalid_proposal"` — the invalid pair is honestly re-audited every time,
  only the already-created id is skipped. This closes the crash-recovery
  window `recover_staging/1` used to re-open at boot (B5).
  """
  @spec finalize(String.t(), String.t()) :: :ok
  def finalize(run_id, workspace) do
    staging_dir = staging_dir(workspace, run_id)

    primary = finalize_primary(staging_dir, workspace, run_id)
    memory = finalize_memory(staging_dir, workspace, run_id)

    outcome_and_cleanup(staging_dir, run_id, primary, memory)

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

  # The existing proposal/v1 flow, verbatim, minus its own audit/cleanup —
  # those are now centralized in `outcome_and_cleanup/4` so a primary
  # proposal and its sibling memory pairs share ONE terminus audit and ONE
  # cleanup decision instead of racing each other. `:absent` (no
  # `proposal.json` at all — a died-pre-turn session, a genuinely empty
  # turn, or a workflow contract with no proposal output at all) is kept
  # distinct from `:invalid` (a `proposal.json` that IS present but fails
  # validation) so `outcome_and_cleanup/4` can tell "nothing here" from
  # "something here was wrong". `:skipped` is a THIRD, idempotency-only
  # outcome (B5 part 2): the proposal is otherwise valid, but `run_id`
  # already exists somewhere in the queue — a re-finalize
  # (`recover_staging/1` at boot, or any direct re-call) must not resurrect
  # it. `outcome_and_cleanup/4` treats `:skipped` as neither created nor
  # invalid, the same way it always treated `:absent`.
  @spec finalize_primary(String.t(), String.t(), String.t()) ::
          :created | :invalid | :absent | :skipped
  defp finalize_primary(staging_dir, workspace, run_id) do
    proposal_path = Path.join(staging_dir, "proposal.json")

    case File.read(proposal_path) do
      {:error, _reason} ->
        :absent

      {:ok, bytes} ->
        with {:ok, payload} <- Jason.decode(bytes),
             true <- valid_proposal?(payload),
             {:ok, run} <- read_sidecar(staging_dir) do
          if item_exists?(workspace, run_id) do
            :skipped
          else
            write_pending!(workspace, run_id, run, payload)
            audit("queue_item_created", %{"run_id" => run_id, "kind" => payload["kind"]})
            :created
          end
        else
          _ -> :invalid
        end
    end
  end

  # Every agent-staged memory-update pair, fanned out into its own pending
  # item. Needs the sidecar (for the queue envelope's session/workflow/input
  # fields, shared with the primary item) — an unreadable sidecar (staging
  # dir absent entirely, or a crash before `write_sidecar/2` ever ran) means
  # there is nothing trustworthy to build an envelope from, so this
  # degrades to "no memory pairs" rather than crashing `finalize/2`; the
  # primary path already covers auditing that case.
  # `:skipped` (B5 part 2, see finalize_primary/3's comment for the shared
  # rationale) increments neither counter — a re-finalize that finds an
  # already-created `<run_id>-m<i>` id neither re-creates it nor counts it
  # toward `invalid`.
  @spec finalize_memory(String.t(), String.t(), String.t()) ::
          {created :: non_neg_integer(), invalid :: non_neg_integer()}
  defp finalize_memory(staging_dir, workspace, run_id) do
    case read_sidecar(staging_dir) do
      {:error, _reason} ->
        {0, 0}

      {:ok, run} ->
        staging_dir
        |> MemoryProposal.load_pairs()
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {{file, result}, i}, {created, invalid} ->
          case finalize_pair(result, run, workspace, run_id, i, file) do
            :created -> {created + 1, invalid}
            :invalid -> {created, invalid + 1}
            :skipped -> {created, invalid}
          end
        end)
    end
  end

  defp finalize_pair({:error, reason}, _run, _workspace, run_id, _i, file) do
    invalid_pair_audit(run_id, file, reason)
  end

  defp finalize_pair(
         {:ok, %{manifest: manifest, content: content}},
         run,
         workspace,
         run_id,
         i,
         file
       ) do
    case MemoryProposal.check_target(workspace, manifest["target_path"]) do
      {:error, reason} ->
        invalid_pair_audit(run_id, file, reason)

      {:ok, _target} ->
        item_id = "#{run_id}-m#{i}"

        if item_exists?(workspace, item_id) do
          :skipped
        else
          tier = RiskTier.classify(workspace, manifest["target_path"]) || "medium"
          envelope = memory_envelope(run, item_id, manifest, content, tier)
          write_memory_pending!(workspace, item_id, envelope)
          audit("queue_item_created", %{"run_id" => item_id, "kind" => "memory_update"})
          :created
        end
    end
  end

  defp invalid_pair_audit(run_id, file, reason) do
    audit("memory_proposal_invalid", %{
      "run_id" => run_id,
      "file" => file,
      "reason" => to_string(reason)
    })

    :invalid
  end

  # `base_sha256: nil` is the create/1 sentinel (Spec B, proposal-pair
  # vocabulary) — the target page does not exist yet, so the title reads
  # "New page: …" rather than "Update …".
  defp memory_envelope(run, item_id, manifest, content, tier) do
    base = Path.basename(manifest["target_path"])
    title = if manifest["base_sha256"] == nil, do: "New page: " <> base, else: "Update " <> base

    %{
      "schema" => "queue_item/v2",
      "run_id" => item_id,
      "session_id" => run["session_id"],
      "workflow" => run["workflow"],
      "workflow_hash" => run["workflow_hash"],
      "input" => run["input"],
      "input_hash" => run["input_hash"],
      "risk_level" => tier,
      "approval" => run["approval"],
      "created_at" => run["created_at"],
      "payload" => %{
        "title" => title,
        "summary" => manifest["reason"],
        "kind" => "memory_update",
        "sources" => manifest["sources"],
        "proposed_action" => %{
          "type" => "apply_page_content",
          "target_path" => manifest["target_path"],
          "base_sha256" => manifest["base_sha256"],
          "content_markdown" => content
        }
      }
    }
  end

  # Single terminus for BOTH the primary proposal and its sibling memory
  # pairs: any item created (primary or memory) outranks any invalid one for
  # the outcome (a run that produced one good memory item and one bad one is
  # still "proposal_created" — the good item is live in the queue), but
  # staging is kept whenever ANYTHING was invalid, regardless of outcome, so
  # the bad pair(s) stay inspectable next to the good item's now-removed
  # source. Absent-everything (no primary, no memory pairs at all) is the
  # only path that reaches `"no_proposal"`.
  defp outcome_and_cleanup(staging_dir, run_id, primary, {mem_created, mem_invalid}) do
    created? = primary == :created or mem_created > 0
    invalid? = primary == :invalid or mem_invalid > 0

    outcome =
      cond do
        created? -> "proposal_created"
        invalid? -> "invalid_proposal"
        true -> "no_proposal"
      end

    unless invalid?, do: File.rm_rf(staging_dir)

    audit_finished(run_id, outcome)
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

  # `workflow_path` (opaque throughout this module — see moduledoc) is
  # still the ABSOLUTE physical path `Valea.Workflows.list/0`'s
  # `resolved_path` field carries. `Valea.Workflows.get/1` was re-keyed to
  # `get/2` (Task 7.1: `{mount_key, relative_path}` identity) — this
  # adapter bridges the two: attribute `workflow_path` to its owning mount
  # the same way `workflow_containment_root/2` does moments later in this
  # same call (`Mounts.mount_for/1`, ENABLED+healthy attribution only),
  # derive the ICM-relative remainder, and look the contract up by its new
  # keyed identity. The full `{mount_key, relative_path}`-addressed
  # `run/2`/`run_generated/3` API is Task 7.2's job (the ICM-scoped run),
  # not this one — `workflow_path` stays this module's own opaque address
  # for now.
  @spec fetch_workflow(String.t()) :: {:ok, map()} | {:error, :not_found}
  defp fetch_workflow(workflow_path) do
    case Mounts.mount_for(workflow_path) do
      {:ok, %{name: mount_key, root: root}} ->
        # `get/2`'s `:not_in_icm` (a path landing inside the mount but
        # outside its OWN `Workflows/`) collapses to this module's existing
        # `:not_found` — this module's public error vocabulary (see `run/2`
        # `@spec`) predates the `{mount_key, relative_path}` re-key, and
        # both atoms mean the same thing to every current caller: no
        # runnable contract at `workflow_path`.
        case Workflows.get(mount_key, Path.relative_to(workflow_path, root)) do
          {:ok, wf} -> {:ok, wf}
          {:error, _reason} -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # Containment-gated: `resolve_real/2` rejects any `..`/symlink traversal
  # that would escape the containment root (realpath semantics, mirroring
  # `PermissionPolicy`), and the read goes through the RESOLVED absolute
  # path so the check actually gates what gets read.
  defp read_workflow(workspace, workflow_path) do
    with {:ok, root} <- workflow_containment_root(workspace, workflow_path),
         {:ok, real} <- Valea.Paths.resolve_real(workflow_path, root),
         {:ok, bytes} <- File.read(real) do
      {:ok, bytes}
    else
      _ -> {:error, :not_found}
    end
  end

  # The root `workflow_path` must be contained within — the workspace for an
  # embedded (workspace-relative `mounts/<name>/…`) path, unchanged from
  # before mounts existed, or the owning EXTERNAL mount's own absolute root
  # for an absolute one (A2-T5b — external content lives outside the
  # workspace by definition, so containing it against the workspace would
  # always fail). See moduledoc for why this is the one place `workflow_path`
  # is inspected rather than treated opaquely.
  defp workflow_containment_root(workspace, workflow_path) do
    case Valea.Mounts.mount_for(workflow_path) do
      {:ok, %{rel_root: nil, root: root}} -> {:ok, root}
      {:ok, %{rel_root: rel_root}} when is_binary(rel_root) -> {:ok, workspace}
      _ -> {:error, :not_found}
    end
  end

  # Task 5.5: the workflow session's PRIMARY ICM (spec §"Workflow session")
  # is the mount that OWNS `workflow_path` — the SAME attribution
  # `workflow_containment_root/2` above already used moments earlier in
  # this same `run/2`/`run_generated/3` call (via `read_workflow/2`), so it
  # is guaranteed to agree here. `mount.name` is the workspace-local mount
  # KEY `SessionScope.resolve/1` expects (never `mount.manifest.name`, the
  # ICM's own display name — see `Valea.Mounts`'s moduledoc "Compatibility
  # shim" section). `mount_for/1` only attributes among ENABLED,
  # non-degraded mounts, so a workflow whose owning mount was disabled out
  # from under this run between `read_workflow/2` succeeding and here would
  # surface `:not_found` — an edge case narrow enough (the same run) that
  # `run/2`'s own documented error vocabulary already covers it.
  @spec owning_mount_key(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  defp owning_mount_key(workflow_path) do
    case Mounts.mount_for(workflow_path) do
      {:ok, %{name: mount_key}} -> {:ok, mount_key}
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

  # `{:file, ...}`: nothing to do, the bytes were already read off a real
  # source file by `run/2` — `input_path` is that file's own
  # workspace-relative path, carried through unchanged.
  defp materialize_input(_staging_dir, _run_id, {:file, input_path, input_bytes}) do
    {input_path, input_bytes}
  end

  # `{:generated, ...}`: no source file exists — `run_generated/3`'s caller
  # handed us bytes compiled in memory. Write them into THIS run's own
  # staging dir (never the agent-writable `proposals/` subdir — this file is
  # server-owned input, not agent output) before the session starts, so the
  # prompt can name a real file and the B3 staging read grant lets the
  # session read it back. `Path.basename/1` is defense-in-depth against a
  # `name` carrying `/`/`..` — every current caller passes a fixed literal
  # (`"input-decisions.md"`), but this keeps the write contained to
  # `staging_dir` regardless.
  defp materialize_input(staging_dir, run_id, {:generated, name, bytes}) do
    safe_name = Path.basename(name)
    File.write!(Path.join(staging_dir, safe_name), bytes)
    {Path.join(["queue", "staging", run_id, safe_name]), bytes}
  end

  defp start_run(workspace, wf, workflow_path, workflow_bytes, input) do
    run_id = generate_run_id()
    staging_dir = staging_dir(workspace, run_id)
    File.mkdir_p!(staging_dir)
    # The agent's memory-update grant (below) is scoped to exactly this
    # subdirectory — created up front so the write_roots grant has somewhere
    # to land even on a workflow turn that writes no memory pairs at all.
    File.mkdir_p!(Path.join(staging_dir, "proposals"))
    staging_rel = Path.join([staging_dir_rel(run_id), "proposal.json"])
    staging_abs = Path.join(workspace, staging_rel)

    # `:file` (run/2): the caller already has bytes read off an existing
    # source file, `input_path` is that file's own workspace-relative path.
    # `:generated` (run_generated/3): no source file exists yet — the bytes
    # are compiled server-side (e.g. `Valea.Workflows.Distill.digest/1`) and
    # written HERE, before the session starts, so `input_path` becomes the
    # staging-relative path of the file just created. Either way, everything
    # downstream (sidecar, prompt, audit, queue envelope) uses `input_path`/
    # `input_bytes` uniformly from this point on.
    {input_path, input_bytes} = materialize_input(staging_dir, run_id, input)

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

    # Task 5.5: the session's PRIMARY ICM is the mount that OWNS this
    # workflow contract (`workflow_path` already resolved through this same
    # attribution — via `read_workflow/2` -> `workflow_containment_root/2` —
    # moments ago in `run/2`/`run_generated/3`, so it is guaranteed to
    # attribute again here), never a caller/model choice (spec §"Workflow
    # session"). The session id is generated HERE, not inside
    # `start_session/1`, because `SessionScope.resolve/1` needs it up front
    # to derive `managed_context`'s path — mirrors
    # `Valea.Api.Agents.create_session`'s identical "generate id -> resolve
    # scope -> start_session(scope)" ordering.
    #
    # `write_paths`/`write_roots` are this run's exact staging grants,
    # unchanged from before. `read_paths: []` is the MINIMAL workflow scope
    # (this task's brief) — it deliberately does NOT re-grant the agent a
    # read of its own staging dir back (the old `policy_ctx.read_roots`
    # above used to fold in `"queue/staging/<run_id>"`); the full workflow
    # input/grant/locator re-key with exact per-input reads is Phase 7
    # (Tasks 7.1/7.2/7.3), not here.
    session_id = Valea.Agents.generate_session_id()

    result =
      with {:ok, mount_key} <- owning_mount_key(workflow_path),
           {:ok, scope} <-
             SessionScope.resolve(%{
               kind: "workflow",
               mount_key: mount_key,
               generation: Manager.generation(),
               session_id: session_id,
               write_paths: [staging_abs],
               # Directory grant (B2's `write_roots`), scoped to `proposals/`
               # only — NEVER the staging dir itself, so the trusted
               # `run.json` sidecar this module writes below stays
               # unwritable by the agent (security invariant: the sidecar is
               # server-owned, carried verbatim into every queue envelope
               # `finalize/2` builds).
               write_roots: [Path.join(staging_dir, "proposals")],
               read_paths: []
             }) do
        Valea.Agents.start_session(%{
          id: session_id,
          kind: "workflow",
          title: wf.name,
          scope: scope,
          run: %{id: run_id, workflow: workflow_path},
          initial_prompt: prompt(workflow_path, input_path, staging_abs),
          on_turn_end: fn _stop -> finalize(run_id, workspace) end
        })
      end

    case result do
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

  # `staging_proposal_abs` is the ABSOLUTE `write_paths` grant (Task 5.5) —
  # NOT workspace-relative. Since the session's `cwd` is now the owning
  # ICM's own root (never the workspace, per `SessionScope.resolve/1`), a
  # workspace-relative instruction here would resolve against the wrong
  # base and land outside every recognized write area; the absolute path is
  # unambiguous regardless of `cwd`, and matches `write_paths`/`write_roots`
  # (also absolute) exactly.
  defp prompt(workflow_path, input_path, staging_proposal_abs) do
    """
    Read AGENTS.md first if you have not already. Then execute the workflow
    contract at "#{workflow_path}" against the input file "#{input_path}".
    Follow the contract's Process steps. Read only the pages its Inputs and
    sources name. If the contract's Outputs call for a proposal, write
    exactly one proposal/v1 JSON file to "#{staging_proposal_abs}". If you
    noticed business knowledge that is stale, missing, or contradicted, you
    may additionally propose memory updates: for each one, write a pair of
    files under "#{Path.dirname(staging_proposal_abs)}/proposals/" —
    <name>.md (the complete new page content) and <name>.json (a
    memory_update/v1 manifest) — following the memory-update contract in
    AGENTS.md. Write nothing else. When done, state in one sentence what
    you prepared, and stop.
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

  # Idempotency guard (B5 part 2): true when `item_id` already exists
  # ANYWHERE in the queue — pending, claimed, or already decided. Checked
  # before writing any pending item (primary or memory) so a re-finalize of
  # a staging dir kept around for inspection (an invalid sibling pair) can
  # never resurrect an item a previous finalize already created, nor an
  # already-decided one a human has since approved or rejected.
  defp item_exists?(workspace, item_id) do
    file = item_id <> ".json"

    Enum.any?(
      [
        pending_dir(workspace),
        processing_dir(workspace),
        approved_dir(workspace),
        rejected_dir(workspace)
      ],
      &File.exists?(Path.join(&1, file))
    )
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

  # Same tmp+rename atomic write `write_pending!/4` uses, for a memory
  # item's own already-built envelope (`memory_envelope/5`) — a memory item
  # has no `source_message` key (it is never a mailbox-op trigger), so it
  # doesn't share `write_pending!/4`'s envelope construction, only its write
  # path.
  defp write_memory_pending!(workspace, item_id, envelope) do
    path = Path.join(pending_dir(workspace), item_id <> ".json")
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
  defp processing_dir(workspace), do: Path.join([workspace | @processing_dir])
  defp approved_dir(workspace), do: Path.join([workspace | @approved_dir])
  defp rejected_dir(workspace), do: Path.join([workspace | @rejected_dir])

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
