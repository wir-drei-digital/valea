# Methodology Depth (Spec B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the teach-the-assistant loop: memory-update proposals from workflow runs through the hardened queue (server-owned risk/containment, hash-guarded apply), a diff-upgraded chat ask dialog with risk tiers, rejection reasons, and a digest-fed "Distill decisions" reflection workflow.

**Architecture:** Extends the existing proposal pipeline (Runner staging → finalize → queue) with a second proposal kind (`memory_update`, authored as staged markdown + thin JSON manifest pairs), a second queue execute arm (`apply_page_content`, Valea writes the page), and a runner variant fed by a server-compiled decisions digest. Chat keeps direct ICM edits behind the ask-gate, now rendered as a real diff with a server-derived risk tier.

**Tech Stack:** Elixir/Phoenix + Ash 3 + ash_typescript 0.17.3 (backend), SvelteKit static SPA + Svelte 5 runes + Bun/vitest (frontend). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-12-methodology-depth-design.md` — binding for every task.

## Global Constraints

- File-first: the agent's only interface is reading/writing files; no new tool surface. Valea (never the agent) applies approved edits.
- Server-owned trust fields: a queue item's `risk_level` and target containment are computed at finalize from the target path — never taken from the agent's manifest. Risk tier vocabulary: `"high"` when the mount-relative path is `AGENTS.md`, `CLAUDE.md`, `icm.yaml`, or starts with `Workflows/`; else `"medium"`. (Spec names Workflows/*.md, AGENTS.md, icm.yaml as behavior-bearing; `CLAUDE.md` is the same instruction spine and is included.)
- Physical-path vocabulary (Spec A2): embedded-mount targets are workspace-relative `mounts/<name>/…`; external-mount targets are resolved absolute paths.
- Proposal pair on disk: `queue/staging/<run_id>/proposals/<name>.md` (full new page content) + `<name>.json` (manifest `{"schema":"memory_update/v1","target_path",...,"base_sha256"(64-hex|null),"reason","sources"}`). `base_sha256: null` means create.
- Pending envelopes stay single self-contained JSON files, schema `queue_item/v2`; memory items use `payload.kind = "memory_update"`, `proposed_action.type = "apply_page_content"` with `content_markdown` inlined by the server. Derived item ids `<run_id>-m1..-mN`, pairs sorted by json filename.
- The workspace shell (root `AGENTS.md`, `MOUNTS.md`, `config/`, `queue/`, `sources/`, `logs/`, `secrets/`) is never a valid proposal target — targets must attribute to an **enabled, non-degraded** mount via `Valea.Mounts.mount_for/2`.
- Apply conflicts (hash mismatch, mount disabled, create-target exists, unreachable) execute NOTHING: item renamed back to `pending/`, `apply_conflict` audited. Crash recovery decides memory items by content hash.
- `mailbox_ops` remain email-only (existing kind guard must keep holding).
- Both decision verbs stamp `decided_at` (ISO-8601) in the v2 upgrade. Reflection digest window: fixed 30 days by `decided_at`; envelopes without the stamp are excluded.
- The agent's write grant must NOT cover `queue/staging/<run_id>/run.json` (trusted sidecar) — only `proposal.json` and the `proposals/` dir.
- Copy tone: calm, no exclamation marks. High-tier copy: "Changes how your assistant behaves." Risk colors: green `--act*` acts, amber `--suggest*` suggests, terracotta `--warn*` warns (Tailwind `text-warn-ink`, `bg-warn-tint`, `border-warn-border`, `text-suggest-ink`).
- Never render agent/user content with `{@html}`.
- TDD per task; commit per task with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. NEVER push to origin.
- Suite gates: `cd backend && mix test`; `just codegen` then `git diff --exit-code frontend/src/lib/api/` after any RPC change; `cd frontend && bun run check && bun run test`.
- No prod users: no migrations or back-compat shims required (except the digest's decided_at exclusion rule above, which is behavior, not a shim).

---

### Task B1: Risk-tier classifier

**Files:**
- Create: `backend/lib/valea/agents/risk_tier.ex`
- Test: `backend/test/valea/agents/risk_tier_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.mount_for/2` (`(workspace, rel_path) :: mount | nil`; matches `mounts/<name>/…` for embedded regardless of enabled state, absolute paths for enabled external mounts).
- Produces: `Valea.Agents.RiskTier.classify(workspace :: String.t(), path :: String.t()) :: "high" | "medium" | nil` — `nil` when the path does not attribute to any mount. Used by B3 (finalize) and B10 (permission enrichment).

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/agents/risk_tier_test.exs
defmodule Valea.Agents.RiskTierTest do
  use ExUnit.Case, async: false

  alias Valea.Agents.RiskTier
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path}
  end

  test "knowledge page in a mount is medium", %{workspace: ws} do
    assert RiskTier.classify(ws, "mounts/primary/Pricing/Current Pricing.md") == "medium"
  end

  test "behavior-bearing mount files are high", %{workspace: ws} do
    assert RiskTier.classify(ws, "mounts/primary/Workflows/New Inquiry Triage.md") == "high"
    assert RiskTier.classify(ws, "mounts/primary/AGENTS.md") == "high"
    assert RiskTier.classify(ws, "mounts/primary/CLAUDE.md") == "high"
    assert RiskTier.classify(ws, "mounts/primary/icm.yaml") == "high"
  end

  test "shell paths are nil", %{workspace: ws} do
    assert RiskTier.classify(ws, "AGENTS.md") == nil
    assert RiskTier.classify(ws, "sources/mail/inbox.md") == nil
    assert RiskTier.classify(ws, "queue/pending/x.json") == nil
  end

  test "absolute path into an embedded mount classifies", %{workspace: ws} do
    abs = Path.join(ws, "mounts/primary/Workflows/New Inquiry Triage.md")
    assert RiskTier.classify(ws, abs) == "high"
  end

  test "non-binary and unattributable input is nil", %{workspace: ws} do
    assert RiskTier.classify(ws, nil) == nil
    assert RiskTier.classify(ws, "/somewhere/else/entirely.md") == nil
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/agents/risk_tier_test.exs`
Expected: FAIL — `Valea.Agents.RiskTier` is undefined.

- [ ] **Step 3: Implement**

```elixir
# backend/lib/valea/agents/risk_tier.ex
defmodule Valea.Agents.RiskTier do
  @moduledoc """
  Server-derived risk tier for a path that lives inside a mount: "high"
  for behavior-bearing files (the mount's instruction spine and its
  workflow contracts — an approved edit changes future agent behavior),
  "medium" for everything else inside a mount, nil for paths that do not
  attribute to any mount (the workspace shell, or nowhere). The tier is
  display + envelope metadata, never an access decision.
  """

  alias Valea.Mounts

  @behavior_files ["AGENTS.md", "CLAUDE.md", "icm.yaml"]

  @spec classify(String.t(), String.t() | nil) :: String.t() | nil
  def classify(workspace, path) when is_binary(path) do
    path = normalize(workspace, path)

    case Mounts.mount_for(workspace, path) do
      nil -> nil
      mount -> tier(inner_path(mount, path))
    end
  end

  def classify(_workspace, _path), do: nil

  # An absolute path under the workspace is the same content addressed
  # physically — attribute it as its workspace-relative form. Absolute
  # paths elsewhere stay absolute (external-mount vocabulary).
  defp normalize(workspace, "/" <> _ = abs) do
    case Path.relative_to(abs, workspace) do
      ^abs -> abs
      rel -> rel
    end
  end

  defp normalize(_workspace, rel), do: rel

  defp inner_path(%{rel_root: rel}, path) when is_binary(rel),
    do: String.replace_prefix(path, rel <> "/", "")

  defp inner_path(%{root: root}, path),
    do: String.replace_prefix(path, root <> "/", "")

  defp tier(inner) do
    if inner in @behavior_files or String.starts_with?(inner, "Workflows/") do
      "high"
    else
      "medium"
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/agents/risk_tier_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/agents/risk_tier.ex backend/test/valea/agents/risk_tier_test.exs
git commit -m "feat(backend): server-derived risk tier for mount paths"
```

---

### Task B2: Policy `write_roots` dir grants + public default read roots

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex` (decide/2 cond clause 6, ~line 103; new helper)
- Modify: `backend/lib/valea/agents/session_server.ex` (make `read_roots/1` and `extra_roots/1` public as `default_read_roots/1` / `default_extra_roots/1`, keep `Map.put_new_lazy` wiring)
- Test: `backend/test/valea/agents/permission_policy_test.exs` (extend)

**Interfaces:**
- Consumes: existing `decide(item, ctx)` and `Valea.Paths.resolve_real/2`.
- Produces: `policy_ctx[:write_roots] :: [abs_dir]` — in `"workflow"` sessions, write kinds resolving inside any write root (segment boundary) are auto-allowed, in addition to the exact `write_paths` list. `Valea.Agents.SessionServer.default_read_roots(workspace) :: [String.t()]` and `default_extra_roots(workspace) :: [String.t()]` for callers (B3's Runner) that must EXTEND the defaults rather than replace them.

- [ ] **Step 1: Write the failing tests** (append to `permission_policy_test.exs`; follow the file's existing item/ctx fixture helpers — an item is `%{"kind" => "write", "rawInput" => %{"file_path" => path}}` and ctx carries `workspace`, `session_kind`, `write_paths`)

```elixir
describe "write_roots dir grants" do
  test "workflow write inside a write_root is allowed", %{workspace: ws} do
    root = Path.join(ws, "queue/staging/r1/proposals")
    File.mkdir_p!(root)
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [], write_roots: [root]}
    item = %{"kind" => "write", "rawInput" => %{"file_path" => Path.join(root, "a.json")}}
    assert Valea.Agents.PermissionPolicy.decide(item, ctx) == {:allow, "allow_once"}
  end

  test "workflow write to the staging sidecar outside the root asks", %{workspace: ws} do
    root = Path.join(ws, "queue/staging/r1/proposals")
    File.mkdir_p!(root)
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [], write_roots: [root]}
    item = %{"kind" => "write", "rawInput" => %{"file_path" => Path.join(ws, "queue/staging/r1/run.json")}}
    assert Valea.Agents.PermissionPolicy.decide(item, ctx) == :ask
  end

  test "chat sessions get no write_roots allowance", %{workspace: ws} do
    root = Path.join(ws, "queue/staging/r1/proposals")
    File.mkdir_p!(root)
    ctx = %{workspace: ws, session_kind: "chat", write_paths: [], write_roots: [root]}
    item = %{"kind" => "write", "rawInput" => %{"file_path" => Path.join(root, "a.json")}}
    assert Valea.Agents.PermissionPolicy.decide(item, ctx) == :ask
  end

  test "prefix trick does not escape the root", %{workspace: ws} do
    root = Path.join(ws, "queue/staging/r1/proposals")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(ws, "queue/staging/r1/proposals-evil"))
    ctx = %{workspace: ws, session_kind: "workflow", write_paths: [], write_roots: [root]}
    item = %{"kind" => "write", "rawInput" => %{"file_path" => Path.join(ws, "queue/staging/r1/proposals-evil/a.json")}}
    assert Valea.Agents.PermissionPolicy.decide(item, ctx) == :ask
  end
end
```

- [ ] **Step 2: Run to verify failure** — `mix test test/valea/agents/permission_policy_test.exs`; the four new tests FAIL (`:ask` where allow expected / missing key handling).

- [ ] **Step 3: Implement.** In `decide/2`, replace clause 6:

```elixir
      kind in @write_kinds and ctx.session_kind == "workflow" and
          (all_in_write_paths?(resolved, ctx.write_paths, ctx.workspace) or
             all_in_write_roots?(resolved, ctx[:write_roots] || [], ctx.workspace)) ->
        {:allow, "allow_once"}
```

Add next to `all_in_write_paths?/3`:

```elixir
  # Directory write grants: every resolved candidate must land inside one
  # of the granted roots (segment boundary — "proposals-evil" is not
  # inside "proposals"). Roots are resolved like write_paths so a symlink
  # cannot relocate a grant.
  defp all_in_write_roots?(_resolved, [], _workspace), do: false

  defp all_in_write_roots?(resolved, roots, workspace) do
    allowed =
      for root <- roots,
          {:ok, real} <- [Valea.Paths.resolve_real(root, workspace)],
          do: real

    allowed != [] and
      Enum.all?(resolved, fn
        {:ok, p} -> Enum.any?(allowed, &(p == &1 or String.starts_with?(p, &1 <> "/")))
        _ -> false
      end)
  end
```

In `session_server.ex`, rename the private `read_roots/1` → public `default_read_roots/1` and `extra_roots/1` → public `default_extra_roots/1` (keep bodies identical; update the two `Map.put_new_lazy` call sites in `init/1`). Add one-line `@doc` on each: callers extending the defaults (per-run staging read grants) use these instead of re-deriving mount composition.

- [ ] **Step 4: Run** `mix test test/valea/agents/permission_policy_test.exs test/valea/agents/session_server_test.exs` — PASS; then full `mix test` — no regressions.

- [ ] **Step 5: Commit** — `git commit -m "feat(backend): policy write_roots dir grants; public default session read roots"`

---

### Task B3: Memory proposal pairs — validation, finalize fan-out, runner grants + prompt

**Files:**
- Create: `backend/lib/valea/workflows/memory_proposal.ex`
- Modify: `backend/lib/valea/workflows/runner.ex` (`start_run/6` policy_ctx + prompt; `finalize/2` + helpers)
- Test: `backend/test/valea/workflows/memory_proposal_test.exs`, extend `backend/test/valea/workflows/runner_test.exs`

**Interfaces:**
- Consumes: B1 `RiskTier.classify/2`; B2 `default_read_roots/1`, `write_roots` ctx key; `Valea.Mounts.mount_for/2` + mount struct `%{name, rel_root, root, enabled, degraded}`; `Valea.Paths.resolve_real/2`; existing `write_pending!/4`-style atomic write.
- Produces:
  - `Valea.Workflows.MemoryProposal.load_pairs(staging_dir) :: [{json_filename, {:ok, %{manifest: map, content: binary}} | {:error, atom}}]` — sorted by filename.
  - `Valea.Workflows.MemoryProposal.check_target(workspace, target_path) :: {:ok, %{mount: mount, abs: String.t()}} | {:error, :not_in_mount | :mount_not_enabled | :outside_mount}`.
  - Finalize emits one pending envelope per valid pair: `run_id`-suffixed id, `risk_level` from RiskTier, `payload.kind "memory_update"`, `proposed_action %{"type" => "apply_page_content", "target_path", "base_sha256", "content_markdown"}`, no `source_message` key. Audit: `queue_item_created` per item; `memory_proposal_invalid` (`%{"run_id","file","reason"}`) per invalid pair; run outcome `proposal_created` if ≥1 item (primary or memory) was created, else existing rules. Staging is removed only when NOTHING was invalid.

- [ ] **Step 1: Failing tests for the module**

```elixir
# backend/test/valea/workflows/memory_proposal_test.exs
defmodule Valea.Workflows.MemoryProposalTest do
  use ExUnit.Case, async: false

  alias Valea.Workflows.MemoryProposal
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    staging = Path.join(ws.path, "queue/staging/r1")
    File.mkdir_p!(Path.join(staging, "proposals"))

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path, staging: staging}
  end

  defp put_pair(staging, name, manifest, content) do
    File.write!(Path.join([staging, "proposals", name <> ".json"]), Jason.encode!(manifest))
    File.write!(Path.join([staging, "proposals", name <> ".md"]), content)
  end

  defp manifest(target, base \\ nil) do
    %{
      "schema" => "memory_update/v1",
      "target_path" => target,
      "base_sha256" => base,
      "reason" => "rate changed",
      "sources" => ["mounts/primary/Pricing/Current Pricing.md"]
    }
  end

  test "valid pair loads with content", %{staging: staging} do
    put_pair(staging, "pricing", manifest("mounts/primary/Pricing/Current Pricing.md"), "# New\n")
    assert [{"pricing.json", {:ok, %{manifest: m, content: "# New\n"}}}] =
             MemoryProposal.load_pairs(staging)
    assert m["reason"] == "rate changed"
  end

  test "orphaned json and orphaned md are errors", %{staging: staging} do
    File.write!(Path.join([staging, "proposals", "a.json"]), Jason.encode!(manifest("mounts/primary/x.md")))
    File.write!(Path.join([staging, "proposals", "b.md"]), "hi")
    assert [{"a.json", {:error, :missing_content}}, {"b.md", {:error, :orphaned_content}}] =
             MemoryProposal.load_pairs(staging)
  end

  test "bad schema, empty reason, bad hash are errors", %{staging: staging} do
    put_pair(staging, "s", %{manifest("mounts/primary/x.md") | "schema" => "nope/v1"}, "x")
    put_pair(staging, "r", %{manifest("mounts/primary/x.md") | "reason" => " "}, "x")
    put_pair(staging, "h", %{manifest("mounts/primary/x.md") | "base_sha256" => "zz"}, "x")
    results = Map.new(MemoryProposal.load_pairs(staging))
    assert results["s.json"] == {:error, :invalid_manifest}
    assert results["r.json"] == {:error, :invalid_manifest}
    assert results["h.json"] == {:error, :invalid_manifest}
  end

  test "check_target accepts an enabled embedded mount page", %{workspace: ws} do
    assert {:ok, %{abs: abs}} =
             MemoryProposal.check_target(ws, "mounts/primary/Pricing/Current Pricing.md")
    assert String.ends_with?(abs, "/mounts/primary/Pricing/Current Pricing.md")
  end

  test "check_target rejects shell, traversal, and unknown-mount targets", %{workspace: ws} do
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "AGENTS.md")
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "sources/mail/inbox.md")
    assert {:error, :outside_mount} =
             MemoryProposal.check_target(ws, "mounts/primary/../../etc/passwd")
    assert {:error, :not_in_mount} = MemoryProposal.check_target(ws, "/tmp/nope.md")
  end

  test "check_target rejects a disabled mount", %{workspace: ws} do
    {:ok, _} = Valea.Mounts.set_enabled("primary", false)
    assert {:error, :mount_not_enabled} =
             MemoryProposal.check_target(ws, "mounts/primary/Pricing/Current Pricing.md")
  end
end
```

- [ ] **Step 2: Run** — module undefined, FAIL.

- [ ] **Step 3: Implement the module**

```elixir
# backend/lib/valea/workflows/memory_proposal.ex
defmodule Valea.Workflows.MemoryProposal do
  @moduledoc """
  Loading + validation for agent-staged memory-update proposal pairs
  (`proposals/<name>.json` manifest + sibling `<name>.md` content), and
  the server-owned target containment check. Trust boundary: everything
  here treats the pair as untrusted input; the manifest's claims are
  verified, never carried (risk tier is derived elsewhere, from the
  target path alone).
  """

  alias Valea.Mounts

  @spec load_pairs(String.t()) :: [{String.t(), {:ok, map()} | {:error, atom()}}]
  def load_pairs(staging_dir) do
    dir = Path.join(staging_dir, "proposals")
    files = dir |> Path.join("*") |> Path.wildcard() |> Enum.map(&Path.basename/1)
    jsons = files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
    mds = files |> Enum.filter(&String.ends_with?(&1, ".md")) |> MapSet.new()

    claimed = MapSet.new(jsons, &(Path.rootname(&1) <> ".md"))

    pairs = Enum.map(jsons, fn json -> {json, load_pair(dir, json, mds)} end)

    orphans =
      for md <- Enum.sort(MapSet.to_list(mds)), not MapSet.member?(claimed, md) do
        {md, {:error, :orphaned_content}}
      end

    pairs ++ orphans
  end

  defp load_pair(dir, json, mds) do
    md = Path.rootname(json) <> ".md"

    with {:md, true} <- {:md, MapSet.member?(mds, md)},
         {:ok, bytes} <- File.read(Path.join(dir, json)),
         {:ok, %{} = manifest} <- Jason.decode(bytes),
         true <- valid_manifest?(manifest),
         {:ok, content} <- File.read(Path.join(dir, md)),
         true <- String.valid?(content) do
      {:ok, %{manifest: manifest, content: content}}
    else
      {:md, false} -> {:error, :missing_content}
      false -> {:error, :invalid_manifest}
      _ -> {:error, :invalid_pair}
    end
  end

  defp valid_manifest?(m) do
    m["schema"] == "memory_update/v1" and
      nonempty?(m["target_path"]) and
      valid_base?(m["base_sha256"]) and
      nonempty?(m["reason"]) and
      is_list(m["sources"]) and Enum.all?(m["sources"], &is_binary/1)
  end

  defp valid_base?(nil), do: true
  defp valid_base?(b) when is_binary(b), do: b =~ ~r/\A[0-9a-f]{64}\z/
  defp valid_base?(_b), do: false

  defp nonempty?(s), do: is_binary(s) and String.trim(s) != ""

  @doc """
  Server-owned containment: the target must attribute to an ENABLED,
  non-degraded mount, and its physical resolution must stay inside that
  mount's root (create targets may not exist yet — resolve_real appends
  the missing remainder literally but still applies `..` physically).
  Returns the lexical absolute path to write.
  """
  @spec check_target(String.t(), String.t()) ::
          {:ok, %{mount: map(), abs: String.t()}}
          | {:error, :not_in_mount | :mount_not_enabled | :outside_mount}
  def check_target(workspace, target_path) do
    case Mounts.mount_for(workspace, target_path) do
      nil ->
        {:error, :not_in_mount}

      %{enabled: true, degraded: nil} = mount ->
        root = mount_root_abs(workspace, mount)
        abs = target_abs(workspace, target_path)

        with true <- String.starts_with?(abs, root <> "/"),
             {:ok, _real} <- Valea.Paths.resolve_real(abs, root) do
          {:ok, %{mount: mount, abs: abs}}
        else
          _ -> {:error, :outside_mount}
        end

      _mount ->
        {:error, :mount_not_enabled}
    end
  end

  defp mount_root_abs(workspace, %{rel_root: rel}) when is_binary(rel),
    do: Path.join(workspace, rel)

  defp mount_root_abs(_workspace, %{root: root}), do: root

  defp target_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp target_abs(workspace, rel), do: Path.expand(rel, workspace)
end
```

Note: `mount_for/2` never matches a disabled EXTERNAL mount (they aren't in the declared-effective set), but DOES match a disabled embedded mount — hence the explicit `enabled/degraded` clause. `Path.expand` collapses `..` lexically, so `mounts/primary/../../etc/passwd` fails the prefix check before `resolve_real` runs.

- [ ] **Step 4: Run module tests** — PASS.

- [ ] **Step 5: Failing runner tests** (append to `runner_test.exs`; use its existing helpers for creating a workspace, an enabled workflow, and driving `finalize/2` directly — mirror the style of `"finalize/2 with an invalid payload..."`):

```elixir
describe "memory proposal pairs" do
  # helper mirroring the file's existing sidecar/staging setup
  defp seed_run!(ws, run_id) do
    staging = Path.join(ws, "queue/staging/#{run_id}")
    File.mkdir_p!(Path.join(staging, "proposals"))

    run = %{
      "run_id" => run_id,
      "session_id" => "s1",
      "workflow" => "mounts/primary/Workflows/New Inquiry Triage.md",
      "workflow_hash" => String.duplicate("a", 64),
      "input" => "sources/mail/messages/x.md",
      "input_hash" => String.duplicate("b", 64),
      "risk_level" => "medium",
      "approval" => %{"required" => true},
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(Path.join(staging, "run.json"), Jason.encode!(run))
    staging
  end

  test "two valid pairs become two pending items with server-owned fields", %{workspace: ws} do
    staging = seed_run!(ws, "r-mem-1")
    target = "mounts/primary/Pricing/Current Pricing.md"
    base = :crypto.hash(:sha256, File.read!(Path.join(ws, target))) |> Base.encode16(case: :lower)

    File.write!(Path.join(staging, "proposals/a-pricing.json"),
      Jason.encode!(%{"schema" => "memory_update/v1", "target_path" => target,
        "base_sha256" => base, "reason" => "rate changed", "sources" => [target]}))
    File.write!(Path.join(staging, "proposals/a-pricing.md"), "# Pricing\n\n150 EUR\n")

    File.write!(Path.join(staging, "proposals/b-wf.json"),
      Jason.encode!(%{"schema" => "memory_update/v1",
        "target_path" => "mounts/primary/Workflows/New Inquiry Triage.md",
        "base_sha256" => nil, "reason" => "tighten steps", "sources" => []}))
    File.write!(Path.join(staging, "proposals/b-wf.md"), "# WF\n")

    :ok = Valea.Workflows.Runner.finalize("r-mem-1", ws)

    p1 = Path.join(ws, "queue/pending/r-mem-1-m1.json") |> File.read!() |> Jason.decode!()
    p2 = Path.join(ws, "queue/pending/r-mem-1-m2.json") |> File.read!() |> Jason.decode!()

    assert p1["run_id"] == "r-mem-1-m1"
    assert p1["risk_level"] == "medium"
    assert p1["payload"]["kind"] == "memory_update"
    assert p1["payload"]["summary"] == "rate changed"
    assert p1["payload"]["proposed_action"]["type"] == "apply_page_content"
    assert p1["payload"]["proposed_action"]["content_markdown"] == "# Pricing\n\n150 EUR\n"
    refute Map.has_key?(p1, "source_message")

    # server-derived tier overrides anything claimed: workflow target is high
    assert p2["risk_level"] == "high"
    assert p2["payload"]["title"] == "New page: New Inquiry Triage.md"

    refute File.exists?(Path.join(ws, "queue/staging/r-mem-1"))
  end

  test "invalid pair audits memory_proposal_invalid and keeps staging", %{workspace: ws} do
    staging = seed_run!(ws, "r-mem-2")
    File.write!(Path.join(staging, "proposals/bad.json"),
      Jason.encode!(%{"schema" => "memory_update/v1", "target_path" => "AGENTS.md",
        "base_sha256" => nil, "reason" => "x", "sources" => []}))
    File.write!(Path.join(staging, "proposals/bad.md"), "x")

    :ok = Valea.Workflows.Runner.finalize("r-mem-2", ws)

    assert Path.join(ws, "queue/pending") |> Path.join("r-mem-2*") |> Path.wildcard() == []
    assert File.exists?(Path.join(ws, "queue/staging/r-mem-2"))

    {:ok, entries} = Valea.Audit.entries(50)
    assert Enum.any?(entries, &(&1["type"] == "memory_proposal_invalid" and &1["file"] == "bad.json"))
  end

  test "run/2 grants: proposals dir writable, run.json not, staging readable" do
    # covered at policy level in B2; here assert the ctx the Runner builds
    # (drive start_run via run/2 with the fake harness as the existing
    # "happy path" test does, then inspect the session's policy_ctx)
  end
end
```

For the third test, follow the existing runner happy-path test's fake-harness setup and assert on the started session's `policy_ctx` (the fake adapter records opts): `write_paths == [<staging>/proposal.json]`, `write_roots == [<staging>/proposals]`, and `"queue/staging/<run_id>" in read_roots`.

- [ ] **Step 6: Run** — FAIL (no pair handling, no grants).

- [ ] **Step 7: Implement runner changes.**

In `start_run/6`: after `File.mkdir_p!(staging_dir)` add `File.mkdir_p!(Path.join(staging_dir, "proposals"))`. Change the `policy_ctx`:

```elixir
      policy_ctx: %{
        workspace: workspace,
        session_kind: "workflow",
        write_paths: [staging_abs],
        write_roots: [Path.join(staging_dir, "proposals")],
        read_roots:
          Valea.Agents.SessionServer.default_read_roots(workspace) ++
            [Path.join(["queue", "staging", run_id])]
      },
```

Replace `prompt/3` body with:

```elixir
    """
    Read AGENTS.md first if you have not already. Then execute the workflow
    contract at "#{workflow_path}" against the input file "#{input_path}".
    Follow the contract's Process steps. Read only the pages its Inputs and
    sources name. If the contract's Outputs call for a proposal, write
    exactly one proposal/v1 JSON file to "#{staging_rel}". If you noticed
    business knowledge that is stale, missing, or contradicted, you may
    additionally propose memory updates: for each one, write a pair of
    files under "#{Path.dirname(staging_rel)}/proposals/" — <name>.md (the
    complete new page content) and <name>.json (a memory_update/v1
    manifest) — following the memory-update contract in AGENTS.md. Write
    nothing else. When done, state in one sentence what you prepared, and
    stop.
    """
```

Restructure `finalize/2`: read the sidecar ONCE up front (absent sidecar keeps current behavior paths), then:

```elixir
  def finalize(run_id, workspace) do
    staging_dir = staging_dir(workspace, run_id)

    primary = finalize_primary(staging_dir, workspace, run_id)     # :created | :invalid | :absent
    memory = finalize_memory(staging_dir, workspace, run_id)       # {created_count, invalid_count}

    outcome_and_cleanup(staging_dir, run_id, primary, memory)
  end
```

- `finalize_primary/3` is the existing proposal.json flow, refactored to RETURN `:created | :invalid | :absent` instead of finishing the run itself (keep `queue_item_created` audit inside it; keep validation identical).
- `finalize_memory/3`: needs the sidecar — on unreadable sidecar return `{0, 0}` (primary path already audits). For each `MemoryProposal.load_pairs(staging_dir)` entry with index `i` (1-based over the FULL sorted pair list, so ids are stable even when some pairs are invalid):
  - `{:error, reason}` → `audit("memory_proposal_invalid", %{"run_id" => run_id, "file" => file, "reason" => to_string(reason)})`, count invalid.
  - `{:ok, %{manifest: m, content: content}}` → `MemoryProposal.check_target(workspace, m["target_path"])`:
    - `{:error, reason}` → same invalid audit path.
    - `{:ok, _}` → build + write the envelope, audit `queue_item_created` `%{"run_id" => item_id, "kind" => "memory_update"}`, count created.

Envelope builder (new private):

```elixir
  defp memory_envelope(run, item_id, manifest, content, tier) do
    base = Path.basename(manifest["target_path"])

    title =
      if manifest["base_sha256"] == nil, do: "New page: " <> base, else: "Update " <> base

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
```

with `tier = Valea.Agents.RiskTier.classify(workspace, m["target_path"]) || "medium"` and `item_id = "#{run_id}-m#{i}"`; write via the same tmp+rename atomic write `write_pending!` uses.

- `outcome_and_cleanup/4`: any created (primary `:created` or memory created > 0) → outcome `"proposal_created"`; else if primary `:invalid` or invalid > 0 → `"invalid_proposal"`; else `"no_proposal"`. `File.rm_rf(staging_dir)` ONLY when nothing was invalid (primary `:invalid` or invalid > 0 keeps staging for inspection — matches today's invalid behavior). Audit the single `workflow_run_finished` with the chosen outcome.

- [ ] **Step 8: Run** `mix test test/valea/workflows/` then full `mix test` — PASS, no regressions (existing finalize tests pin the primary paths; if an existing test asserted `rm_rf` timing, reconcile against the rules above — they are behavior-identical for runs without pairs).

- [ ] **Step 9: Commit** — `git commit -m "feat(backend): memory-update proposal pairs — validation, finalize fan-out, runner grants + prompt"`

---

### Task B4: Queue — `memory_update` envelopes + hash-guarded apply executor

**Files:**
- Modify: `backend/lib/valea/queue.ex` (`valid_payload?/1`, `valid_action?` split by kind, `approve/2` execute arm, `upgrade_envelope/3` decided_at, helpers)
- Test: extend `backend/test/valea/queue_test.exs`

**Interfaces:**
- Consumes: B3 `MemoryProposal.check_target/2` (re-run at approve — the boundary may have changed since finalize).
- Produces: `approve/2` returns `{:ok, %{draft_path: String.t() | nil, applied_path: String.t() | nil}}` (email fills draft_path, memory fills applied_path) or `{:error, :apply_conflict}` (item back in `pending/`). Decided envelopes carry `"decided_at"` (both verbs, ISO-8601). B5/B7/B12 depend on these exact shapes.

- [ ] **Step 1: Failing tests** (append to `queue_test.exs`; use its existing workspace setup + a helper that writes a pending memory envelope):

```elixir
  defp pending_memory!(ws, run_id, target, base, content) do
    item = %{
      "schema" => "queue_item/v2",
      "run_id" => run_id,
      "workflow" => "mounts/primary/Workflows/New Inquiry Triage.md",
      "risk_level" => "medium",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{
        "title" => "Update x", "summary" => "why", "kind" => "memory_update",
        "sources" => [],
        "proposed_action" => %{
          "type" => "apply_page_content", "target_path" => target,
          "base_sha256" => base, "content_markdown" => content
        }
      }
    }
    dir = Path.join(ws, "queue/pending")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, run_id <> ".json"), Jason.encode!(item))
    item
  end

  describe "apply_page_content" do
    test "approve applies an edit when the base hash matches", %{workspace: ws} do
      target = "mounts/primary/Pricing/Current Pricing.md"
      old = File.read!(Path.join(ws, target))
      base = :crypto.hash(:sha256, old) |> Base.encode16(case: :lower)
      pending_memory!(ws, "m1", target, base, "# Pricing\n\n150\n")

      {:ok, %{item: _, revision: rev}} = Valea.Queue.get("m1")
      assert {:ok, %{applied_path: ^target, draft_path: nil}} = Valea.Queue.approve("m1", rev)
      assert File.read!(Path.join(ws, target)) == "# Pricing\n\n150\n"
      assert File.exists?(Path.join(ws, "queue/approved/m1.json"))

      approved = Path.join(ws, "queue/approved/m1.json") |> File.read!() |> Jason.decode!()
      assert approved["decided_at"]
      refute Map.has_key?(approved, "mailbox_ops")
    end

    test "approve creates a page when base is null and target absent", %{workspace: ws} do
      target = "mounts/primary/Decisions/2026-07.md"
      pending_memory!(ws, "m2", target, nil, "# Decisions\n")
      {:ok, %{revision: rev}} = Valea.Queue.get("m2")
      assert {:ok, %{applied_path: ^target}} = Valea.Queue.approve("m2", rev)
      assert File.read!(Path.join(ws, target)) == "# Decisions\n"
    end

    test "hash mismatch: nothing written, item back in pending, apply_conflict audited", %{workspace: ws} do
      target = "mounts/primary/Pricing/Current Pricing.md"
      pending_memory!(ws, "m3", target, String.duplicate("0", 64), "# clobber\n")
      old = File.read!(Path.join(ws, target))
      {:ok, %{revision: rev}} = Valea.Queue.get("m3")

      assert {:error, :apply_conflict} = Valea.Queue.approve("m3", rev)
      assert File.read!(Path.join(ws, target)) == old
      assert File.exists?(Path.join(ws, "queue/pending/m3.json"))
      refute File.exists?(Path.join(ws, "queue/processing/m3.json"))

      {:ok, entries} = Valea.Audit.entries(20)
      assert Enum.any?(entries, &(&1["type"] == "apply_conflict" and &1["run_id"] == "m3"))
    end

    test "create-target-exists and disabled-mount are conflicts too", %{workspace: ws} do
      target = "mounts/primary/Pricing/Current Pricing.md"
      pending_memory!(ws, "m4", target, nil, "x")
      {:ok, %{revision: rev}} = Valea.Queue.get("m4")
      assert {:error, :apply_conflict} = Valea.Queue.approve("m4", rev)

      base = :crypto.hash(:sha256, File.read!(Path.join(ws, target))) |> Base.encode16(case: :lower)
      pending_memory!(ws, "m5", target, base, "y")
      {:ok, _} = Valea.Mounts.set_enabled("primary", false)
      {:ok, %{revision: rev5}} = Valea.Queue.get("m5")
      assert {:error, :apply_conflict} = Valea.Queue.approve("m5", rev5)
      {:ok, _} = Valea.Mounts.set_enabled("primary", true)
    end

    test "malformed apply action fails envelope validation", %{workspace: ws} do
      pending_memory!(ws, "m6", "mounts/primary/x.md", "not-hex", "c")
      assert {:error, :queue_item_invalid} = Valea.Queue.get("m6")
    end

    test "reject of a memory item lands with decided_at and no mailbox_ops", %{workspace: ws} do
      target = "mounts/primary/Pricing/Current Pricing.md"
      base = :crypto.hash(:sha256, File.read!(Path.join(ws, target))) |> Base.encode16(case: :lower)
      pending_memory!(ws, "m7", target, base, "z")
      {:ok, %{revision: rev}} = Valea.Queue.get("m7")
      assert {:ok, %{}} = Valea.Queue.reject("m7", rev)
      rejected = Path.join(ws, "queue/rejected/m7.json") |> File.read!() |> Jason.decode!()
      assert rejected["decided_at"]
      refute Map.has_key?(rejected, "mailbox_ops")
    end
  end
```

- [ ] **Step 2: Run** — FAIL (validation rejects the kind; no apply arm).

- [ ] **Step 3: Implement.**

Validation — replace `valid_payload?/1`'s action check with kind-aware dispatch:

```elixir
  defp valid_payload?(%{} = payload) do
    nonempty_string?(payload["title"]) and
      nonempty_string?(payload["summary"]) and
      nonempty_string?(payload["kind"]) and
      list_of_strings?(payload["sources"]) and
      valid_action_for_kind?(payload["kind"], payload["proposed_action"])
  end

  defp valid_action_for_kind?("memory_update", %{
         "type" => "apply_page_content",
         "target_path" => target,
         "base_sha256" => base,
         "content_markdown" => content
       })
       when is_binary(target) and is_binary(content) do
    nonempty_string?(target) and (is_nil(base) or hex64?(base))
  end

  defp valid_action_for_kind?("memory_update", _action), do: false
  defp valid_action_for_kind?(_kind, action), do: valid_action?(action)

  defp hex64?(b) when is_binary(b), do: b =~ ~r/\A[0-9a-f]{64}\z/
  defp hex64?(_b), do: false
```

(`valid_action?` keeps its existing email clauses unchanged.)

Approve — inside `approve/2`, after the claim + sync `approval_intent`, branch:

```elixir
      case item["payload"]["kind"] do
        "memory_update" -> execute_memory(workspace, run_id, item)
        _ -> execute_email(workspace, run_id, item)
      end
```

`execute_email/3` is today's body extracted verbatim (ensure_draft → action_executed → complete_approval → item_approved → broadcast_ops → `{:ok, %{draft_path: draft_rel_path(run_id), applied_path: nil}}`). New:

```elixir
  defp execute_memory(workspace, run_id, item) do
    action = item["payload"]["proposed_action"]

    case apply_page_content(workspace, action) do
      {:ok, target} ->
        audit("action_executed", %{"run_id" => run_id, "target_path" => target})
        complete_approval(workspace, run_id, item)
        audit("item_approved", %{"run_id" => run_id})
        {:ok, %{draft_path: nil, applied_path: target}}

      {:error, reason} ->
        # Nothing observable happened — hand the CLAIMED item back for the
        # human to re-decide with fresh context. Same recovery posture as
        # a crashed pre-execute approve.
        File.mkdir_p!(pending_dir(workspace))
        File.rename!(processing_path(workspace, run_id), pending_path(workspace, run_id))

        audit("apply_conflict", %{
          "run_id" => run_id,
          "target_path" => action["target_path"],
          "reason" => to_string(reason)
        })

        {:error, :apply_conflict}
    end
  end

  defp apply_page_content(workspace, action) do
    target = action["target_path"]

    with {:ok, %{abs: abs}} <- Valea.Workflows.MemoryProposal.check_target(workspace, target),
         :ok <- check_base(abs, action["base_sha256"]) do
      File.mkdir_p!(Path.dirname(abs))
      atomic_write!(abs, action["content_markdown"])
      {:ok, target}
    end
  end

  defp check_base(abs, nil) do
    if File.exists?(abs), do: {:error, :target_exists}, else: :ok
  end

  defp check_base(abs, base) do
    case File.read(abs) do
      {:ok, bytes} -> if sha256(bytes) == base, do: :ok, else: {:error, :page_changed}
      {:error, :enoent} -> {:error, :page_missing}
      {:error, reason} -> {:error, reason}
    end
  end
```

Note the email approve return shape changes to `%{draft_path: ..., applied_path: nil}` — update the existing happy-path assertion in `queue_test.exs` and the RPC layer expectation (B7 rewires the RPC; until then `queue_api.ex`'s `approve_item` reads `:draft_path` from the map, which still exists — verify with the suite).

`upgrade_envelope/3` adds the stamp (both verbs + recovery reuse it):

```elixir
  defp upgrade_envelope(workspace, item, op_names) do
    item
    |> Map.put("schema", "queue_item/v2")
    |> Map.put("decided_at", DateTime.utc_now() |> DateTime.to_iso8601())
    |> maybe_put_mailbox_ops(workspace, item, op_names)
  end
```

Also broadcast: `execute_memory` does NOT call `broadcast_ops/1` (no mailbox ops), but the queue-changed UI refresh comes from the watcher's `queue_changed`, which fires on the directory renames — no extra plumbing.

- [ ] **Step 4: Run** `mix test test/valea/queue_test.exs` then full `mix test` — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(backend): queue apply_page_content executor with hash guard, conflict hand-back, decided_at"`

---

### Task B5: Crash recovery for memory items

**Files:**
- Modify: `backend/lib/valea/queue.ex` (`recover_one/2` + new helpers)
- Test: extend `backend/test/valea/queue_test.exs`

**Interfaces:**
- Consumes: B4's envelope shapes; existing `recover/1` sweep.
- Produces: deterministic recovery — a `memory_update` item in `processing/` whose target's bytes hash to `content_markdown` is finished into `approved/` (`item_approved` with `recovered: true`, decided_at stamped); otherwise handed back to `pending/` (`approval_recovered`). Email behavior unchanged.

- [ ] **Step 1: Failing tests**

```elixir
  describe "recover/1 for memory items" do
    test "apply happened, crash before terminal rename → finished", %{workspace: ws} do
      target = "mounts/primary/Pricing/Current Pricing.md"
      content = "# Applied\n"
      item = pending_memory!(ws, "mr1", target, String.duplicate("0", 64), content)
      # simulate: claimed + applied, then crash
      File.mkdir_p!(Path.join(ws, "queue/processing"))
      File.rename!(Path.join(ws, "queue/pending/mr1.json"), Path.join(ws, "queue/processing/mr1.json"))
      File.write!(Path.join(ws, target), content)

      :ok = Valea.Queue.recover(ws)

      assert File.exists?(Path.join(ws, "queue/approved/mr1.json"))
      approved = Path.join(ws, "queue/approved/mr1.json") |> File.read!() |> Jason.decode!()
      assert approved["decided_at"]
      _ = item
    end

    test "crash before apply → handed back to pending", %{workspace: ws} do
      target = "mounts/primary/Pricing/Current Pricing.md"
      pending_memory!(ws, "mr2", target, String.duplicate("0", 64), "# Never applied\n")
      File.mkdir_p!(Path.join(ws, "queue/processing"))
      File.rename!(Path.join(ws, "queue/pending/mr2.json"), Path.join(ws, "queue/processing/mr2.json"))

      :ok = Valea.Queue.recover(ws)

      assert File.exists?(Path.join(ws, "queue/pending/mr2.json"))
      refute File.exists?(Path.join(ws, "queue/approved/mr2.json"))
    end
  end
```

- [ ] **Step 2: Run** — first test FAIL (memory item lands back in pending because no draft exists).

- [ ] **Step 3: Implement.** In `recover_one/2`, decide by kind first:

```elixir
  defp recover_one(workspace, path) do
    run_id = Path.basename(path, ".json")

    case classify_recovery(workspace, path) do
      :finish_memory -> finish_recovered_memory(workspace, path, run_id)
      :repend -> repend!(workspace, path, run_id)
      :email -> recover_email(workspace, path, run_id)
    end
  end

  # Memory items are decided by CONTENT: the envelope carries the exact
  # bytes the apply would have written, so "did the apply happen" is a
  # pure hash comparison against the target — no draft file to consult.
  defp classify_recovery(workspace, path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"payload" => %{"kind" => "memory_update"}} = item} <- Jason.decode(bytes) do
      action = item["payload"]["proposed_action"]
      abs = memory_target_abs(workspace, action["target_path"])

      case File.read(abs) do
        {:ok, current} ->
          if sha256(current) == sha256(action["content_markdown"] || ""),
            do: :finish_memory,
            else: :repend

        _ ->
          :repend
      end
    else
      _ -> :email
    end
  end

  defp memory_target_abs(_workspace, "/" <> _ = abs), do: abs
  defp memory_target_abs(workspace, rel), do: Path.join(workspace, rel)

  defp finish_recovered_memory(workspace, path, run_id) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = item} <- Jason.decode(bytes) do
      atomic_write!(path, Jason.encode!(upgrade_envelope(workspace, item, [])))
    end

    File.mkdir_p!(approved_dir(workspace))
    File.rename!(path, approved_path(workspace, run_id))
    audit("item_approved", %{"run_id" => run_id, "recovered" => true})
  end
```

`recover_email/3` is today's draft-based body extracted verbatim; `repend!/3` is the existing hand-back branch extracted (mkdir pending, rename, audit `approval_recovered`). `upgrade_envelope(workspace, item, [])` with an empty op list adds schema + decided_at; `maybe_put_mailbox_ops` already no-ops for non-email kinds.

- [ ] **Step 4: Run** queue tests + full `mix test` — PASS (existing recovery tests pin email behavior).

- [ ] **Step 5: Commit** — `git commit -m "feat(backend): content-hash crash recovery for memory queue items"`

---

### Task B6: Rejection reasons end-to-end (queue → RPC → client)

**Files:**
- Modify: `backend/lib/valea/queue.ex` (`reject/3`, `complete_rejection/4`, `decided_entry/2` + `list_decided/0` fields)
- Modify: `backend/lib/valea/api/queue_api.ex` (`reject_item` gains `reason` arg)
- Modify: `frontend/src/lib/api/client.ts` (rejectQueueItem signature), `frontend/src/lib/stores/queue.svelte.ts` (`reject(runId, revision, reason?)`)
- Test: `backend/test/valea/queue_test.exs`, `backend/test/valea_web/queue_rpc_test.exs`, `frontend/src/lib/stores/queue.test.ts`

**Interfaces:**
- Produces: `Valea.Queue.reject(run_id, revision, reason \\ nil)`; decided envelope gains `"decision" => %{"reason" => reason}` when a non-blank reason was given; `item_rejected` audit gains `"reason"`; `list_decided/0` entries gain `decision` and `decided_at`. RPC `reject_item(run_id, revision, generation, reason \\ nil)`. Store `queueStore.reject(runId, revision, reason?)`.

- [ ] **Step 1: Failing backend tests**

```elixir
  test "reject/3 persists a trimmed reason in envelope and audit", %{workspace: ws} do
    target = "mounts/primary/Pricing/Current Pricing.md"
    base = :crypto.hash(:sha256, File.read!(Path.join(ws, target))) |> Base.encode16(case: :lower)
    pending_memory!(ws, "rr1", target, base, "x")
    {:ok, %{revision: rev}} = Valea.Queue.get("rr1")

    assert {:ok, %{}} = Valea.Queue.reject("rr1", rev, "  too pushy  ")

    rejected = Path.join(ws, "queue/rejected/rr1.json") |> File.read!() |> Jason.decode!()
    assert rejected["decision"] == %{"reason" => "too pushy"}

    {:ok, entries} = Valea.Audit.entries(10)
    assert Enum.any?(entries, &(&1["type"] == "item_rejected" and &1["reason"] == "too pushy"))

    {:ok, decided} = Valea.Queue.list_decided()
    entry = Enum.find(decided, &(&1.run_id == "rr1"))
    assert entry.decision == %{"reason" => "too pushy"}
    assert entry.decided_at
  end

  test "reject/2 (no reason) leaves no decision key", %{workspace: ws} do
    # ... same setup with run id rr2, call Valea.Queue.reject("rr2", rev)
    # assert rejected envelope has no "decision" key and audit entry has no "reason"
  end
```

(Write the second test in full — same shape as the first with the assertions inverted.)

- [ ] **Step 2: Run** — FAIL (reject/3 undefined).

- [ ] **Step 3: Implement.**

```elixir
  @spec reject(String.t(), revision(), String.t() | nil) :: ...
  def reject(run_id, revision, reason \\ nil) do
    ...existing with-chain unchanged, but:
      :ok <- claim(workspace, run_id) do
      complete_rejection(workspace, run_id, item, normalize_reason(reason))
      audit("item_rejected", reject_audit(run_id, normalize_reason(reason)))
      ...
  end

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_binary(reason) do
    case reason |> String.trim() |> String.slice(0, 500) do
      "" -> nil
      trimmed -> trimmed
    end
  end
  defp normalize_reason(_reason), do: nil

  defp reject_audit(run_id, nil), do: %{"run_id" => run_id}
  defp reject_audit(run_id, reason), do: %{"run_id" => run_id, "reason" => reason}
```

`complete_rejection/4` puts `"decision" => %{"reason" => reason}` on the envelope after `upgrade_envelope` when reason is non-nil. `decided_entry/2` adds `decision: item["decision"]`, `decided_at: item["decided_at"]` to the returned map.

RPC: in `queue_api.ex`'s `reject_item` add `argument :reason, :string, allow_nil?: true, default: nil` and pass `Map.get(input.arguments, :reason)` through; also extend `list_decided_items` unchanged (entries are unconstrained maps — the new keys flow through). Frontend: `rejectQueueItem(runId, revision, generation, reason?: string | null)` in `client.ts` (pass `reason: reason ?? null`), store `reject(runId, revision, reason?: string)`, test in `queue.test.ts` asserting the api receives the reason.

- [ ] **Step 4: Run** `mix test`, `just codegen && git -C . diff --exit-code frontend/src/lib/api/`, `cd frontend && bun run check && bun run test` — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: optional rejection reasons through queue, RPC, and store"`

---

### Task B7: Approve RPC return + apply_conflict mapping + codegen sweep

**Files:**
- Modify: `backend/lib/valea/api/queue_api.ex` (`approve_item` return fields; error mapping)
- Modify: `frontend/src/lib/api/client.ts` (`approveQueueItemFields`), `frontend/src/lib/components/queue/DraftReview.svelte`'s `describeError` (add `apply_conflict`)
- Test: `backend/test/valea_web/queue_rpc_test.exs`

**Interfaces:**
- Produces: `approve_item` returns `%{draft_path: nil | String.t(), applied_path: nil | String.t()}` (both fields typed nilable strings); `Valea.Queue.approve` errors map `:apply_conflict → "apply_conflict"` (flows through the existing `to_string(reason)` fallback — verify with a test rather than new code).

- [ ] **Step 1: Failing RPC test** — in `queue_rpc_test.exs`, drive `approve_item` over a pending memory envelope (reuse B4's `pending_memory!` fixture inlined) and assert `%{"appliedPath" => target, "draftPath" => nil}` in the RPC result; plus a hash-mismatch envelope asserting the error string `"apply_conflict"`.

- [ ] **Step 2: Run** — FAIL (constraints don't include applied_path).

- [ ] **Step 3: Implement.** `approve_item`'s returns:

```elixir
        constraints fields: [
          draft_path: [type: :string, allow_nil?: true],
          applied_path: [type: :string, allow_nil?: true]
        ]
```

and the action body passes both keys through from `Valea.Queue.approve/2`'s map. Run `just codegen`; update `client.ts`: `approveQueueItemFields = ['draftPath', 'appliedPath']` and the wrapper's return type. `DraftReview.svelte` `describeError`: `apply_conflict` → "The page changed since this was proposed. The item is back in your queue — reject it or re-run the workflow." (also used by B12's card).

- [ ] **Step 4: Run** backend tests + `just codegen` diff gate + `bun run check` + `bun run test` — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat: approve RPC returns applied_path; apply_conflict surfaced to the UI"`

---

### Task B8: Decisions digest + generated-input runner variant + distill RPC/cockpit field

**Files:**
- Create: `backend/lib/valea/workflows/distill.ex`
- Modify: `backend/lib/valea/workflows/runner.ex` (`run_generated/3`, `start_run` input handling)
- Modify: `backend/lib/valea/workflows.ex` (`distill_path/0`, mirroring `triage_path/0`)
- Modify: `backend/lib/valea/cockpit.ex` + `backend/lib/valea/api/cockpit.ex` (`distill_workflow_path` field), `backend/lib/valea/api/queue_api.ex` or workflows API module (new `distill_decisions` action — put it beside `run_workflow`'s home; locate with `grep -rn "run_workflow" backend/lib/valea/api/`)
- Modify: `frontend/src/lib/api/client.ts` (`distillDecisions(generation)`, cockpit field), `frontend/src/lib/today/cockpit.ts` (`distillWorkflowPath`)
- Test: `backend/test/valea/workflows/distill_test.exs`, extend runner + rpc + cockpit tests

**Interfaces:**
- Produces:
  - `Valea.Workflows.Distill.digest(workspace) :: {count :: non_neg_integer(), markdown :: String.t()}` — decided envelopes with `decided_at` within 30 days, newest first; each rendered as `### <title>` + bullet lines `kind`, `workflow`, `decided approved|rejected on <YYYY-MM-DD>`, and `reason: <...>` when present. Header line: `# Recent decisions (last 30 days)`.
  - `Valea.Workflows.Runner.run_generated(workflow_path, input_name, input_bytes)` — same contract as `run/2` but the input is written server-side to `queue/staging/<run_id>/<input_name>` before session start; `input` in sidecar/envelope is that staging-relative path; `input_hash` = sha256(bytes).
  - RPC `distill_decisions(generation)` → `{run_id, session_id}`; error `"no_recent_decisions"` when count == 0; error `"workflow_not_found"` when no distill contract is installed/enabled.
  - `Valea.Workflows.distill_path/0 :: String.t() | nil` — first enabled workflow whose basename is `"Distill Decisions.md"`.
  - Cockpit `today` gains `"distill_workflow_path"` (nilable string, camelCases to `distillWorkflowPath`).

- [ ] **Step 1: Failing digest tests**

```elixir
# backend/test/valea/workflows/distill_test.exs
defmodule Valea.Workflows.DistillTest do
  use ExUnit.Case, async: false
  alias Valea.Workflows.Distill
  alias Valea.Workspace.Manager

  setup do
    # standard tmp workspace setup as in B1
    ...
    %{workspace: ws.path}
  end

  defp decided!(ws, dir, run_id, decided_at, extra \\ %{}) do
    item =
      Map.merge(
        %{
          "schema" => "queue_item/v2", "run_id" => run_id,
          "workflow" => "mounts/primary/Workflows/New Inquiry Triage.md",
          "risk_level" => "medium",
          "created_at" => "2026-07-01T00:00:00Z",
          "decided_at" => decided_at,
          "payload" => %{"title" => "T-" <> run_id, "summary" => "s", "kind" => "email_draft",
            "sources" => [], "proposed_action" => %{"type" => "create_email_draft",
              "to" => "a@b.c", "subject" => "s", "body_markdown" => "b"}}
        },
        extra
      )
    d = Path.join(ws, "queue/" <> dir)
    File.mkdir_p!(d)
    File.write!(Path.join(d, run_id <> ".json"), Jason.encode!(item))
  end

  test "window, reasons, ordering, exclusions", %{workspace: ws} do
    now = DateTime.utc_now()
    recent = now |> DateTime.add(-2, :day) |> DateTime.to_iso8601()
    old = now |> DateTime.add(-40, :day) |> DateTime.to_iso8601()

    decided!(ws, "approved", "d1", recent)
    decided!(ws, "rejected", "d2", recent, %{"decision" => %{"reason" => "too pushy"}})
    decided!(ws, "approved", "d3", old)
    decided!(ws, "approved", "d4-nostamp", nil)

    {count, md} = Distill.digest(ws)
    assert count == 2
    assert md =~ "# Recent decisions (last 30 days)"
    assert md =~ "T-d1"
    assert md =~ "reason: too pushy"
    refute md =~ "T-d3"
    refute md =~ "d4-nostamp"
  end

  test "empty window", %{workspace: ws} do
    assert {0, md} = Distill.digest(ws)
    assert md =~ "# Recent decisions"
  end
end
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement `Distill`** — read `queue/approved/*.json` + `queue/rejected/*.json` directly (decided source of truth; do NOT round-trip through `list_decided` which needs the Manager):

```elixir
defmodule Valea.Workflows.Distill do
  @moduledoc """
  Compiles the reflection workflow's input: a self-contained markdown
  digest of recently decided queue items, so the agent reads one
  server-owned document and the read boundary never widens to queue/.
  """

  @window_days 30

  @spec digest(String.t()) :: {non_neg_integer(), String.t()}
  def digest(workspace) do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_days, :day)

    items =
      for dir <- ["approved", "rejected"],
          path <- Path.wildcard(Path.join([workspace, "queue", dir, "*.json"])),
          {:ok, bytes} <- [File.read(path)],
          {:ok, %{} = item} <- [Jason.decode(bytes)],
          decided_at = parse_ts(item["decided_at"]),
          decided_at != nil,
          DateTime.compare(decided_at, cutoff) == :gt do
        {decided_at, dir, item}
      end
      |> Enum.sort_by(fn {ts, _, _} -> ts end, {:desc, DateTime})

    md =
      [
        "# Recent decisions (last #{@window_days} days)",
        "",
        "Each entry is one item the user decided. Rejections with a reason",
        "are the strongest teaching signal.",
        ""
        | Enum.flat_map(items, &entry/1)
      ]
      |> Enum.join("\n")

    {length(items), md}
  end

  defp entry({ts, dir, item}) do
    decided = if dir == "approved", do: "approved", else: "rejected"
    reason = get_in(item, ["decision", "reason"])

    [
      "### #{sanitize(item["payload"]["title"] || item["run_id"])}",
      "- kind: #{sanitize(item["payload"]["kind"])}",
      "- workflow: #{sanitize(item["workflow"])}",
      "- decided: #{decided} on #{ts |> DateTime.to_date() |> Date.to_iso8601()}"
    ] ++
      if(reason, do: ["- reason: #{sanitize(reason)}"], else: []) ++ [""]
  end

  # Titles/reasons are user/agent text landing in an agent prompt file —
  # collapse control chars and neutralize line-leading structure the same
  # way MOUNTS.md generation does.
  defp sanitize(nil), do: ""
  defp sanitize(s) when is_binary(s) do
    s
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.trim()
  end
  defp sanitize(other), do: inspect(other)

  defp parse_ts(nil), do: nil
  defp parse_ts(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_ts(_), do: nil
end
```

- [ ] **Step 4: Runner `run_generated/3`.** Failing test first (runner_test): drive `run_generated` with the fake harness and assert (a) `queue/staging/<run_id>/input-decisions.md` exists with the digest bytes before the session prompt fires, (b) sidecar `input` == `queue/staging/<run_id>/input-decisions.md`, (c) envelope/audit carry it. Implementation: refactor `run/2`'s tail into `start_run(workspace, wf, workflow_path, workflow_bytes, input)` where `input` is `{:file, input_path, input_bytes}` or `{:generated, name, bytes}`; for `:generated`, after `mkdir_p` of staging write `Path.join(staging_dir, name)` with the bytes and set `input_path = Path.join(["queue", "staging", run_id, name])`. Everything downstream (sidecar, prompt, audit) uses `input_path`/`bytes` uniformly. Public:

```elixir
  @spec run_generated(String.t(), String.t(), String.t()) ::
          {:ok, %{run_id: String.t(), session_id: String.t()}} | {:error, term()}
  def run_generated(workflow_path, input_name, input_bytes) do
    with {:ok, %{path: workspace}} <- current_workspace(),
         {:ok, wf} <- Workflows.get(workflow_path),
         :ok <- ensure_enabled(wf),
         {:ok, workflow_bytes} <- read_workflow(workspace, workflow_path) do
      start_run(workspace, wf, workflow_path, workflow_bytes, {:generated, input_name, input_bytes})
    end
  end
```

(The B3 staging read grant already lets the session read the digest.)

- [ ] **Step 5: `distill_path/0` + RPC + cockpit.** `Valea.Workflows.distill_path/0` mirrors `triage_path/0` with basename `"Distill Decisions.md"` (read `triage_path`'s implementation and copy its shape exactly). RPC action `distill_decisions` (same module as `run_workflow`): args `generation :integer`; body: check generation → `Workflows.distill_path()` (nil → error `"workflow_not_found"`) → `Distill.digest(workspace)` (count 0 → error `"no_recent_decisions"`) → `Runner.run_generated(path, "input-decisions.md", md)` → `%{run_id, session_id}`. Cockpit: `today/0` adds `"distill_workflow_path" => distill_workflow_path()` (same guard pattern as `triage_workflow_path`); `api/cockpit.ex` constraints add `distill_workflow_path: [type: :string, allow_nil?: true]`. Frontend: `client.ts` adds `distillDecisions(generation)` wrapper + cockpit field in `cockpitTodayFields`; `cockpit.ts` type + `normalizeCockpitToday` pass-through. Tests: rpc test (happy via fake harness or assert error strings for no-workflow/no-decisions), cockpit rpc field test.

- [ ] **Step 6: Run** full backend suite + codegen gate + frontend check/test — PASS.

- [ ] **Step 7: Commit** — `git commit -m "feat: decisions digest, generated-input runs, distill RPC + cockpit field"`

---

### Task B9: Starter-mount content — Distill contract, Decisions seed, AGENTS.md contracts

**Files:**
- Create: `backend/priv/workspace_template/mounts/starter/Workflows/Distill Decisions.md`
- Create: `backend/priv/workspace_template/mounts/starter/Decisions/2026.md` (replaces the bare `.gitkeep`; keep the `.gitkeep` file — harmless)
- Modify: `backend/priv/workspace_template/AGENTS.md` (root — add memory-update contract section)
- Modify: `backend/priv/workspace_template/mounts/starter/AGENTS.md` (Decisions convention)
- Modify: `backend/priv/workspace_template/mounts/starter/Workflows/New Inquiry Triage.md` (Outputs note)
- Test: extend `backend/test/valea/workspace/scaffold_test.exs` (or the existing scaffold/template test file — locate with `grep -rln "workspace_template" backend/test/`)

**Interfaces:** none consumed beyond file conventions; produces the contract file `Workflows/Distill Decisions.md` whose basename B8's `distill_path/0` matches.

- [ ] **Step 1: Failing test** — scaffold a workspace, assert: `Workflows.list/0` includes a workflow named "Distill Decisions" with `enabled: true` and `risk_level: "medium"`; `mounts/<slug>/Decisions/2026.md` exists; root `AGENTS.md` contains `memory_update/v1`; mount `AGENTS.md` contains `Decisions/`.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Write the content.**

`Workflows/Distill Decisions.md`:

```markdown
---
name: Distill Decisions
enabled: true
trigger: { type: manual, source: decisions.digest }
sources:
  - { id: decisions_digest, type: file, required: true }
  - { id: decision_log, type: icm, path: "Decisions/2026.md" }
risk_level: medium
approval:
  required: true
  reason: Memory updates must be reviewed before they change business memory.
  actions: [apply_page_content]
audit: { log_sources: true, log_inputs: true, log_outputs: true, log_agent: true }
---

# Distill Decisions

## Inputs

| id | what it is |
| --- | --- |
| decisions_digest | A digest of recently decided queue items, compiled by the app. |
| decision_log | The mount's chronological decision log. |

## Process

1. Read the digest. Look for durable decisions: a rejection with a reason,
   a repeated pattern of approvals, anything that changes how future work
   should be prepared.
2. Read the decision log and any page a candidate decision touches. Do
   not re-propose anything the log or the pages already record.
3. For each durable decision, propose a memory update (see the
   memory-update contract in the root AGENTS.md): append an entry to the
   decision log page, and — when a decision contradicts an existing page
   (pricing, policies, tone) — propose the correction to that page too.

## Outputs

Zero or more memory-update pairs under the staging `proposals/` folder.
No email drafts. If the digest holds nothing durable, write nothing and
say so.
```

`Decisions/2026.md`:

```markdown
# Decisions — 2026

A chronological log of business decisions worth remembering. One entry
per decision: date, the decision, why, and where it came from.

## 2026-07-09 — Coaching stays advisory, never medical

Why: a prospect asked for anxiety treatment; that is out of scope.
From: Policies/No Medical Advice.md
```

Root `AGENTS.md` — append after the existing "## The proposal contract" section:

```markdown
## The memory-update contract

You never edit mount pages directly during a workflow run. To propose a
change to business memory, write a PAIR of files under the run's staging
`proposals/` folder:

- `<name>.md` — the complete new content of the target page.
- `<name>.json` — a manifest:

    {
      "schema": "memory_update/v1",
      "target_path": "mounts/<mount>/Pricing/Current Pricing.md",
      "base_sha256": "<sha256 hex of the target page exactly as you read it, or null to create a new page>",
      "reason": "one line: why this change",
      "sources": ["paths you read"]
    }

Target paths use the same form you read them by: workspace-relative for
mounts under `mounts/`, absolute for mounts listed with a real location
in MOUNTS.md. The app verifies the target and shows the user a diff;
nothing changes without their approval.
```

Mount `AGENTS.md` — add under "## The map"'s `Decisions/` bullet (or extend it):

```markdown
- `Decisions/` — the decision log: dated entries recording business
  decisions, why they were made, and their source. When work you prepare
  is approved or rejected for a reason, that reason usually belongs here.
```

Triage contract — append to its `## Outputs` section:

```markdown
If the inquiry exposed stale or missing business memory (pricing that no
longer matches, a policy the pages don't cover), you may also propose
memory updates per the memory-update contract in the root AGENTS.md.
```

- [ ] **Step 4: Run** the scaffold test + full `mix test` (template determinism tests may pin file lists — update fixtures they assert) — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(template): Distill Decisions contract, decision-log seed, memory-update contract in AGENTS.md"`

---

### Task B10: Permission-item risk-tier enrichment

**Files:**
- Modify: `backend/lib/valea/agents/session_server.ex` (`handle_info({:runtime_output, ...})` items reduce, new `enrich_item/2`)
- Test: extend `backend/test/valea/agents/session_server_test.exs`

**Interfaces:**
- Consumes: B1 `RiskTier.classify/2`; permission items shaped `%{"type" => "permission", "rawInput" => %{"file_path" => ...}}` (paths also under `"path"`, `"filePath"`, `"notebook_path"`).
- Produces: ask-path permission items carry `"risk_tier" => "high" | "medium"` when the target attributes to a mount; absent otherwise. The enriched item is what lands in the timeline AND the channel `event` push (both flow from `append_item/2`).

- [ ] **Step 1: Failing test** — using `agent_case.ex`'s fake-adapter scenario helpers (mirror an existing permission-request test): a `session/request_permission` for a Write with `rawInput.file_path` = `<ws>/mounts/primary/Workflows/New Inquiry Triage.md` in a `"chat"` session → the broadcast/timeline item has `"risk_tier" => "high"`; a knowledge page → `"medium"`; a `sources/` path → no `"risk_tier"` key.

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement.** In `handle_info({:runtime_output, data}, state)` change the items reduce:

```elixir
    state = Enum.reduce(items, state, &append_item(&2, enrich_item(&1, state)))
```

and add:

```elixir
  # A permission ask is the human's decision point — stamp the same
  # server-derived risk tier the queue uses, so the dialog can say
  # plainly when an approval changes future agent behavior. Display
  # metadata only; policy decisions never read it.
  defp enrich_item(%{"type" => "permission", "rawInput" => raw} = item, state)
       when is_map(raw) do
    path = raw["file_path"] || raw["path"] || raw["filePath"] || raw["notebook_path"]

    case is_binary(path) && Valea.Agents.RiskTier.classify(state.workspace, path) do
      tier when tier in ["high", "medium"] -> Map.put(item, "risk_tier", tier)
      _ -> item
    end
  end

  defp enrich_item(item, _state), do: item
```

- [ ] **Step 4: Run** session_server tests + full backend — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(backend): risk-tier enrichment on ask-path permission items"`

---

### Task B11: FE — line-diff util + PermissionCard diff & risk banner

**Files:**
- Create: `frontend/src/lib/diff/line-diff.ts`, `frontend/src/lib/diff/line-diff.test.ts`
- Create: `frontend/src/lib/components/agent/permission-view.ts`, `permission-view.test.ts`
- Modify: `frontend/src/lib/components/agent/PermissionCard.svelte`

**Interfaces:**
- Produces:
  - `lineDiff(oldText: string, newText: string, cap = 400): { rows: DiffRow[]; truncated: boolean }` with `DiffRow = { type: 'ctx' | 'add' | 'del'; text: string }` — LCS over lines, shared by B12's queue card.
  - `derivePermissionView(item: Record<string, unknown>): PermissionView` where `PermissionView = { title: string; command?: string; diff?: { path: string; rows: DiffRow[]; truncated: boolean; mode: 'edit' | 'write' }; tier?: 'high' | 'medium' }` — Edit tools (`rawInput.old_string`/`new_string`) diff those spans; Write tools (`rawInput.content`) render all-add rows; anything else has no diff.

- [ ] **Step 1: Failing tests**

```ts
// frontend/src/lib/diff/line-diff.test.ts
import { describe, expect, it } from 'vitest';
import { lineDiff } from './line-diff';

describe('lineDiff', () => {
  it('marks unchanged, added, removed lines', () => {
    const { rows } = lineDiff('a\nb\nc', 'a\nx\nc');
    expect(rows).toEqual([
      { type: 'ctx', text: 'a' },
      { type: 'del', text: 'b' },
      { type: 'add', text: 'x' },
      { type: 'ctx', text: 'c' }
    ]);
  });

  it('handles pure insert and pure delete', () => {
    expect(lineDiff('', 'a\nb').rows).toEqual([
      { type: 'add', text: 'a' },
      { type: 'add', text: 'b' }
    ]);
    expect(lineDiff('a', '').rows).toEqual([{ type: 'del', text: 'a' }]);
  });

  it('caps output and flags truncation', () => {
    const big = Array.from({ length: 500 }, (_, i) => `l${i}`).join('\n');
    const out = lineDiff('', big, 100);
    expect(out.rows.length).toBe(100);
    expect(out.truncated).toBe(true);
  });
});
```

```ts
// frontend/src/lib/components/agent/permission-view.test.ts
import { describe, expect, it } from 'vitest';
import { derivePermissionView } from './permission-view';

describe('derivePermissionView', () => {
  it('builds an edit diff from old_string/new_string', () => {
    const v = derivePermissionView({
      title: 'Edit file',
      rawInput: { file_path: '/w/mounts/m/Pricing.md', old_string: 'a\nb', new_string: 'a\nc' },
      risk_tier: 'medium'
    });
    expect(v.diff?.mode).toBe('edit');
    expect(v.diff?.path).toBe('/w/mounts/m/Pricing.md');
    expect(v.tier).toBe('medium');
    expect(v.diff?.rows.some((r) => r.type === 'del' && r.text === 'b')).toBe(true);
  });

  it('builds an all-add preview for Write content', () => {
    const v = derivePermissionView({
      title: 'Write file',
      rawInput: { file_path: '/w/mounts/m/AGENTS.md', content: 'x\ny' },
      risk_tier: 'high'
    });
    expect(v.diff?.mode).toBe('write');
    expect(v.diff?.rows.every((r) => r.type === 'add')).toBe(true);
    expect(v.tier).toBe('high');
  });

  it('falls back to command-only for non-file tools', () => {
    const v = derivePermissionView({ title: 'Run command', command: 'ls', rawInput: { command: 'ls' } });
    expect(v.diff).toBeUndefined();
    expect(v.command).toBe('ls');
  });
});
```

- [ ] **Step 2: Run** `cd frontend && bun run test` — FAIL.

- [ ] **Step 3: Implement.**

```ts
// frontend/src/lib/diff/line-diff.ts
export type DiffRow = { type: 'ctx' | 'add' | 'del'; text: string };

/** LCS-based line diff. Small inputs only (editor pages, tool params). */
export function lineDiff(
  oldText: string,
  newText: string,
  cap = 400
): { rows: DiffRow[]; truncated: boolean } {
  const a = oldText === '' ? [] : oldText.split('\n');
  const b = newText === '' ? [] : newText.split('\n');
  const m = a.length;
  const n = b.length;
  // DP table of LCS lengths
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array<number>(n + 1).fill(0));
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const rows: DiffRow[] = [];
  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (a[i] === b[j]) {
      rows.push({ type: 'ctx', text: a[i] });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      rows.push({ type: 'del', text: a[i] });
      i++;
    } else {
      rows.push({ type: 'add', text: b[j] });
      j++;
    }
  }
  while (i < m) rows.push({ type: 'del', text: a[i++] });
  while (j < n) rows.push({ type: 'add', text: b[j++] });

  if (rows.length > cap) return { rows: rows.slice(0, cap), truncated: true };
  return { rows, truncated: false };
}
```

```ts
// frontend/src/lib/components/agent/permission-view.ts
import { lineDiff, type DiffRow } from '$lib/diff/line-diff';

export type PermissionView = {
  title: string;
  command?: string;
  diff?: { path: string; rows: DiffRow[]; truncated: boolean; mode: 'edit' | 'write' };
  tier?: 'high' | 'medium';
};

const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);

export function derivePermissionView(item: Record<string, unknown>): PermissionView {
  const raw = (item.rawInput ?? {}) as Record<string, unknown>;
  const view: PermissionView = { title: str(item.title) ?? 'Permission request' };
  const command = str(item.command) ?? str(raw.command);
  if (command) view.command = command;

  const tier = str(item.risk_tier);
  if (tier === 'high' || tier === 'medium') view.tier = tier;

  const path = str(raw.file_path) ?? str(raw.path) ?? str(raw.filePath);
  const oldStr = str(raw.old_string);
  const newStr = str(raw.new_string);
  const content = str(raw.content);

  if (path && oldStr !== undefined && newStr !== undefined) {
    view.diff = { path, ...lineDiff(oldStr, newStr), mode: 'edit' };
  } else if (path && content !== undefined) {
    view.diff = { path, ...lineDiff('', content), mode: 'write' };
  }
  return view;
}

export function tierCopy(tier: 'high' | 'medium'): string {
  return tier === 'high' ? 'Changes how your assistant behaves' : 'Edits your business memory';
}
```

`PermissionCard.svelte`: derive `view = derivePermissionView(item)` and render, above the option buttons: the tier banner when `view.tier` (`high`: `bg-warn-tint text-warn-ink border border-warn-border`; `medium`: `bg-suggest-tint text-suggest-ink border border-suggest-border`; text from `tierCopy`), then the diff block when `view.diff` (mono, `whitespace-pre-wrap`, `del` rows `bg-warn-tint` with leading `- `, `add` rows `bg-act-tint` with leading `+ `, `ctx` plain with two-space lead; path shown above; "diff truncated" note when flagged; `mode === 'write'` labeled "New file content"). Keep existing title/command/options rendering; NEVER `{@html}`.

- [ ] **Step 4: Run** `bun run test && bun run check` — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(frontend): permission dialog renders diffs and risk tiers"`

---

### Task B12: FE — MemoryUpdateReview card, queue routing, reject reasons in both cards

**Files:**
- Create: `frontend/src/lib/components/queue/MemoryUpdateReview.svelte`, `memory-review.ts`, `memory-review.test.ts`
- Modify: `frontend/src/routes/queue/[run_id]/+page.svelte` (route by `payload.kind`), `frontend/src/lib/components/queue/DraftReview.svelte` (reason input on reject), `frontend/src/lib/components/queue/ApprovalCard.svelte` (kind badge/link for memory items), decided view in the same route (reason + applied target display)
- Test: `memory-review.test.ts`, extend `frontend/src/lib/stores/queue.test.ts` if not done in B6

**Interfaces:**
- Consumes: B6 `queueStore.reject(runId, revision, reason?)`; B7 `approve` result `{draftPath, appliedPath}` + `apply_conflict` error copy; B11 `lineDiff`; `api.icmPage(path)` (`{content, hash}` — hash is sha256 hex of full content).
- Produces: `buildMemoryReview(item, page | null): MemoryReview` in `memory-review.ts`:

```ts
export type MemoryReview = {
  targetPath: string;
  mountLabel: string;            // first path segment after mounts/, or the absolute root dir name
  isCreate: boolean;
  highRisk: boolean;             // item.risk_level === 'high'
  staleBase: boolean;            // page && page.hash !== base_sha256 (edit mode only)
  rows: DiffRow[];               // create → all-add; edit → lineDiff(page.content, content_markdown)
  truncated: boolean;
  reason: string;                // payload.summary
  sources: string[];
};
```

- [ ] **Step 1: Failing tests** for `buildMemoryReview` (create mode all-add; edit mode diff rows; `staleBase` true when hashes differ; `highRisk`; mount label for `mounts/primary/...` → `primary` and for `/abs/path/company-icm/...` → `company-icm` — derive by matching against the envelope's target only: for absolute targets use the basename of the first existing ancestor? No — keep it presentation-only: absolute targets show the full directory path as the label, embedded show the mount name; write the tests to those two rules).

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement** `memory-review.ts` (pure), then the component:

- Load: on mount, if `!isCreate && targetPath.endsWith('.md')` fetch `api.icmPage(targetPath)`; failures → `page = null` → render the proposed content as all-add rows with a quiet note "Could not read the current page — showing the proposed content."
- Render: kind badge "Memory update", target path (link to `/knowledge/<encodePath(targetPath)>` when `.md`), reason, `QueueSourceChips`, risk banner when `highRisk` (`tierCopy('high')` styling from B11), stale-base warning banner ("This page changed since the update was proposed — approving will be refused; reject it or re-run the workflow.") when `staleBase`, diff rows (same renderer styling as B11 — extract a small shared `DiffBlock.svelte` under `frontend/src/lib/components/diff/` used by both cards), approve/reject buttons with the same FSM as `DraftReview` (`idle|busy|approved|rejected|changed|gone|conflict|error`; `apply_conflict` → `conflict` state with B7's copy and an onReload call).
- Approved state: "Applied to <targetPath>" linking into Knowledge.
- Reject reason: single-line `<Input>` (placeholder: "Why? Optional — this teaches your assistant.") shown next to the reject button in BOTH `MemoryUpdateReview` and `DraftReview`; passes through `queueStore.reject(runId, revision, reason || undefined)`.
- Route `queue/[run_id]/+page.svelte`: `item.payload.kind === 'memory_update'` → `MemoryUpdateReview`, else `DraftReview`. Decided branch: when the decided item has `decision?.reason` render `Rejected — “<reason>”`; memory-kind decided items skip the mailbox-op rows entirely and show "Applied to <path>" / "Rejected" instead (extend `queue-ops.ts`'s `normalizeDecidedItem` to carry `decision` and `kind` — it already carries `kind`).
- `ApprovalCard.svelte`: `payload.kind === 'memory_update'` → badge text "Memory update suggested", link text "Review the change →" (same `/queue/{run_id}` target).

- [ ] **Step 4: Run** `bun run test && bun run check` — PASS.

- [ ] **Step 5: Commit** — `git commit -m "feat(frontend): memory-update review card, reject reasons, decided reasons"`

---

### Task B13: FE — Distill action on Today and Workflows

**Files:**
- Modify: `frontend/src/routes/+page.svelte` (Today: distill action), `frontend/src/lib/today/cockpit.ts` (if not finished in B8), the Workflows registry page (locate: `frontend/src/routes/workflows/+page.svelte` or grep `workflowsStore` usage) — add the same action on the Distill Decisions card
- Create: `frontend/src/lib/today/distill.ts`, `distill.test.ts`

**Interfaces:**
- Consumes: B8 `api.distillDecisions(generation)`, `today.distillWorkflowPath`.
- Produces: `distillButtonState(today, phase): { visible: boolean; label: string; disabled: boolean; note?: string }` pure helper (`phase: 'idle' | 'running' | 'empty' | 'error'`), tested.

- [ ] **Step 1: Failing tests** for `distillButtonState`: hidden when `distillWorkflowPath` null; idle → label "Distill recent decisions"; running → disabled, label "Distilling…"; empty → note "No decisions in the last 30 days yet."; error → note carries the message.

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** the helper + wire: Today renders a quiet secondary button under the "Prepared for you" section when visible; click → `api.distillDecisions(workspaceStore.generation ?? 0)`; success → running state with a link `/chat?session={sessionId}` ("Watching the run →") — the resulting queue items arrive via the existing `queue_changed` refetch; error `no_recent_decisions` → `empty` phase note. Workflows page: on the card whose `path` equals `distillWorkflowPath` (fetch cockpit data or match by workflow name "Distill Decisions"), the same action — reuse the helper.

- [ ] **Step 4: Run** `bun run test && bun run check` — PASS. **Step 5: Commit** — `git commit -m "feat(frontend): distill recent decisions action on Today and Workflows"`

---

### Task B14: Docs + acceptance sweep

**Files:**
- Modify: `docs/ARCHITECTURE.md` (queue kinds + apply executor, proposal pairs, write_roots/staging read grant, risk tiers, digest/distill, rejection reasons — claim-check every sentence against the code), `docs/VISION.md` (roadmap: add item 8 "Methodology depth (Spec B)" marked shipped-pending-merge with spec pointer)
- Test: none new — this task runs the full gates.

- [ ] **Step 1:** Write the doc updates (concise, matching the existing style — ARCHITECTURE documents as-built truth, not aspiration).
- [ ] **Step 2:** Run everything: `cd backend && mix format --check-formatted && mix test`, `just codegen` + `git diff --exit-code frontend/src/lib/api/`, `cd frontend && bun run check && bun run test`. Expected: all green (backend ≥ existing 900 + new, frontend ≥ 430 + new, check 0 errors).
- [ ] **Step 3:** Manual claim-check pass: every ARCHITECTURE claim added names a module/function that exists (grep each).
- [ ] **Step 4: Commit** — `git commit -m "docs: methodology-depth as-built architecture + roadmap"`

---

## Plan self-review notes (retained for the executor)

- Spec §1 (chat dialog) → B10 + B11. §2 (pairs) → B3. §3 (finalize) → B3. §4 (apply + recovery + decided_at) → B4 + B5. §5 (reasons) → B6 + B12. §6 (digest/reflection) → B8 + B9. §7 (decision pages) → B9. §8 (UI) → B11 + B12 + B13. Error table → B3/B4/B5/B8 tests. Testing section → mapped per task. Trust framing copy → B11/B12/B13.
- Type consistency: `approve` return `%{draft_path, applied_path}` defined in B4, consumed in B7/B12. `DiffRow` defined in B11, consumed in B12. `check_target/2` defined in B3, consumed in B4. `default_read_roots/1` defined in B2, consumed in B3. `decided_at`/`decision` written in B4/B6, read in B8/B12.
- The B4 email-return-shape change (`draft_path` map gains `applied_path: nil`) is intentionally made in B4 so B7's RPC change is purely additive; B4's step 3 note tells the implementer to keep `queue_api.ex` compiling (it reads `:draft_path`, still present).
