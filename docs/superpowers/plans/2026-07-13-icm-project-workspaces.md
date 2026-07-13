# Workspace Profiles, Mounted ICM Projects & ICM-Scoped Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reverse the workspace↔ICM relationship so every agent session runs *inside exactly one primary ICM* (the ICM's physical root is the process + ACP cwd), the Valea workspace becomes a hidden, private operational profile that is never an agent project, ICMs are mounted purely by reference and carry stable identity, and related context enters a session only when the primary ICM explicitly declares it.

**Architecture:** A new `Valea.Agents.SessionScope` resolver becomes the single point that turns `(kind, mount_key, generation)` into a launch object `%{workspace, primary_icm, related_icms, cwd, read_paths, write_paths, write_roots, managed_settings, managed_context}`. `SessionServer`/`ProcessRuntime`/`Acp.Connection` stop conflating the workspace root with the cwd: cwd/ACP-cwd become the primary ICM's resolved physical root, while transcripts/queue/audit/generation stay keyed to the workspace. Managed harness settings move out of `<icm>/.claude/settings.json` into a Valea-owned per-session `runtime/sessions/<id>/settings.json` passed through the adapter. `Valea.Mounts` collapses to a config-backed, external-only registry keyed by a stable ICM `id`; embedded `mounts/` discovery and generated `MOUNTS.md` are deleted. Persisted records (queue targets, audit, workflow registry) move from raw physical paths to stable `{icm_id, relative_path}` / workspace-relative locators resolved at the I/O boundary. Workspaces move into `~/.valea/workspaces/<slug>-<short-id>/` and are selected by internal id, never a user-entered path. The frontend replaces the sidebar file tree with ICM-project groups (each showing ≤5 recent sessions), relocates the tree into Knowledge, and replaces create/open/adopt onboarding with Start fresh / Use existing ICM.

**Tech Stack:** Elixir 1.15+/OTP, Phoenix 1.8, Ash 3 + AshSqlite + ash_typescript, yaml_elixir, file_system, erlexec; SvelteKit static SPA + Svelte 5 runes, Tailwind v4, Bun/Vitest; Tauri desktop shell. No new backend or frontend dependencies.

**Spec:** `docs/superpowers/specs/2026-07-13-icm-project-workspaces-design.md` — binding for every task; read it for any ambiguity. It supersedes `2026-07-12-icm-mounts-design.md` (Plan A) and `2026-07-12-icm-by-reference-design.md` (Plan A2) wherever they define embedded `mounts/`, workspace-root routing, `MOUNTS.md`, global mount composition, or path-as-identity.

**Revision 2026-07-13 (B/C interaction review):** after Specs B (methodology depth) and C (knowledge depth) merged to main, this plan was reviewed for how the redesign disturbs their shipped code. The review added/expanded tasks for: the run-sidecar ICM stamp + `RiskTier`/finalize on ICM identity (Tasks 7.2, 7.3, **7.5**); re-keying `backlinks.ex`/`link_rewrite.ex` and scoping search/backlinks/rename-rewrite to **primary + related** ICMs (Tasks 4.2, **5.6**); the image upload/serve endpoint (**Task 4.4**); the frontend link/image path-vocabulary rewrite (**Task 9.6**); a portable **ICM template** seeded on create + the Valea proposal contract injected via the session bootstrap `context.md` (Tasks **3.5**, 1.2 — the "inject + seed" resolution of where B's teach-loop content lives once the workspace stops being an agent project); and the C7 managed-settings **fallback** the Phase-1 spike must decide (Task 1.1), since the installed `claude-agent-acp` adapter has no verified way to load an external settings file. Three decisions locked in this review: **(a)** Valea's queue vocabulary is injected at launch + a clean starter is seeded into new ICMs (never baked into the portable ICM's own files); **(b)** editor-time search/backlinks/rename-rewrite are bounded to the primary ICM + its declared related ICMs; **(c)** the Phase-1 spike settles the managed-settings mechanism before `SessionSettings` is built on it. **Follow-up decision (harness seam):** enforcement is `PermissionPolicy` on the ACP `session/request_permission` callback (harness-neutral, authoritative); the settings file is only an optional per-harness pre-filter, wrapped behind a new `Valea.Harness` behaviour (`Valea.Harnesses.ClaudeCode` is its first implementer). Claude Code ships **callback-only** — no settings file is written into or near the ICM (the user's own `.claude/` config lives there; the ICM must stay usable by a bare harness); the session `context.md` (related-ICM map + injected contract) is still materialized under the hidden workspace. Tasks 1.1–1.3, C6, C7, C10 reshaped accordingly. **Spike-review revision:** the Phase-1 review found pure callback-only can't guarantee writes/denied-reads reach the callback with no settings at all (the CLI's own defaults decide first), and surfaced the SDK's in-memory `managedSettings` (`--managed-settings <json>`, no file). Enforcement is therefore an in-memory `managedSettings` posture (rendered by `SessionSettings.content/1`) + the ACP callback as authoritative answer — still zero ICM writes. `launch/2` returns `managed_settings` (JSON), not `settings_path`.

## How to execute this plan

The spec defines twelve phases (spec §"Implementation sequence"). This plan keeps that order. **Each phase is an independently testable milestone** and is designed to be executed — and reviewed — as its own session: at the end of every phase the suite is green and the app runs. Phases are strictly ordered by dependency (a later phase consumes types and modules a earlier one produces); do not reorder. Within a phase, tasks are bite-sized (2–5 minute steps) and each ends with a commit.

Because there are no production users (spec §"Clean-cut implementation policy"), this is a **replacement, not a migration**: delete legacy code and fixtures rather than adding compatibility branches, and recreate development workspaces from the new onboarding. The deletions are deliberately deferred to **Phase 11** so earlier phases can build the new spine alongside the old one and keep the suite green; do not delete a legacy module before Phase 11 unless a task explicitly says so.

---

## Global Constraints

Binding on every task. The spec is the source of truth when in doubt.

- **The workspace is never an agent project.** No workspace carries a routing `CLAUDE.md`, `AGENTS.md`, or `MOUNTS.md`. Process cwd and ACP cwd are *identical* and equal the primary ICM's resolved physical root. Relative agent paths resolve against the primary ICM, never the workspace. (spec invariants 1, 4, 5)
- **Exactly one primary ICM per session; mounting ≠ inclusion.** Every chat and workflow session has exactly one required primary ICM. A mounted ICM is *launchable*, not automatically part of any other ICM's context. Related ICMs join only when the primary ICM's `CONTEXT.md` declares them, direct-only (no transitive grant), cycle-safe. (spec invariants 2, 3; §"Related ICMs")
- **ICMs are external, by-reference, and never mutated by Valea.** No files are copied or moved into a mount. Workspace relationship state never edits `icm.yaml` or any ICM file. Valea-generated runtime/settings files never land inside a user-owned ICM. The same physical ICM may be mounted in several workspaces; its content is not copied. (spec invariants 7, 8, 9)
- **Stable identity.** `icm.yaml` `id` is the ICM's stable identity (not provenance); it travels with the ICM across moves and workspaces. A duplicate `id` within one workspace is a doctor error and cannot enter a session scope. A given physical root and a given ICM `id` may each appear at most once per workspace. (spec §"ICM anatomy and identity")
- **Stable locators for persistence; physical paths only at the I/O boundary.** Persisted app records use stable logical locators — ICM `{"kind":"icm","icm_id","path"}` (ICM-root-relative) or workspace `{"kind":"workspace","path"}` (workspace-relative). The agent never receives `icm://…`; filesystem tools always get a real resolved path. Transcripts/audit snapshot *both* the stable locator and the resolved physical path. (spec invariant 10; §"Stable locators versus physical paths")
- **Workspaces are hidden and id-addressed.** Workspaces live at `~/.valea/workspaces/<slug>-<short-id>/` under `Valea.App.Config.dir/0` (which still honors `VALEA_APP_DIR`). Users name a workspace but never choose or type its folder. Every workspace/ICM/session/workflow RPC is keyed by internal id / mount key + `generation`, never a caller-supplied filesystem path. (spec §"Workspace storage", §"API direction")
- **Least-privilege source access.** A generic chat never receives `sources/`, queue contents, other mounted ICMs, or another workspace. A workflow receives only the exact source files/dirs its validated contract needs. Workspace `logs/`, `config/`, `secrets/`, runtime settings, `.git/`, and SQLite files are always denied to the agent. (spec §"Permission and containment model"; managed policy below)
- **Containment is unchanged at the primitive.** All path decisions continue through `Valea.Paths.resolve_real/2` with segment-boundary membership (`resolved == base or starts_with?(resolved <> "/", base <> "/")`) and symlink-before-`..` resolution. A symlink escaping any granted root is denied unless it lands inside another granted root. Never replace this primitive; only change the *set of roots* fed to it. (spec invariant, §"Permission and containment model")
- **Generation guard.** Every mutating RPC takes `generation` and calls `Valea.Workspace.Manager.check_generation/1` **before** acting, returning `workspace_changed` on mismatch. (unchanged behavior)
- **No `{@html}`** of agent- or user-authored content anywhere in the frontend. Copy tone stays calm, no exclamation marks.
- **Suite gates (run at the end of every task):** `cd backend && mix test` green, `mix format` clean, zero compiler warnings; after any RPC change `cd backend && mix ash_typescript.codegen` then `git diff --exit-code ../frontend/src/lib/api/` must pass (regenerated client committed); `cd frontend && bun run check` 0 errors and `cd frontend && bun run test` green. `just test` runs all of it.
- **TDD, DRY, YAGNI.** Write the failing test first. One commit per task; never push to origin. End each commit message with `Co-Authored-By: Claude <noreply@anthropic.com>`.
- **Test idiom.** Backend tests isolate `VALEA_APP_DIR` to a tmp dir, `Valea.Workspace.Manager.close()` before/after, create+open a workspace via the Manager, and register `on_exit` cleanup (see `test/support/agent_case.ex`). Phase 2 updates that helper to the id-based, hidden-workspace model; every later test uses the updated helper.

---

## Shared Contracts (pin once, reference everywhere)

These are the cross-phase types. Later tasks reference them by name instead of re-deriving. Exact field names/shapes here are normative.

### C1 — Hidden workspace layout (Phase 2)

```text
~/.valea/workspaces/<slug>-<short-id>/      # root; VALEA_APP_DIR overrides ~/.valea
  workspace.yaml                            # version 5 (C2)
  config/{mail.yaml,calendar.yaml}
  sources/{mail/,calendar/,files/}
  queue/{staging,pending,processing,approved,rejected,applied}/
  logs/{sessions/,audit.jsonl}
  runtime/sessions/<session-id>/            # ephemeral, Valea-managed, sweepable
    settings.json                           # managed harness settings (C7)
    context.md                              # resolved related-ICM map (C6)
  secrets/                                  # reserved; keychain preferred
  app.sqlite
```

No root `AGENTS.md`/`CLAUDE.md`/`MOUNTS.md`, no `mounts/` directory, no `.claude/` directory. `<short-id>` is the first 8 chars of the workspace UUID. `Scaffold.valid?/1` marker dirs become `~w(config sources queue logs queue/staging queue/processing runtime)`.

### C2 — `workspace.yaml` version 5

```yaml
version: 5
id: 74fa36f2-3f0c-46fb-92f6-cc20b8a2ab68
name: "Coaching business"

icms:
  coaching:
    path: ~/Documents/Mara Coaching
    enabled: true
  legal:
    path: ~/Knowledge/Legal
    enabled: true
```

Rules (spec §"Workspace config"): the mapping key is the workspace-local **mount key** — a safe basename-like slug, unique in the workspace. `path` is stored in the user's form (`~` preserved) and expanded + symlink-resolved + boundary-validated on every load. `enabled` defaults to `true` when absent. Identity/description come from the ICM's `icm.yaml`, never here. Unknown keys preserved. A physical root appears at most once; an ICM `id` appears at most once. Rejected paths (→ degraded, not written): inside the private workspace, filesystem root, the home dir itself, or an ancestor of the workspace. A fresh workspace writes `version: 5`, `id`, `name`, and an empty `icms: {}`.

### C3 — `icm.yaml` format 2 (`Valea.Mounts.Manifest`)

```yaml
format: 2
id: 6f9f0c9e-3ccd-4fa5-a219-113a70618b55
name: "Mara Lindt Coaching"
description: "Offers, clients, pricing, tone and policies for the coaching business."
```

`%Valea.Mounts.Manifest{format: 2, id: <uuid, required>, name: <required, non-blank>, description: <string|nil>}`. `load/1` returns `{:error, {:invalid, reason}}` when `id` is missing/blank/not a UUID (format 2's new rule vs. the old provenance model). `render/1` always emits `format: 2`. Copying an ICM as a new module requires minting a new id (a create action's job; the codec never mints on load).

### C4 — `CONTEXT.md` frontmatter (related ICMs)

```yaml
---
format: 1
related_icms:
  - id: 31201697-cff8-4d99-9dc5-b140e4178716
    name: "Legal & Administration"
    entrypoint: CONTEXT.md
---
```

`id` required, resolves against **enabled, healthy** ICMs mounted in the current workspace. `name` is descriptive only. `entrypoint` defaults to `CONTEXT.md`, must stay inside the related ICM root. Direct-only, cycle-safe: a session scope = primary ICM + the direct related ICMs it declares; related ICMs' own `related_icms` are not transitively granted. Missing/disabled/duplicate-id/cyclic/escaping entries surface in the doctor; a chat may start with a visible degraded-context warning, a workflow whose inputs need the missing ICM fails preflight.

### C5 — Stable locators (`Valea.Icm.Locator`)

```elixir
# ICM locator — path is ICM-root-relative, passes the owning-root containment gate
%{"kind" => "icm", "icm_id" => "6f9f0c9e-…", "path" => "Pricing/Current Pricing.md"}
# Workspace locator — path is workspace-relative, passes the workspace containment gate
%{"kind" => "workspace", "path" => "sources/mail/messages/42.md"}
```

`Valea.Icm.Locator.resolve(workspace, locator) :: {:ok, physical_abs} | {:error, reason}` resolves an ICM locator by looking the `icm_id` up in the current workspace mount table (missing/disabled/duplicate/moved → error) then `Paths.resolve_real(path, icm_root)`; a workspace locator resolves against the workspace root. JSON-serializable (string keys) for envelopes/audit. The agent never sees a locator — only the resolved physical path.

### C6 — Launch object (`Valea.Agents.SessionScope.resolve/1` result)

```elixir
%{
  workspace: %{id: workspace_id, root: workspace_root, name: workspace_name, generation: generation},
  primary_icm: %{mount_key: "coaching", id: icm_id, root: resolved_icm_root, manifest: %Manifest{}},
  related_icms: [%{mount_key: "legal", id: icm_id, root: resolved_root, entrypoint: "CONTEXT.md", manifest: %Manifest{}}],
  cwd: resolved_icm_root,          # == primary_icm.root
  read_paths: [exact_task_input_abs, …],
  write_paths: [exact_file_abs, …],
  write_roots: [exact_dir_abs, …],
  managed_settings: "<workspace>/runtime/sessions/<id>/settings.json",
  managed_context:  "<workspace>/runtime/sessions/<id>/context.md",
  kind: "chat" | "workflow"
}
```

`SessionScope.resolve/1` takes an opts map `%{kind, mount_key, generation, session_id, read_paths \\ [], write_paths \\ [], write_roots \\ []}` (defined in Phase 5 Task 5.2) and is the ONLY place mount-key lookup, health/uniqueness validation, related-ICM resolution, absolute read/write root computation, and session-local settings/context materialization happen. Neither `Valea.Api.Agents` nor `Valea.Workflows.Runner` re-derives these rules. (spec §"Session scope and launch", §"Backend restructuring map") `managed_context` (the `context.md` bootstrap) is always materialized to disk; the permission posture is rendered in-memory by the harness (`managed_settings` JSON), never written to disk. `SessionScope` hands the scope to the session's harness adapter (`Valea.Harness.launch/2`), which returns the launch directives.

### C7 — Session permission policy: in-memory managedSettings + callback

The session permission policy has two cooperating layers, both keeping Valea out of the ICM: an in-memory **posture** rendered by `SessionSettings.content/1` and injected per-harness (Claude Code: the SDK's `managedSettings`, forwarded as `--managed-settings <json>`) that makes sensitive calls fall through to "ask", and `Valea.Agents.PermissionPolicy` (Task 5.3) on the ACP `session/request_permission` callback, which authoritatively answers each ask. The posture guarantees the call reaches the callback; the callback decides. Neither writes into the ICM. The policy (spec §"Managed harness settings"):

- **Allow reads** in the primary ICM root and each resolved related ICM root, and at each exact task input path.
- **Ask** for `Edit`, `Write`, and `Bash` unless an exact workflow grant applies.
- **Deny** the workspace's `logs/`, `config/`, `secrets/`, `runtime/`, `.git/`, and `app.sqlite*`; deny `WebFetch`/`WebSearch`.
- **Do not auto-load** instructions (`CLAUDE.md`) from related additional directories — only the primary ICM's own `CLAUDE.md` (at the cwd) loads; related entrypoints are read only when the primary ICM's routing calls for them.
- Preserve user-level harness config except where Valea's stronger session enforcement overrides it.

**Claude Code uses in-memory `managedSettings`** (revised after the Phase-1 spike review). The installed adapter cannot load an *external settings file*, but the underlying SDK accepts settings as an **in-memory JSON string** — `managedSettings` (forwarded to the CLI as `--managed-settings <json>`), documented for embedding apps that must "enforce lockdown settings on the spawned subprocess without writing root-owned files," and applied restrictive-only. Valea renders its posture with `SessionSettings.content/1` and passes it as `managedSettings` via the adapter's SDK-options channel (`_meta.claudeCode.options`, per the contract note). This writes **nothing** into or near the ICM (the user's own `.claude/` config there is untouched) *and* sets the posture that guarantees writes/`Bash`/denied-reads fall through to the ACP `request_permission` callback — closing the gap pure callback-only left (with no settings at all, the CLI's own defaults decide first and may auto-resolve a call before Valea sees it). The callback remains the authoritative answer to every resulting ask. Additional read roots are conveyed natively via `session/new` `additionalDirectories`. Whether `additionalDirectories` auto-loads a dir's `CLAUDE.md`, and how to suppress it, is fixed by the Phase-1 spike and recorded in `docs/notes/acp-launch-contract.md`.

### C8 — Session metadata (`session/v1`, written as transcript line 1)

```json
{
  "schema": "session/v1",
  "id": "…",
  "acp_session_id": null,
  "workspace_id": "74fa36f2-…",
  "workspace_name": "Coaching business",
  "icm_mount": "coaching",
  "icm_id": "6f9f0c9e-…",
  "icm_name": "Mara Lindt Coaching",
  "icm_root": "/Users/mara/Documents/Mara Coaching",
  "kind": "chat",
  "workflow": null,
  "run_id": null,
  "title": "…",
  "harness": "claude_code",
  "generation": 3,
  "started_at": "2026-07-13T12:00:00Z"
}
```

Transcripts stay file-only under `<workspace>/logs/sessions/<id>.jsonl` (line 1 metadata, lines 2+ `%{"seq","item"}`). No reader for pre-redesign transcripts (deleted Phase 11).

### C9 — API surface (Ash actions on `Valea.Api`, ash_typescript-exposed)

Names may be refined per task but the domain boundary is fixed (spec §"API direction"). Every mutating action takes `generation`.

- **Workspace** (`Valea.Api.Workspace`): `current_workspace` · `list_workspaces` · `create_workspace(name)` (path app-owned) · `open_workspace(id)` · `workspace_switch_preflight(id)`.
- **ICM mounts** (`Valea.Api.Icms`, replaces `Valea.Api.Mounts`): `list_icms(generation)` · `mount_icm(path, generation)` · `create_icm(name, path, generation)` · `set_icm_enabled(mount_key, enabled, generation)` · `unmount_icm(mount_key, generation)` (config-only) · `icm_doctor(mount_key, generation)` · `icm_tree(mount_key, generation)`.
- **Sessions** (`Valea.Api.Agents`): `create_session(kind, mount_key, generation)` · `list_recent_sessions_by_icm(limit: 5)` (grouped) · `list_sessions(mount_key, cursor)` · `create_follow_up(session_id, generation)`.
- **Workflows** (`Valea.Api.Agents`): registry items `{icm_id, mount_key, relative_path, resolved_path, name, …}`; `run_workflow(mount_key, relative_path, input_locator, generation)`.

### C10 — Module map (new / renamed / deleted)

```text
NEW backend:
  lib/valea/icm/locator.ex                    Valea.Icm.Locator            (C5, Phase 4)
  lib/valea/agents/session_scope.ex           Valea.Agents.SessionScope    (C6, Phase 5)
  lib/valea/agents/session_settings.ex        Valea.Agents.SessionSettings (C7, Phase 1/5)
  lib/valea/mounts/context.ex                 Valea.Mounts.Context         (C4 related-ICMs, Phase 5)
  lib/valea/api/icms.ex                        Valea.Api.Icms               (C9, Phase 3)
  lib/valea/harness.ex                        Valea.Harness behaviour (harness-neutral launch seam) (C7, Phase 1)
  priv/icm_template/                          portable ICM starter, seeded by create/3 (Phase 3, Task 3.5)
NEW frontend:
  src/lib/components/shell/IcmProjects.svelte  sidebar ICM/session groups   (Phase 9)
  src/lib/stores/recent-sessions.svelte.ts     grouped-by-mount session store (Phase 9)
RENAMED/REPURPOSED:
  Valea.Mounts                                 embedded+external → config-only external registry (Phase 3)
  Valea.Mounts.Manifest                        format 1 provenance → format 2 stable identity (Phase 3)
  Valea.Agents.ClaudeSettings                  workspace .claude writer → SessionSettings renderer (Phase 1/5)
  Valea.Harnesses.ClaudeCode                   gains launch/materialization; implements Valea.Harness; in-memory managedSettings + callback (Phase 1)
  Valea.Api.Workspace                          path-based → id-based (Phase 2)
  Valea.ICM.Backlinks / Valea.ICM.LinkRewrite  all-enabled-mounts → primary+related scope, (mount_key, rel_path) (Phase 4 + Task 5.6)
  Valea.Agents.RiskTier                        workspace-path attribution → ICM-locator tier (Phase 7, Task 7.5)
  ValeaWeb.FilesController                      raw-path attribution → mount_key + documented Assets/ stance (Phase 4, Task 4.4)
DELETED (Phase 11):
  lib/valea/mounts/mounts_md.ex                MOUNTS.md generation
  lib/valea/mounts/external.ex                 folded into Valea.Mounts (all mounts are external now)
  lib/valea/workspace/migration.ex             version migration chain
  lib/valea/workspace/adopt.ex                 adopt-by-move onboarding
  frontend onboarding OpenWorkspaceFlow adopt/move + manual-path branches
```

---

## Phase 1 — Harness launch spike

**Milestone:** the claude-agent-acp launch surface is *discovered and documented* — how it receives `cwd`, how it receives additional read roots (native `session/new` `additionalDirectories`), and whether writes/denied-reads reach the ACP `session/request_permission` callback (the authoritative gate) — and a throwaway probe proves the callback-authoritative model end to end. Whether the adapter can also be pointed at an *external* settings pre-filter is recorded as informational (the chosen path is the SDK's in-memory `managedSettings`, see Task 1.2, so an external-settings-file negative answer does not block). Valea also gains a `Valea.Harness` behaviour + a `SessionSettings` renderer + a fake-adapter assertion of the launch shape. **No runtime refactor lands in this phase** (the real chat/workflow launch keeps using the current workspace-root path until Phase 5); this phase de-risks everything downstream.

Today `Valea.Acp.Connection.new/1` sends only `%{"cwd" => launch.cwd, "mcpServers" => []}` on `session/new` (`acp/connection.ex:378-401`), and `Valea.Agents.ClaudeSettings.write!/1` writes `<workspace>/.claude/settings.json` with `./`-anchored globs that are correct only because cwd == workspace (`agents/claude_settings.ex:66-76`, moduledoc). Both assumptions break when cwd becomes an external ICM root. This phase establishes the replacement: additional read roots via the native `additionalDirectories` field, an in-memory `managedSettings` posture (SDK `--managed-settings`, no file) that makes sensitive calls fall through to "ask", and the ACP `request_permission` callback as the authoritative answer — nothing is written into the ICM.

### Task 1.1: Spike — discover and document the adapter launch contract

**Files:**
- Create: `docs/notes/acp-launch-contract.md`
- Create (throwaway proof, committed): `backend/scripts/spike/acp_launch_probe.exs`

**Interfaces:**
- Produces: `docs/notes/acp-launch-contract.md` — the normative record every later phase reads for the exact wire/CLI mechanism behind C7 (managed settings), additional read directories, and cwd. Documents, with a verified example, (a) how the adapter receives cwd, (b) how it receives one-or-more additional readable directories, (c) how it receives a Valea-owned settings/permissions file *not* located in the cwd, (d) how (or whether) it can be told **not** to auto-load `CLAUDE.md` from the additional directories.

This is an investigation task; its "test" is a reproducible proof, not an assertion in `mix test`. Do the investigation, write the contract, then prove it.

- [ ] **Step 1: Inventory the adapter's launch surface**

Locate the adapter Valea shells out to (`Valea.App.Config.harness_command/0`, default `["claude-agent-acp"]`) and read its actual capability surface. Concretely:

Run: `which claude-agent-acp && claude-agent-acp --help 2>&1 | head -60`
Run: `node -e "console.log(require.resolve('@agentclientprotocol/claude-agent-acp'))" 2>/dev/null` (find the installed package) and read its `package.json` `bin`, then read the adapter entry source for how it constructs the Claude Code invocation and which ACP `session/new` params (`cwd`, `mcpServers`, any `_meta`, `settingSources`, additional-directory options) it forwards.
Run: `claude --help 2>&1 | grep -iE "add-dir|settings|setting-sources|permission|strict-mcp"` to see which Claude Code CLI flags exist (`--add-dir`, `--settings <file>`, `--setting-sources`, `--permission-mode`, `--strict-mcp-config` are the candidates) and whether the ACP adapter forwards them (via argv, env such as `CLAUDE_CODE_*`, or ACP `_meta`).

Record findings verbatim in `acp-launch-contract.md` under a "Surface" heading. Do not guess — quote the `--help` output and the adapter source lines you relied on.

- [ ] **Step 2: Write the contract**

In `docs/notes/acp-launch-contract.md`, document the chosen mechanism for each of C7's needs as a concrete recipe (exact flag/env/param names + example values), plus a "Rejected alternatives" note for anything that looked plausible but the adapter does not forward. Lock these decisions:

- **cwd:** confirmed `session/new` `cwd` (already used). State it stays authoritative for relative agent paths.
- **Additional read roots:** the exact mechanism (expected: Claude Code `--add-dir <abs>` per root, forwarded by the adapter, or ACP session param). Note whether added dirs auto-load their `CLAUDE.md` and, if so, how to suppress it (`--setting-sources`, or omit — see step 4).
- **Managed settings:** the exact mechanism to point the harness at `runtime/sessions/<id>/settings.json` (expected: `--settings <abs>` and/or a `CLAUDE_CODE_*` env var) so no `.claude/settings.json` is written into the cwd/ICM.
- **Instruction isolation:** how to keep related additional directories from contributing project instructions globally (C7 last bullet).

- [ ] **Step 3: Build the proof harness**

Write `backend/scripts/spike/acp_launch_probe.exs` — a throwaway Elixir script that, using `Valea.Agents.Env.minimal/0` and `Valea.Harnesses.ClaudeCode.acp_command/1`, launches ONE real adapter session (via `Valea.Agents.ProcessRuntime` + `Valea.Acp.Connection`) with:

- `cwd` = a temp "primary ICM" dir containing a marker file `PRIMARY.md` and a `CLAUDE.md`,
- one additional read root = a temp "related ICM" dir containing `RELATED.md` and its own `CLAUDE.md`,
- a Valea-owned settings file in a *third* temp dir (standing in for `runtime/sessions/<id>/settings.json`) that denies a temp "secret" dir and asks for writes,

then drives one prompt asking the agent to read `PRIMARY.md`, read `RELATED.md` (via absolute path), attempt to read the secret file, and attempt a write. The script prints the permission decisions / tool results it observes. Keep it dependency-free (reuse existing Valea modules); mark it clearly as a spike probe in a header comment.

- [ ] **Step 4: Run the proof and record the result**

Run: `cd backend && mix run scripts/spike/acp_launch_probe.exs`
Expected and required to pass the milestone:
- `PRIMARY.md` reads without a prompt (cwd allow).
- `RELATED.md` reads without a prompt via its absolute path (additional-root allow).
- the secret file read is denied.
- the write is ask-gated (reaches the client permission callback rather than auto-allowing).
- no `.claude/` directory is created inside either the primary or related temp dir (verify with `find <primary> <related> -name settings.json`).

Paste the observed output into `acp-launch-contract.md` under "Verified proof". If any expectation fails, iterate the mechanism (step 2) until all pass; the downstream phases depend on this being real, not assumed.

**Fallback decision (record the outcome in the contract note).** A review of the installed `@agentclientprotocol/claude-agent-acp@0.58.1` found: (a) additional read roots ARE natively supported — `session/new` accepts a top-level `additionalDirectories` field (prefer it over any `_meta.valea.*` invention; see Task 1.3); but (b) the adapter's `SettingsManager` only resolves `.claude/settings.json` from the session **cwd** + `~/.claude` + the OS-managed path — there is **no** parameter to point it at an external Valea-owned settings file. If the spike confirms (b) against whatever adapter version ships at implementation time, choose and document ONE fallback before Task 1.2 builds `SessionSettings.materialize!`: **(1)** a newer adapter/CLI surface that forwards `--settings`/`--add-dir` (re-verify — the bare `claude` CLI has these; confirm the adapter passes them through); **(2)** write a Valea-owned `<cwd>/.claude/settings.json` inside the ICM as a documented, gitignored-by-convention exception to invariant 9 (weakest — the spec explicitly rules this out; take it only if 1 and 3 fail); or **(3)** drop settings-file pre-filtering and enforce solely through the ACP `session/request_permission` round-trip with `PermissionPolicy` as sole authority (architecturally clean since `PermissionPolicy` already decides allow/deny/ask, but the SDK's default permission mode governs auto-approvals before Valea's callback fires — verify it prompts rather than auto-allows). Whichever is chosen, `SessionSettings`'s target/consumption contract (Task 1.2) must be shaped to it, so this decision precedes Task 1.2. **Decision landed (revised post-review):** neither the external settings file (options 1/2) nor pure callback-only (option 3), but the SDK's in-memory `managedSettings` — settings passed as `--managed-settings <json>`, no file written anywhere. This sets the restrictive posture (ask writes/`Bash`, deny workspace state) so sensitive calls reach the ACP callback, which `PermissionPolicy` answers authoritatively. It closes the hole the review found in pure callback-only (with no settings, the CLI's defaults may auto-resolve a call before Valea sees it). See C7 and Task 1.2.

- [ ] **Step 5: Commit**

```bash
git add docs/notes/acp-launch-contract.md backend/scripts/spike/acp_launch_probe.exs
git commit -m "spike: prove claude-agent-acp launch contract (cwd + add-dir + managed settings)"
```

### Task 1.2: `Valea.Harness` behaviour + `SessionSettings` renderer (in-memory managedSettings for Claude Code)

**Files:**
- Create: `backend/lib/valea/harness.ex` (the `Valea.Harness` behaviour — harness-neutral launch seam)
- Modify: `backend/lib/valea/harnesses/claude_code.ex` (`Valea.Harnesses.ClaudeCode` implements `Valea.Harness`; delegates rendering to `SessionSettings`; conveys the in-memory `managedSettings` posture)
- Create: `backend/lib/valea/agents/session_settings.ex` (the Claude Code adapter's renderer)
- Test: `backend/test/valea/agents/session_settings_test.exs`, `backend/test/valea/harnesses/claude_code_test.exs`

**Interfaces:**
- Consumes: the C7 policy and the C6 launch object shape (only the fields it needs: `primary_icm.root`, `related_icms[].root`, `read_paths`, `write_paths`, `write_roots`, `workspace.root`, `managed_settings`, `managed_context`).
- Produces:
  - `Valea.Agents.SessionSettings.content(scope :: map()) :: map()` — the settings JSON map (C7), computed from absolute roots (NOT `./`-anchored). Deny wins over allow.
  - `Valea.Agents.SessionSettings.context(scope :: map()) :: String.t()` — the `context.md` bootstrap listing the resolved primary + related ICM roots and entrypoints (C6 map, human/agent-readable).
  - `Valea.Agents.SessionSettings.materialize!(scope :: map()) :: :ok` — writes only `context/1` to `scope.managed_context`, creating `runtime/sessions/<id>/` (atomic tmp+rename), never inside any ICM root. The permission posture is NOT written to disk; it is rendered by `content/1` and passed in-memory to the harness (see `launch/2`).
  - `Valea.Harness` behaviour: `c:launch(scope :: map(), session_dir :: String.t()) :: {:ok, directives :: map()}` where `directives = %{cwd, additional_roots, context_path, managed_settings, env, argv_extra}` (`managed_settings` is the in-memory posture JSON string, or `nil` for a harness that doesn't support it). The harness-neutral seam SessionScope calls (Phase 5).
  - `Valea.Harnesses.ClaudeCode.launch/2` (implements the behaviour): calls `SessionSettings.materialize!/1` (context only), then returns `additional_roots` = resolved related-ICM + exact-input roots (conveyed as `additionalDirectories`), `context_path` = the materialized `context.md`, and `managed_settings` = `Jason.encode!(SessionSettings.content(scope))` — the in-memory posture JSON conveyed to the adapter via its SDK-options channel (`_meta.claudeCode.options.managedSettings`, per the contract note). Nothing is written to the ICM; `PermissionPolicy` on the ACP callback authoritatively answers the asks the posture produces.

Note: this renders *absolute-root* allow/deny rules (the C7 policy), unlike the old `ClaudeSettings` which relied on `./**` anchored to cwd==workspace. This is the module that makes cwd≠workspace safe.

**Contract injection (inject+seed decision).** `context/1` is where Valea's own queue vocabulary lives now that the workspace carries no root `AGENTS.md`. For a **workflow** session (`scope.kind == "workflow"`), `context/1` appends the `proposal/v1` + `memory_update/v1` contract text — the exact schema guidance currently in `backend/priv/workspace_template/AGENTS.md`, which Phase 2 deletes. This keeps the Valea-specific vocabulary out of the portable ICM's own files (the ICM stays usable by a bare harness) while still teaching each workflow run the proposal shapes. Preserve that contract text verbatim in this module when Phase 2 removes the template `AGENTS.md`. Add a test: `context(scope(%{kind: "workflow"}))` contains `memory_update/v1`, and `context(scope(%{kind: "chat"}))` does not.

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/agents/session_settings_test.exs
defmodule Valea.Agents.SessionSettingsTest do
  use ExUnit.Case, async: true

  alias Valea.Agents.SessionSettings

  defp scope(overrides) do
    Map.merge(
      %{
        workspace: %{id: "ws", root: "/ws", name: "W", generation: 1},
        primary_icm: %{mount_key: "coaching", id: "icm-1", root: "/icms/coaching", manifest: nil},
        related_icms: [%{mount_key: "legal", id: "icm-2", root: "/icms/legal", entrypoint: "CONTEXT.md", manifest: nil}],
        cwd: "/icms/coaching",
        read_paths: [],
        write_paths: [],
        write_roots: [],
        managed_settings: nil,
        managed_context: nil,
        kind: "chat"
      },
      overrides
    )
  end

  test "allows reads in primary and related ICM roots as absolute globs" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    assert "Read(/icms/coaching/**)" in perms["allow"]
    assert "Read(/icms/legal/**)" in perms["allow"]
  end

  test "asks for edit/write/bash" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    assert "Write" in perms["ask"]
    assert "Edit" in perms["ask"]
    assert "Bash" in perms["ask"]
  end

  test "denies workspace operational state and web tools" do
    perms = SessionSettings.content(scope(%{}))["permissions"]
    for glob <- ["Read(/ws/logs/**)", "Read(/ws/config/**)", "Read(/ws/secrets/**)",
                 "Read(/ws/runtime/**)", "Read(/ws/.git/**)", "Read(/ws/app.sqlite)"] do
      assert glob in perms["deny"], "expected deny to include #{glob}"
    end
    assert "WebFetch" in perms["deny"]
    assert "WebSearch" in perms["deny"]
  end

  test "grants exact task input reads and exact workflow write paths/roots" do
    perms =
      SessionSettings.content(
        scope(%{read_paths: ["/ws/sources/mail/messages/42.md"],
                write_paths: ["/ws/queue/staging/r1/proposal.json"],
                write_roots: ["/ws/queue/staging/r1/proposals"]})
      )["permissions"]

    assert "Read(/ws/sources/mail/messages/42.md)" in perms["allow"]
    assert "Write(/ws/queue/staging/r1/proposal.json)" in perms["allow"]
    assert "Write(/ws/queue/staging/r1/proposals/**)" in perms["allow"]
  end

  test "context.md lists primary and related roots" do
    md = SessionSettings.context(scope(%{}))
    assert md =~ "/icms/coaching"
    assert md =~ "/icms/legal"
    assert md =~ "CONTEXT.md"
  end

  test "materialize! writes only context.md (posture is in-memory), never inside an ICM root" do
    tmp = Path.join(System.tmp_dir!(), "vss-#{System.unique_integer([:positive])}")
    icm = Path.join(tmp, "icm")
    File.mkdir_p!(icm)
    context = Path.join([tmp, "ws", "runtime", "sessions", "s1", "context.md"])

    :ok =
      SessionSettings.materialize!(
        scope(%{primary_icm: %{mount_key: "c", id: "i", root: icm, manifest: nil},
                cwd: icm, related_icms: [], managed_context: context})
      )

    assert File.exists?(context)
    refute File.exists?(Path.join([tmp, "ws", "runtime", "sessions", "s1", "settings.json"]))
    assert File.dir?(Path.join(icm, ".claude")) == false
    on_exit(fn -> File.rm_rf!(tmp) end)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/agents/session_settings_test.exs`
Expected: FAIL — `Valea.Agents.SessionSettings` is undefined.

- [ ] **Step 3: Implement**

```elixir
# backend/lib/valea/agents/session_settings.ex
defmodule Valea.Agents.SessionSettings do
  @moduledoc """
  Renders and materializes the Valea-owned harness settings + context for one
  session, under `<workspace>/runtime/sessions/<id>/`. Unlike the old
  `Valea.Agents.ClaudeSettings` (which wrote `<workspace>/.claude/settings.json`
  and relied on `./**` globs being anchored to cwd == workspace), every rule
  here is an ABSOLUTE-path glob so it stays correct when the cwd is an external
  ICM root that is NOT the workspace. Deny wins over allow. Valea never writes a
  settings file inside a user-owned ICM.

  See docs/notes/acp-launch-contract.md for how the harness is pointed at the
  materialized settings file and the additional read roots.
  """

  @protected ~w(logs config secrets runtime .git)
  @db_files ~w(app.sqlite app.sqlite-wal app.sqlite-shm)

  @spec content(map()) :: map()
  def content(scope) do
    read_root_allows =
      ([scope.primary_icm.root] ++ Enum.map(scope.related_icms, & &1.root))
      |> Enum.map(&"Read(#{&1}/**)")

    input_allows = Enum.map(scope.read_paths, &"Read(#{&1})")
    write_path_allows = Enum.map(scope.write_paths, &"Write(#{&1})")
    write_root_allows = Enum.map(scope.write_roots, &"Write(#{&1}/**)")

    ws = scope.workspace.root

    deny =
      Enum.flat_map(@protected, fn d ->
        ["Read(#{ws}/#{d}/**)", "Edit(#{ws}/#{d}/**)", "Write(#{ws}/#{d}/**)"]
      end) ++
        Enum.map(@db_files, &"Read(#{ws}/#{&1})") ++
        ["WebFetch", "WebSearch"]

    %{
      "permissions" => %{
        "deny" => deny,
        "ask" => ["Write", "Edit", "Bash"],
        "allow" => read_root_allows ++ input_allows ++ write_path_allows ++ write_root_allows
      }
    }
  end

  @spec context(map()) :: String.t()
  def context(scope) do
    related =
      scope.related_icms
      |> Enum.map(fn r -> "- #{r.mount_key} (#{r.root}) — entrypoint #{r.entrypoint}" end)
      |> Enum.join("\n")

    related = if related == "", do: "(none)", else: related

    """
    # Session context (Valea-managed)

    Primary ICM: #{scope.primary_icm.mount_key} — #{scope.primary_icm.root}
    Your working directory IS this ICM's root. Relative paths resolve here.

    Related ICMs available to this session (read their entrypoint only when your
    routing calls for it; they do not load automatically):
    #{related}
    """
  end

  @spec materialize!(map()) :: :ok
  def materialize!(scope) do
    # Only context.md is written to disk (session bootstrap: related-ICM map + injected
    # contract). The permission posture is NOT written as a file — it is rendered by
    # content/1 and passed in-memory to the harness as managedSettings (--managed-settings
    # <json>), so nothing lands in or near the ICM. Enforcement: the posture forces sensitive
    # calls to "ask", and PermissionPolicy on the ACP request_permission callback answers them.
    write_atomic!(scope.managed_context, context(scope))
    :ok
  end

  defp write_atomic!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/agents/session_settings_test.exs`
Expected: PASS.

- [ ] **Step 5: Define the `Valea.Harness` behaviour + Claude Code adapter**

Create `backend/lib/valea/harness.ex` with `@callback launch(scope :: map(), session_dir :: String.t()) :: {:ok, map()}`. In `Valea.Harnesses.ClaudeCode`, implement `launch/2`: `SessionSettings.materialize!(scope)` (context only), then return `{:ok, %{cwd: scope.cwd, additional_roots: related_and_input_roots(scope), context_path: scope.managed_context, managed_settings: Jason.encode!(SessionSettings.content(scope)), env: Valea.Agents.Env.minimal(), argv_extra: []}}`. Add `backend/test/valea/harnesses/claude_code_test.exs` asserting `launch/2` returns a `managed_settings` JSON string whose decoded `permissions.deny` includes the workspace-state globs and whose `permissions.ask` includes `Write`/`Bash`, `additional_roots` containing the related root, a `context_path` that exists after the call, and no `.claude/` written under the ICM.

- [ ] **Step 6: Run to verify pass** — `cd backend && mix test test/valea/agents/session_settings_test.exs test/valea/harnesses/claude_code_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/valea/harness.ex backend/lib/valea/harnesses/claude_code.ex backend/lib/valea/agents/session_settings.ex backend/test/valea/agents/session_settings_test.exs backend/test/valea/harnesses/claude_code_test.exs
git commit -m "feat: Valea.Harness behaviour + ClaudeCode launch adapter (in-memory managedSettings)"
```

### Task 1.3: Teach `Acp.Connection` + fake adapter the extended launch shape

**Files:**
- Modify: `backend/lib/valea/acp/connection.ex:378-401` (`open_session_frames/2`)
- Modify: `backend/test/support/fake_adapter.exs` (assert/echo the launch params)
- Test: `backend/test/valea/acp/connection_test.exs` (add cases; create if absent)

**Interfaces:**
- Consumes: the launch map given to `Connection.new/1`, extended from `%{cwd, mode, conversation_id, known_message_ids, client_version}` with two optional fields: `additional_roots :: [String.t()]` (absolute additional directories → `additionalDirectories`) and `managed_settings :: String.t() | nil` (the in-memory posture JSON → the adapter's SDK-options channel).
- Produces: `session/new` frames that carry the additional read roots (native `additionalDirectories`) and the in-memory `managedSettings` posture JSON (via the adapter's SDK-options channel, per the contract note), defaulting to today's behavior when the fields are absent. The test asserts `additionalDirectories` carries the related root and the `managedSettings` posture is transmitted. The fake adapter records what it received so tests can assert transmission.

Use the exact param/flag names fixed in `docs/notes/acp-launch-contract.md`. The code below shows one encoding; if the contract instead fixes CLI flags forwarded by the adapter, encode them where `ProcessRuntime` builds argv and adjust the test to assert argv — keep the *test's* observable contract (additional roots + managed-settings posture transmitted) identical. **Note:** the installed adapter exposes additional read roots as a native top-level `session/new` `additionalDirectories` field, and the in-memory posture rides the SDK-options channel (`_meta.claudeCode.options.managedSettings`); use the exact field placement the Task-1.1 contract note fixes and adjust the test assertions to match.

- [ ] **Step 1: Write the failing test**

```elixir
# backend/test/valea/acp/connection_test.exs  (add these cases)
defmodule Valea.Acp.ConnectionLaunchTest do
  use ExUnit.Case, async: true
  alias Valea.Acp.Connection

  defp session_new_frame(launch) do
    {state, _init_frames} = Connection.new(launch)
    # advance the handshake to the point session/new is emitted
    init_resp =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 0,
        "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}})
    {_state, _items, frames, _effects} = Connection.handle_bytes(state, init_resp <> "\n")
    frames |> Enum.map(&Jason.decode!/1) |> Enum.find(&(&1["method"] == "session/new"))
  end

  test "session/new carries cwd (baseline, unchanged)" do
    frame = session_new_frame(%{cwd: "/icms/coaching", mode: :new, conversation_id: nil,
      known_message_ids: MapSet.new(), client_version: "test"})
    assert frame["params"]["cwd"] == "/icms/coaching"
  end

  test "session/new carries additional read roots and the managed-settings posture when present" do
    frame = session_new_frame(%{cwd: "/icms/coaching", mode: :new, conversation_id: nil,
      known_message_ids: MapSet.new(), client_version: "test",
      additional_roots: ["/icms/legal"],
      managed_settings: ~s({"permissions":{"deny":["Read(/ws/logs/**)"],"ask":["Write","Bash"]}})})

    # exact field placement per docs/notes/acp-launch-contract.md — assert the values reach the frame
    assert frame["params"]["cwd"] == "/icms/coaching"
    assert "/icms/legal" in frame["params"]["additionalDirectories"]
    assert get_in(frame, ["params", "_meta", "claudeCode", "options", "managedSettings"]) =~ "Write"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/acp/connection_test.exs`
Expected: FAIL — the second assertion fails (no `_meta` carried today).

- [ ] **Step 3: Implement**

In `acp/connection.ex`, extend `open_session_frames/2` so the `session/new` base includes the additional roots (native `additionalDirectories`) + the managed-settings posture when the launch map carries them (encode per the contract note — shown here as native field + `_meta`, adjust if the contract fixes CLI-flag forwarding):

```elixir
defp open_session_frames(%{launch: launch} = state, caps) do
  base =
    %{"cwd" => launch.cwd, "mcpServers" => []}
    |> put_additional_directories(launch)
    |> put_managed_settings(launch)

  cond do
    # …existing session/resume + session/load branches unchanged…
    true -> request(state, "session/new", base, :session_new)
  end
end

# additionalDirectories is a native session/new field (per the contract note).
defp put_additional_directories(base, launch) do
  case Map.get(launch, :additional_roots) do
    roots when is_list(roots) and roots != [] -> Map.put(base, "additionalDirectories", roots)
    _ -> base
  end
end

# The in-memory posture rides the adapter's SDK-options channel (per the contract note).
defp put_managed_settings(base, launch) do
  case Map.get(launch, :managed_settings) do
    json when is_binary(json) ->
      Map.put(base, "_meta", %{"claudeCode" => %{"options" => %{"managedSettings" => json}}})

    _ ->
      base
  end
end
```

Then extend `test/support/fake_adapter.exs` to store the received `session/new` `params` (including `_meta`) and echo them back in a way the SessionServer E2E tests (Phase 5) can observe — mirror however the fake adapter already records `cwd`.

- [ ] **Step 4: Run to verify pass**

Run: `cd backend && mix test test/valea/acp/connection_test.exs`
Expected: PASS.

- [ ] **Step 5: Full suite + commit**

Run: `cd backend && mix test`
Expected: PASS (no existing session/workflow behavior changed — the new fields are absent on today's launches).

```bash
git add backend/lib/valea/acp/connection.ex backend/test/support/fake_adapter.exs backend/test/valea/acp/connection_test.exs
git commit -m "feat: ACP launch carries additional read roots + managed settings path (contract-gated)"
```

**Phase 1 exit check:** `docs/notes/acp-launch-contract.md` exists with a Verified-proof section; `SessionSettings` renders absolute-root managed settings + context and never writes inside an ICM; `Connection` transmits the extended launch shape; `mix test` green. Nothing in the live chat/workflow path has changed yet.

---

## Phase 2 — Hidden workspace storage & id-based lifecycle

**Milestone:** workspaces are created app-owned under `~/.valea/workspaces/<slug>-<short-id>/` (C1) with `workspace.yaml` version 5 (C2), and the whole lifecycle (create/open/list/switch-preflight/current) is keyed by internal id — no caller ever supplies or receives a filesystem path. The workspace is no longer an agent project: the v5 template has no root `AGENTS.md`/`CLAUDE.md`/`MOUNTS.md`, no `mounts/`, no `.claude/`, and adds `runtime/`.

Legacy note: `Valea.Workspace.Migration` and `Valea.Workspace.Adopt` still exist after this phase (deleted in Phase 11). A fresh v5 workspace passes through `Migration.migrate/1` as all-no-ops (each `ensure_vN` is a no-op once version ≥ N), so leave it wired; do not run it against the new template. Repoint its template source to a preserved legacy copy so old-workspace migration tests stay green.

### Task 2.1: `Valea.App.Config` — app-owned workspaces dir + id-keyed registry

**Files:**
- Modify: `backend/lib/valea/app/config.ex` (add `workspaces_dir/0`; re-key `known_workspaces` by id)
- Test: `backend/test/valea/app/config_test.exs` (create/extend)

**Interfaces:**
- Consumes: `Valea.App.Config.dir/0` (unchanged: `VALEA_APP_DIR` or `:filename.basedir(:user_data, "valea")`, `app/config.ex:18-23`).
- Produces:
  - `Valea.App.Config.workspaces_dir() :: String.t()` — `Path.join(dir(), "workspaces")`.
  - `Valea.App.Config.record_opened(%{id, name, slug, path}) :: :ok` — id-keyed upsert into `known_workspaces` (entry `%{"id","name","slug","path","last_opened_at"}`), sets `last_opened => id`.
  - `Valea.App.Config.recent() :: [%{"id","name","slug","path","last_opened_at"}]` — existing-dir-filtered, newest first (unchanged filtering, now id-carrying).
  - `Valea.App.Config.workspace_by_id(id) :: map() | nil` and `Valea.App.Config.last_opened_id() :: String.t() | nil` — used by Manager for id→path resolution and auto-open.

`path` stays in the registry as the *internal* on-disk locator the Manager needs to boot a workspace; it is never sent to or accepted from the UI (which uses `id` only).

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/app/config_test.exs
defmodule Valea.App.ConfigTest do
  use ExUnit.Case, async: false
  alias Valea.App.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-cfg-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    on_exit(fn -> File.rm_rf!(dir); System.delete_env("VALEA_APP_DIR") end)
    File.mkdir_p!(dir)
    :ok
  end

  test "workspaces_dir is under the app dir" do
    assert Config.workspaces_dir() == Path.join(Config.dir(), "workspaces")
  end

  test "record_opened keys by id and sets last_opened to the id" do
    ws = Path.join(Config.workspaces_dir(), "coaching-a2f3")
    File.mkdir_p!(ws)
    :ok = Config.record_opened(%{id: "id-1", name: "Coaching", slug: "coaching", path: ws})

    assert Config.last_opened_id() == "id-1"
    assert %{"id" => "id-1", "name" => "Coaching", "path" => ^ws} = Config.workspace_by_id("id-1")
    assert [%{"id" => "id-1"}] = Config.recent()
  end

  test "recent drops entries whose folder no longer exists" do
    :ok = Config.record_opened(%{id: "gone", name: "Gone", slug: "gone", path: Path.join(Config.workspaces_dir(), "gone-0000")})
    assert Config.recent() == []
    assert Config.workspace_by_id("gone") == nil or match?(%{}, Config.workspace_by_id("gone"))
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/app/config_test.exs`
Expected: FAIL — `workspaces_dir/0`, `record_opened/1`, `workspace_by_id/1`, `last_opened_id/0` undefined.

- [ ] **Step 3: Implement**

In `app/config.ex`, add `workspaces_dir/0`; change the `record_opened` arity to take a map and dedup by `id`; add `workspace_by_id/1` and `last_opened_id/0`; keep `recent/0` filtering by `File.dir?(entry["path"])` but returning the id-carrying entries.

```elixir
def workspaces_dir, do: Path.join(dir(), "workspaces")

def record_opened(%{id: id, name: name, slug: slug, path: path}) do
  cfg = read()
  entry = %{"id" => id, "name" => name, "slug" => slug, "path" => path,
            "last_opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
  known = [entry | Enum.reject(cfg["known_workspaces"], &(&1["id"] == id))]
  write(%{cfg | "known_workspaces" => known, "last_opened" => id})
end

def workspace_by_id(id), do: Enum.find(read()["known_workspaces"], &(&1["id"] == id))
def last_opened_id, do: read()["last_opened"]

def recent do
  read()["known_workspaces"]
  |> Enum.filter(&File.dir?(&1["path"]))
  |> Enum.sort_by(& &1["last_opened_at"], :desc)
end
```

(`write/1` mirrors the existing private JSON writer; if `record_opened/2` still has callers, update them in this task — grep `record_opened`.)

- [ ] **Step 4: Run to verify pass** — `cd backend && mix test test/valea/app/config_test.exs` → PASS.
- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/app/config.ex backend/test/valea/app/config_test.exs
git commit -m "feat: app-owned workspaces_dir + id-keyed workspace registry"
```

### Task 2.2: v5 hidden workspace template + Scaffold

**Files:**
- Create: `backend/priv/workspace_template/` (v5 layout, C1) — replace the current contents
- Preserve: copy the current `backend/priv/workspace_template/` to `backend/priv/legacy_workspace_template/` **before** replacing it (migration reads it until Phase 11)
- Modify: `backend/lib/valea/workspace/scaffold.ex` (marker dirs; `create/2` builds the v5 tree; drop starter-mount/MOUNTS/`.claude`)
- Modify: `backend/lib/valea/workspace/migration.ex:439` (`template_dir/0` → `legacy_workspace_template`)
- Test: `backend/test/valea/workspace/scaffold_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.Manifest` (unchanged here), `Valea.App.Config` (not needed).
- Produces:
  - `Valea.Workspace.Scaffold.create(target :: String.t(), name :: String.t(), id :: String.t()) :: :ok | {:error, term()}` — builds the C1 tree at `target`, writing `workspace.yaml` = `version: 5`, the given `id`, `name`, `icms: {}`. No starter mount, no `MOUNTS.md`, no root agent files, no `.claude/`, creates `runtime/`.
  - `Valea.Workspace.Scaffold.valid?/1` — marker dirs `~w(config sources queue logs queue/staging queue/processing runtime)`.
  - `Valea.Workspace.Scaffold.slugify/1` — unchanged (Manager reuses it for the folder name).

- [ ] **Step 1: Preserve the legacy template and build the v5 template**

```bash
cp -R backend/priv/workspace_template backend/priv/legacy_workspace_template
```

Then replace `backend/priv/workspace_template/` with the v5 layout: delete `AGENTS.md`, `CLAUDE.md`, `MOUNTS.md`, and the whole `mounts/` subtree; keep `config/mail.yaml`, `config/calendar.yaml`, `sources/…`, `queue/*/.gitkeep`, `logs/audit.jsonl`, `secrets/.gitkeep`, `gitignore`; add `runtime/.gitkeep`; set `config/workspace.yaml` to:

```yaml
version: 5
id: TEMPLATE
name: "Workspace"
icms: {}
```

Repoint migration's template source:

```elixir
# migration.ex:439
defp template_dir, do: Application.app_dir(:valea, "priv/legacy_workspace_template")
```

- [ ] **Step 2: Write the failing tests**

```elixir
# backend/test/valea/workspace/scaffold_test.exs  (rewrite the create/valid cases)
defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true
  alias Valea.Workspace.Scaffold

  setup do
    t = Path.join(System.tmp_dir!(), "vsc-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(t) end)
    %{target: t}
  end

  test "creates the hidden v5 layout with no agent-routing files", %{target: t} do
    :ok = Scaffold.create(t, "Coaching business", "74fa36f2-0000-0000-0000-000000000000")

    assert Scaffold.valid?(t)
    for d <- ~w(config sources queue logs queue/staging queue/processing runtime),
        do: assert File.dir?(Path.join(t, d)), "missing #{d}"

    refute File.exists?(Path.join(t, "AGENTS.md"))
    refute File.exists?(Path.join(t, "CLAUDE.md"))
    refute File.exists?(Path.join(t, "MOUNTS.md"))
    refute File.dir?(Path.join(t, "mounts"))
    refute File.dir?(Path.join(t, ".claude"))

    yaml = File.read!(Path.join(t, "config/workspace.yaml"))
    assert yaml =~ "version: 5"
    assert yaml =~ "74fa36f2-0000-0000-0000-000000000000"
    assert yaml =~ ~s(name: "Coaching business")
    assert yaml =~ "icms: {}"
  end
end
```

- [ ] **Step 3: Run to verify failure** — `cd backend && mix test test/valea/workspace/scaffold_test.exs` → FAIL.

- [ ] **Step 4: Implement**

Rewrite `Scaffold.create/2`→`create/3` to `cp_r` the (now v5) template, rename `gitignore`→`.gitignore`, then overwrite `config/workspace.yaml` with the rendered v5 doc (`version: 5`, given id, escaped name via `Valea.Yaml.escape/1`, `icms: {}`). Delete `mint_starter_mount!`, the `ClaudeSettings.write!` call, and the `MountsMd.regenerate` call. Set `@marker_dirs ~w(config sources queue logs queue/staging queue/processing runtime)`. Keep `slugify/1` and `inspect_summary/1` (drop `icm_pages`/`workflows` counts that assumed `mounts/`, or compute them as 0 — a fresh hidden workspace has no ICMs). Keep the `create/1` and `create/2` arities only if still called; otherwise update callers (Manager, Adopt) in their own tasks.

- [ ] **Step 5: Run to verify pass** — `cd backend && mix test test/valea/workspace/scaffold_test.exs` → PASS.
- [ ] **Step 6: Commit**

```bash
git add backend/priv/workspace_template backend/priv/legacy_workspace_template backend/lib/valea/workspace/scaffold.ex backend/lib/valea/workspace/migration.ex backend/test/valea/workspace/scaffold_test.exs
git commit -m "feat: v5 hidden workspace template + Scaffold (no agent-routing files)"
```

### Task 2.3: `Valea.Workspace.Manager` — create(name) app-owned + open(id)

**Files:**
- Modify: `backend/lib/valea/workspace/manager.ex` (`create/1`, `open/1` by id, `current/0` returns id, auto-open by id)
- Test: `backend/test/valea/workspace/manager_test.exs`

**Interfaces:**
- Consumes: `Valea.App.Config.workspaces_dir/0`, `record_opened/1`, `workspace_by_id/1`, `last_opened_id/0`; `Valea.Workspace.Scaffold.slugify/1`, `create/3`, `valid?/1`.
- Produces:
  - `Valea.Workspace.Manager.create(name :: String.t()) :: {:ok, %{id, name, path, generation}} | {:error, term()}` — mints a workspace UUID, computes `path = Path.join(workspaces_dir(), "#{slugify(name)}-#{String.slice(uuid, 0, 8)}")`, scaffolds v5 there, opens it, records it by id.
  - `Valea.Workspace.Manager.open(id :: String.t()) :: {:ok, %{id, name, path, generation}} | {:error, :unknown_workspace | :not_a_workspace | term()}` — resolves `id → path` via `App.Config.workspace_by_id/1`, then the existing path-based open pipeline (`manager.ex:122-196`).
  - `Valea.Workspace.Manager.current/0` — now `%{path, name, id, generation}` when open (adds `id`, read from `workspace.yaml`).
  - `Valea.Workspace.Manager.generation/0`, `check_generation/1`, `close/0` — unchanged.

The GenServer state gains `id` alongside `path`/`name` (read from the opened `workspace.yaml`). Keep the internal path-based open helpers; only the *public entry points* become id-based.

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/workspace/manager_test.exs  (add/replace)
defmodule Valea.Workspace.ManagerTest do
  use ExUnit.Case, async: false
  alias Valea.Workspace.Manager
  alias Valea.App.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-mgr-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    on_exit(fn -> Manager.close(); File.rm_rf!(dir); System.delete_env("VALEA_APP_DIR") end)
    :ok
  end

  test "create(name) places the workspace under the app-owned hidden dir" do
    {:ok, ws} = Manager.create("Coaching business")
    assert String.starts_with?(ws.path, Config.workspaces_dir())
    assert Path.basename(ws.path) |> String.starts_with?("coaching-business-")
    assert ws.name == "Coaching business"
    assert is_binary(ws.id)
    assert %{id: id, name: "Coaching business"} = Manager.current()
    assert id == ws.id
  end

  test "open(id) reopens a previously created workspace by id" do
    {:ok, ws} = Manager.create("Legal")
    :ok = Manager.close()
    {:ok, reopened} = Manager.open(ws.id)
    assert reopened.id == ws.id
    assert reopened.path == ws.path
  end

  test "open(unknown id) errors" do
    assert {:error, :unknown_workspace} = Manager.open("nope")
  end
end
```

- [ ] **Step 2: Run to verify failure** — `cd backend && mix test test/valea/workspace/manager_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Add `create/1` (`GenServer.call(__MODULE__, {:create, name}, 30_000)`) and change `open/1` to accept an id. In `handle_call({:create, name}, …)`: mint uuid, build path, `Scaffold.create(path, name, uuid)`, then run the existing open pipeline against `path`, then `App.Config.record_opened(%{id: uuid, name: name, slug: slugify(name), path: path})`. In `handle_call({:open, id}, …)`: `case App.Config.workspace_by_id(id) do nil -> {:error, :unknown_workspace}; %{"path" => path, "name" => name} -> open the path, then record_opened again to bump last_opened_at`. Read `id` out of `config/workspace.yaml` when building the `current` payload (or carry the id from create/open into state). Update `handle_continue(:auto_open, …)` to read `App.Config.last_opened_id()` and open by id.

- [ ] **Step 4: Run to verify pass** — `cd backend && mix test test/valea/workspace/manager_test.exs` → PASS.
- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/workspace/manager.ex backend/test/valea/workspace/manager_test.exs
git commit -m "feat: id-based Manager.create(name)/open(id); current carries id"
```

### Task 2.4: Workspace switch preflight

**Files:**
- Modify: `backend/lib/valea/workspace/manager.ex` (add `switch_preflight/1`)
- Test: `backend/test/valea/workspace/manager_test.exs`

**Interfaces:**
- Consumes: `Valea.Agents.list_sessions/0` (live-session detection — an entry with `status`/`live`), a dirty-editor signal if one exists server-side (else the UI supplies the dirty-edit block; document that the dirty check is frontend-owned via `onBeforeMutate`).
- Produces: `Valea.Workspace.Manager.switch_preflight(id :: String.t()) :: {:ok, %{live_sessions: [%{id, title, icm_mount}], target_id: String.t()}}` — reports live sessions that a switch would stop, so the UI can confirm before switching. Read-only; performs no teardown. (spec §"Workspace lifecycle and switching" step 2; §"API direction" `workspace_switch_preflight`.)

- [ ] **Step 1: Write the failing test** — assert that with no live sessions, `switch_preflight(other_id)` returns `{:ok, %{live_sessions: []}}`; with a live session present (start one via the fake adapter helper), the list is non-empty. (Use the Phase-2-updated `AgentCase.open_workspace!`/`start_session` helpers.)
- [ ] **Step 2: Run to verify failure** — FAIL (undefined).
- [ ] **Step 3: Implement** `switch_preflight/1`: validate the target id exists (`App.Config.workspace_by_id/1`), collect `Valea.Agents.list_sessions/0` filtered to live, map to `%{id, title, icm_mount}`, return.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: workspace switch preflight reports live sessions`.

### Task 2.5: `Valea.Api.Workspace` — id-based RPC + test-helper update + codegen

**Files:**
- Modify: `backend/lib/valea/api/workspace.ex` (rewrite actions to C9)
- Modify: `backend/test/support/agent_case.ex` (`open_workspace!` uses `Manager.create(name)`)
- Modify: `frontend/src/lib/api/ash_rpc.ts` (regenerated), and the wrapper `frontend/src/lib/api/client.ts` calls (rename to match)
- Test: `backend/test/valea/api/workspace_test.exs` (or existing)

**Interfaces:**
- Produces the C9 Workspace surface: `current_workspace` (→ `%{"open","id","name","generation"}`, **no path**), `list_workspaces` (→ recent, `%{"id","name","last_opened_at"}`, no path), `create_workspace(name, )` (no `parent_dir`), `open_workspace(id, generation)`, `workspace_switch_preflight(id)`. Remove `inspect_path`/`inspect_workspace`/`adopt_workspace` path-based actions here (adopt is deleted in Phase 11; onboarding rework is Phase 10 — for now leave those actions returning a `not_supported` error rather than deleting, to keep the frontend compiling until Phase 10, OR keep them until Phase 10 and only add the new id-based ones). Choose: **add the new id-based actions now, keep the old ones compiling but unused; delete old ones in Phase 10/11.**

- [ ] **Step 1: Write the failing test** — an Ash action test (or via `AshTypescript`/direct `Ash` call) asserting `create_workspace` takes only `name` and returns an `id`, and `open_workspace` takes `id`.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** the new actions wrapping `Manager.create/1`, `Manager.open/1`, `Manager.switch_preflight/1`, `App.Config.recent/0`. Strip `path` from every payload (`opened_payload/1` → `%{"open" => true, "id" => info.id, "name" => info.name, "generation" => Manager.generation()}`).
- [ ] **Step 4: Update the test helper** — in `agent_case.ex`, change `open_workspace!` from `Manager.create(Path.join(dir, "workspaces"), name)` to `Manager.create(name)` (the app-owned dir is derived from the isolated `VALEA_APP_DIR`). Keep the isolated-`VALEA_APP_DIR` + `on_exit` cleanup.
- [ ] **Step 5: Regenerate the client + wire the wrapper**

Run: `cd backend && mix ash_typescript.codegen`
Then update `frontend/src/lib/api/client.ts` wrappers: `createWorkspace(name)`, `openWorkspace(id)`, `getWorkspace()` (returns id), `listWorkspaces()`/`recentWorkspaces()` (id-carrying), `workspaceSwitchPreflight(id)`. Frontend components still compile against these (the id-consuming UI lands in Phase 10).

- [ ] **Step 6: Run gates + commit**

Run: `cd backend && mix test` → PASS. Run: `cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/` → clean. Run: `cd frontend && bun run check` → 0.

```bash
git add backend/lib/valea/api/workspace.ex backend/test/support/agent_case.ex backend/test/valea/api/workspace_test.exs frontend/src/lib/api/
git commit -m "feat: id-based Workspace RPC surface (create(name)/open(id)/switch-preflight) + regen client"
```

**Phase 2 exit check:** a fresh workspace lands under `~/.valea/workspaces/<slug>-<short-id>/`, is `version: 5`, has no agent-routing files or `mounts/`, and is created/opened/listed purely by id; `mix test` + `bun run check` green. ICMs don't exist yet in this workspace model — Phase 3 introduces the config-backed registry.

---

## Phase 3 — Config-backed external-only ICM registry & stable identity

**Milestone:** `Valea.Mounts` is a config-truth registry: the set of mounted ICMs is exactly the `icms:` map in `workspace.yaml` (C2), every ICM is external/by-reference, `icm.yaml` is format 2 with a *validated, workspace-unique* `id` (C3), and mount/create/enable/unmount are id- and mount-key-based RPCs that never touch ICM files. Embedded `mounts/` discovery is gone. `MOUNTS.md` is no longer generated on any registry path (the module is deleted in Phase 11; the watcher's stale regeneration is cleaned in Phase 8).

Compatibility shim to keep phases green: the `mount()` map keeps its current field set (`%{name, rel_root, root, manifest, enabled, degraded}`) but `rel_root` is now **always `nil`** (all mounts are external). Every consumer that already branches on `rel_root` (`Valea.ICM`, `References`, `Search`, `ClaudeSettings`, `Workflows`) transparently takes its external branch; the dead embedded branches are removed in Phase 11. Here, `name` is the workspace-local **mount key** (the `icms:` mapping key); `manifest.name` is the ICM display name.

### Task 3.1: `Valea.Mounts.Manifest` format 2 — stable identity

**Files:**
- Modify: `backend/lib/valea/mounts/manifest.ex`
- Test: `backend/test/valea/mounts/manifest_test.exs`

**Interfaces:**
- Produces:
  - `%Valea.Mounts.Manifest{format: 2, id: String.t(), name: String.t(), description: String.t() | nil}` (C3).
  - `Manifest.load(icm_root) :: {:ok, t()} | {:error, :missing | {:invalid, String.t()}}` — now returns `{:error, {:invalid, "id must be a UUID"}}` when `id` is absent/blank/not a UUID (the format-2 rule). `name` still required and non-blank. `format` defaults to 2 when absent but a present `format` is preserved.
  - `Manifest.render(attrs) :: String.t()` — emits `format: 2`.
  - `Manifest.write!(icm_root, attrs) :: :ok` — unchanged mechanics (atomic), emits format 2.

**Pre-flight (do this first):** the format-1 loader accepted any `id` (including absent/non-UUID); the format-2 loader rejects non-UUIDs. Before flipping the loader, `grep -rl "icm.yaml" backend/priv backend/test` and confirm every fixture/template `icm.yaml` carries a real UUID `id` (the two Valea-minted paths already do; hand-written fixtures may not). Fix any that don't in this task, or Phase 3 tests fail at load time.

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/mounts/manifest_test.exs  (add/replace)
defmodule Valea.Mounts.ManifestTest do
  use ExUnit.Case, async: true
  alias Valea.Mounts.Manifest

  defp write(root, yaml), do: (File.mkdir_p!(root); File.write!(Path.join(root, "icm.yaml"), yaml))
  defp tmp, do: Path.join(System.tmp_dir!(), "mf-#{System.unique_integer([:positive])}")

  test "loads format 2 with a valid uuid id" do
    root = tmp()
    write(root, "format: 2\nid: 6f9f0c9e-3ccd-4fa5-a219-113a70618b55\nname: \"Coaching\"\ndescription: \"x\"\n")
    assert {:ok, %Manifest{format: 2, id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55", name: "Coaching"}} = Manifest.load(root)
    on_exit(fn -> File.rm_rf!(root) end)
  end

  test "rejects a manifest with no id or a non-uuid id" do
    root = tmp()
    write(root, "format: 2\nname: \"Coaching\"\n")
    assert {:error, {:invalid, _}} = Manifest.load(root)
    write(root, "format: 2\nid: not-a-uuid\nname: \"Coaching\"\n")
    assert {:error, {:invalid, _}} = Manifest.load(root)
    on_exit(fn -> File.rm_rf!(root) end)
  end

  test "render emits format 2" do
    assert Manifest.render(%{id: "6f9f0c9e-3ccd-4fa5-a219-113a70618b55", name: "N", description: "d"}) =~ "format: 2"
  end
end
```

- [ ] **Step 2: Run to verify failure** — `cd backend && mix test test/valea/mounts/manifest_test.exs` → FAIL.

- [ ] **Step 3: Implement**

Change `defstruct` default `format: 2`. In the loader, replace the bare `Map.get(doc, "id")` with a validated fetch:

```elixir
defp fetch_id(doc) do
  case doc |> Map.get("id") |> to_string() |> String.trim() do
    "" -> {:error, {:invalid, "id is required"}}
    id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> {:ok, id}
        :error -> {:error, {:invalid, "id must be a UUID"}}
      end
  end
end
```

Thread `fetch_id/1` into `load/1` alongside the existing `fetch_name/1`. Change `render/1`'s literal `format: 1` → `format: 2`.

- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: icm.yaml format 2 with validated stable UUID identity`.

### Task 3.2: `Valea.Mounts` registry core — config truth, external-only, uniqueness

**Files:**
- Modify: `backend/lib/valea/mounts.ex` (`list/1` reads `icms:`; drop `mounts/*` glob; fold External resolution inline; add dup-id/dup-path/boundary degradation)
- Test: `backend/test/valea/mounts/mounts_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.Manifest.load/1` (C3), `Valea.Paths.resolve_real/2`, `Valea.Mounts.External.check_boundaries/2` + `validate_ref/2` (reuse until Phase 11 folds External in; call them from `Valea.Mounts`).
- Produces:
  - `Valea.Mounts.list(workspace) :: [mount()]` — one `mount()` per `icms:` entry, external-only (`rel_root: nil`), resolved from `path`, boundary-validated, manifest-loaded, with `degraded` set for any failure. Two entries resolving to the same physical root, or two healthy entries whose manifests share an `id`, are **both** degraded (`"ambiguous id …"` / `"duplicate root …"`). Sorted by `name` (mount key).
  - `Valea.Mounts.enabled(workspace) :: [mount()]` — `list/1` filtered to enabled + non-degraded (`effective?/1`, unchanged).
  - `Valea.Mounts.mount_for(workspace, path_or_locator)` — attribution by absolute-root prefix among enabled, non-degraded mounts (the external branch of today's `mount_for/2`; the embedded branch is removed).
  - `Valea.Mounts.mount_by_key(workspace, mount_key) :: mount() | nil` — direct lookup by the `icms:` key (new; used by SessionScope/Runner/RPC).
  - `Valea.Mounts.mount_by_id(workspace, icm_id) :: mount() | nil` — lookup by stable id among healthy mounts (new; used by locator resolution + related-ICM resolution).

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/mounts/mounts_test.exs  (rewrite around config-truth)
defmodule Valea.MountsTest do
  use ExUnit.Case, async: false
  alias Valea.Mounts
  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-mnt-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")
    on_exit(fn -> Manager.close(); File.rm_rf!(dir); System.delete_env("VALEA_APP_DIR") end)
    %{ws: ws.path, home: dir}
  end

  # Build a real external ICM folder with a format-2 manifest.
  defp icm!(base, name, id) do
    root = Path.join(base, name)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "icm.yaml"), "format: 2\nid: #{id}\nname: \"#{name}\"\n")
    root
  end

  defp write_icms(ws, yaml_block) do
    path = Path.join(ws, "config/workspace.yaml")
    base = File.read!(path) |> String.split("icms:") |> hd()
    File.write!(path, base <> "icms:\n" <> yaml_block)
  end

  test "an icms: entry becomes a healthy external mount", %{ws: ws, home: home} do
    root = icm!(home, "Coaching", "6f9f0c9e-3ccd-4fa5-a219-113a70618b55")
    write_icms(ws, "  coaching:\n    path: #{root}\n    enabled: true\n")
    assert [%{name: "coaching", root: ^root, rel_root: nil, degraded: nil, enabled: true} = m] = Mounts.list(ws)
    assert m.manifest.id == "6f9f0c9e-3ccd-4fa5-a219-113a70618b55"
    assert Mounts.mount_by_key(ws, "coaching").root == root
    assert Mounts.mount_by_id(ws, "6f9f0c9e-3ccd-4fa5-a219-113a70618b55").name == "coaching"
  end

  test "two entries sharing an ICM id are both degraded", %{ws: ws, home: home} do
    a = icm!(home, "A", "31201697-cff8-4d99-9dc5-b140e4178716")
    b = icm!(home, "B", "31201697-cff8-4d99-9dc5-b140e4178716")
    write_icms(ws, "  a:\n    path: #{a}\n  b:\n    path: #{b}\n")
    assert Enum.all?(Mounts.list(ws), &(&1.degraded != nil))
  end

  test "a path inside the workspace is degraded, not mounted", %{ws: ws} do
    write_icms(ws, "  bad:\n    path: #{Path.join(ws, "sources")}\n")
    assert [%{name: "bad", degraded: reason}] = Mounts.list(ws)
    assert reason =~ "inside" or reason =~ "boundary"
  end
end
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

Rewrite `list/1` to read `read_config_mounts/1`'s `icms:` map and build one external mount per entry (drop the `Path.join(workspace, "mounts/*")` glob and the `embedded ++ external` compose). Reuse the resolution/degradation machinery from `Valea.Mounts.External` (`build_from_ref`-style: expand `~`, `resolve_real`, `check_boundaries/2`, `Manifest.load/1`) — call it from `Valea.Mounts`. After building the list, run two post-passes: `degrade_duplicate_roots/1` (any resolved root appearing >1 → all such degraded) and `degrade_duplicate_ids/1` (any healthy manifest `id` appearing >1 → all such degraded). Keep `effective?/1`, `enabled/1`, `mount_for/2` (external branch only). Add `mount_by_key/2` and `mount_by_id/2`. Keep the `mount()` type with `rel_root: nil` always.

- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: config-truth external-only ICM registry with root/id uniqueness`.

### Task 3.3: `Valea.Mounts` mutations — mount/create/enable/unmount + audit

**Files:**
- Modify: `backend/lib/valea/mounts.ex` (config `icms:` writer; `mount/2`, `create/3`, `set_enabled/3`, `unmount/2`)
- Test: `backend/test/valea/mounts/mounts_mutation_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.Manifest.write!/2` (create only), `Valea.Audit.append/2`, `Valea.Paths`/boundary checks.
- Produces (all operate on the current workspace's `config/workspace.yaml` `icms:` map; none mutates an ICM except `create` which writes a fresh `icm.yaml` into a folder the user is creating):
  - `Valea.Mounts.mount(workspace, path) :: {:ok, %{mount_key, id}} | {:error, reason}` — validates the folder is a healthy format-2 ICM, boundary-checks the path, rejects duplicate physical root and duplicate id in this workspace, derives a unique mount key from the manifest name (`slugify` + de-dupe), writes `icms.<key> = %{path: <user-form>, enabled: true}`, audits `icm_mounted`. Never copies/moves.
  - `Valea.Mounts.create(workspace, name, path) :: {:ok, %{mount_key, id}} | {:error, reason}` — mints a new UUID, **seeds the portable ICM template (Task 3.5)** into the (empty/new) folder — including a fresh format-2 `icm.yaml` (`id`, `name`, `description: ""`) — then `mount/2` it. `create` is the only path that writes into an ICM. (Task 3.3 may land a minimal `Manifest.write!` skeleton first; Task 3.5 upgrades it to the full template copy.)
  - `Valea.Mounts.set_enabled(workspace, mount_key, enabled) :: :ok | {:error, reason}` — flips `icms.<key>.enabled`, audits `icm_enabled`/`icm_disabled`.
  - `Valea.Mounts.unmount(workspace, mount_key) :: {:ok, path} | {:error, reason}` — removes the `icms.<key>` entry only; folder untouched; audits `icm_unmounted`.

The `icms:` writer must preserve top-level `version`/`id`/`name` and any unknown keys and store `path` in the user's `~`-form (mirror the current `render_declare`/`render_config` YAML hand-rendering in `mounts.ex`, retargeted from a `mounts:` list of `kind: path` refs to the `icms:` map of `{path, enabled}`).

- [ ] **Step 1: Write the failing tests** — mount a healthy ICM (asserts the `icms:` entry appears and `Mounts.list` shows it healthy); mounting a second folder with the same id fails `:duplicate_id`; mounting the same path twice fails `:duplicate_root`; `create` writes a format-2 `icm.yaml` then mounts; `unmount` removes the config entry and leaves the folder intact; `set_enabled(false)` flips enabled.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** the four mutations + the `icms:` YAML writer + a `unique_mount_key/2` helper (slugify manifest name, suffix `-2`,`-3`… on collision). Audit each via `Valea.Audit.append/2`.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: ICM mount/create/enable/unmount mutations (config-only, audited)`.

### Task 3.4: `Valea.Api.Icms` RPC surface + frontend store rename + codegen

**Files:**
- Create: `backend/lib/valea/api/icms.ex` (`Valea.Api.Icms`, `type_name("Icms")`)
- Modify: `backend/lib/valea/api.ex` (register the new resource; keep `Valea.Api.Mounts` until Phase 11)
- Modify: `frontend/src/lib/api/client.ts` + `frontend/src/lib/stores/mounts.svelte.ts` (rename wrappers to `list_icms`/`mount_icm`/…)
- Modify: `frontend/src/lib/api/ash_rpc.ts` (regenerated)
- Test: `backend/test/valea/api/icms_test.exs`

**Interfaces:**
- Produces the C9 ICM-mount surface: `list_icms(generation)` (→ `%{icms: [%{mount_key, id, name, description, root, enabled, degraded}]}`), `mount_icm(path, generation)`, `create_icm(name, path, generation)`, `set_icm_enabled(mount_key, enabled, generation)`, `unmount_icm(mount_key, generation)`, `icm_doctor(mount_key, generation)`. Each guards `Manager.check_generation/1` first, resolves `Manager.current()` for the workspace, calls the corresponding `Valea.Mounts` function, and broadcasts `{:mounts_changed}` on the `"mounts"` topic after mutations. `icm_doctor` wraps the existing `Valea.Mounts.Doctor.run/1` for now (Phase 8 enriches it). `icm_tree` is added in Phase 4.

- [ ] **Step 1: Write the failing test** — call `list_icms` (empty), `create_icm("Coaching", path, gen)`, then `list_icms` shows one healthy ICM; `set_icm_enabled`/`unmount_icm` reflect through.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** `Valea.Api.Icms` mirroring `Valea.Api.Mounts`'s structure (generic `action …, :map`, `Manager.check_generation`, broadcast), delegating to the Phase-3.3 mutations. Register in `Valea.Api`.
- [ ] **Step 4: Regenerate + wire frontend** — `cd backend && mix ash_typescript.codegen`; rename `mountsStore` calls in `client.ts`/`mounts.svelte.ts` to the `*_icm(s)` names; `MountSummary` gains `mountKey`/`id` (keep `name` = display). Components consuming `mountsStore.mounts` still compile (deeper UI is Phase 9/10).
- [ ] **Step 5: Gates + commit**

Run: `cd backend && mix test`; `mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/`; `cd frontend && bun run check`.

```bash
git add backend/lib/valea/api/icms.ex backend/lib/valea/api.ex backend/test/valea/api/icms_test.exs frontend/
git commit -m "feat: Valea.Api.Icms RPC (list/mount/create/enable/unmount/doctor) + regen client"
```

### Task 3.5: Portable ICM template + `create/3` seeds it

**Files:**
- Create: `backend/priv/icm_template/` — the portable ICM starter, adapted from the current `backend/priv/workspace_template/mounts/starter/` tree (which Phase 2 deletes): `CLAUDE.md` (`@AGENTS.md` + `@CONTEXT.md` imports), `AGENTS.md` (identity/rules/folder-map skeleton with a `{{name}}` heading), `CONTEXT.md` (routing skeleton + a commented `related_icms:` frontmatter example, C4), `Workflows/Distill Decisions.md` (B's distill workflow, verbatim from the current starter), `Decisions/2026.md` (the decision-log seed), `Templates/Client.md` + `Templates/Decision.md` (C's starters, verbatim from the current `mounts/starter/Templates/`).
- Modify: `backend/lib/valea/mounts.ex` (`create/3` copies the template instead of writing only a bare `icm.yaml`)
- Test: `backend/test/valea/mounts/mounts_mutation_test.exs` (extend the `create` case)

**Interfaces:**
- Consumes: `Valea.Mounts.Manifest.write!/2`, the template dir via `Application.app_dir(:valea, "priv/icm_template")`.
- Produces: `Valea.Mounts.create(workspace, name, path)` now `cp_r`s `priv/icm_template/` into `path`, substitutes `{{name}}` in `AGENTS.md`/`CONTEXT.md`, writes a fresh format-2 `icm.yaml` (`id` = new UUID, `name`, `description: ""`) over the template placeholder, then mounts by reference. A freshly created ICM therefore carries the Distill workflow, a Decisions log, and the Client/Decision templates, so B's teach-loop and C's templates work out of the box — the "seed" half of the inject+seed decision. The portable files carry NO Valea-specific queue/proposal JSON vocabulary (that is injected per session by `SessionSettings.context/1`, Task 1.2), keeping the ICM usable by a bare harness.

- [ ] **Step 1: Build the template dir** — copy + adapt the soon-to-be-deleted `backend/priv/workspace_template/mounts/starter/` tree into `backend/priv/icm_template/`. Replace the starter's fixed name with a `{{name}}` placeholder in `AGENTS.md`/`CONTEXT.md`. Strip any content that referenced the workspace-root `AGENTS.md` proposal contract (that vocabulary moves to the injected `context.md`, Task 1.2); `CONTEXT.md` keeps only the routing skeleton + the commented `related_icms:` example.
- [ ] **Step 2: Write the failing test** — `Mounts.create(ws, "Coaching", path)` then assert `path/Workflows/Distill Decisions.md`, `path/Decisions/2026.md`, `path/Templates/Client.md`, `path/CONTEXT.md`, and a format-2 `path/icm.yaml` (real UUID, `name: "Coaching"`) all exist, and `AGENTS.md` contains "Coaching" (placeholder substituted).
- [ ] **Step 3: Run to verify failure** — FAIL.
- [ ] **Step 4: Implement** — change `create/3` to `File.cp_r!(template_dir(), path)`, substitute `{{name}}`, `Manifest.write!(path, %{id: uuid, name: name, description: ""})`, then `mount/2`.
- [ ] **Step 5: Run to verify pass** — PASS.
- [ ] **Step 6: Commit** — `feat: seed new ICMs from a portable icm_template (Distill workflow, Decisions, Templates)`.

**Phase 3 exit check:** mounting/creating an ICM writes only `workspace.yaml` `icms:` (and, for create, a seeded portable ICM at the target folder); `Mounts.list` is config truth with root/id uniqueness + boundary degradation; the ICM RPC surface is id/mount-key based; `mix test` + `bun run check` green. `MOUNTS.md` is no longer written by any registry action.

---

## Phase 4 — Stable ICM/workspace locators & containment resolution

**Milestone:** a first-class `Valea.Icm.Locator` (C5) exists and is the addressing scheme for ICM file operations, so a persisted record survives an ICM being moved: the id + ICM-relative path is stored, and the physical root is resolved from the current mount table at the I/O boundary. Knowledge page CRUD moves from raw physical paths to `(mount_key, relative_path)`.

### Task 4.1: `Valea.Icm.Locator` — type, encode, resolve, attribution

**Files:**
- Create: `backend/lib/valea/icm/locator.ex`
- Test: `backend/test/valea/icm/locator_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.mount_by_id/2`, `Valea.Mounts.mount_for/2` (attribution), `Valea.Paths.resolve_real/2`.
- Produces:
  - `Valea.Icm.Locator.icm(icm_id, rel_path) :: map()` → `%{"kind"=>"icm","icm_id"=>…,"path"=>…}`; `Valea.Icm.Locator.workspace(rel_path) :: map()` → `%{"kind"=>"workspace","path"=>…}` (C5, string keys, JSON-safe).
  - `Valea.Icm.Locator.resolve(workspace, locator) :: {:ok, physical_abs} | {:error, :icm_not_mounted | :icm_disabled | :icm_degraded | :outside | :invalid}` — ICM locator: look up `icm_id` among healthy enabled mounts, then `Paths.resolve_real(path, icm_root)`; workspace locator: `Paths.resolve_real(path, workspace)`.
  - `Valea.Icm.Locator.for_path(workspace, physical_abs) :: map()` — attributes an absolute path to a mount → ICM locator (id + root-relative path), else a workspace locator (workspace-relative). Used to snapshot locators for audit/queue (Phase 7).

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/icm/locator_test.exs
defmodule Valea.Icm.LocatorTest do
  use ExUnit.Case, async: false
  alias Valea.Icm.Locator
  alias Valea.Workspace.Manager
  alias Valea.Mounts

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-loc-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create("W")
    id = "6f9f0c9e-3ccd-4fa5-a219-113a70618b55"
    root = Path.join(dir, "coaching")
    File.mkdir_p!(Path.join(root, "Pricing"))
    File.write!(Path.join(root, "icm.yaml"), "format: 2\nid: #{id}\nname: \"Coaching\"\n")
    File.write!(Path.join(root, "Pricing/Current Pricing.md"), "# p\n")
    {:ok, _} = Mounts.mount(ws.path, root)
    on_exit(fn -> Manager.close(); File.rm_rf!(dir); System.delete_env("VALEA_APP_DIR") end)
    %{ws: ws.path, id: id, root: root}
  end

  test "resolves an icm locator to the current physical path", %{ws: ws, id: id, root: root} do
    loc = Locator.icm(id, "Pricing/Current Pricing.md")
    assert {:ok, abs} = Locator.resolve(ws, loc)
    assert abs == Path.join(root, "Pricing/Current Pricing.md")
  end

  test "icm locator for an unmounted id errors", %{ws: ws} do
    assert {:error, :icm_not_mounted} = Locator.resolve(ws, Locator.icm("00000000-0000-0000-0000-000000000000", "x.md"))
  end

  test "for_path attributes an in-ICM path to an icm locator", %{ws: ws, id: id, root: root} do
    assert %{"kind" => "icm", "icm_id" => ^id, "path" => "Pricing/Current Pricing.md"} =
             Locator.for_path(ws, Path.join(root, "Pricing/Current Pricing.md"))
  end

  test "for_path attributes a workspace path to a workspace locator", %{ws: ws} do
    assert %{"kind" => "workspace", "path" => "sources/mail/messages/42.md"} =
             Locator.for_path(ws, Path.join(ws, "sources/mail/messages/42.md"))
  end
end
```

- [ ] **Step 2: Run to verify failure** — FAIL (module undefined).
- [ ] **Step 3: Implement** `Valea.Icm.Locator` with `icm/2`, `workspace/1`, `resolve/2` (guarding `nil`/degraded/disabled before `Paths.resolve_real/2`), and `for_path/2` (try `Mounts.mount_for/2`; on a hit compute `Path.relative_to(abs, mount.root)`; else workspace-relative).
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: Valea.Icm.Locator (stable id+relative-path addressing)`.

### Task 4.2: Re-key `Valea.ICM` + `Api.ICM` page ops to `(mount_key, relative_path)`

**Files:**
- Modify: `backend/lib/valea/icm.ex` (page/save_page/create_page/create_folder/rename/delete take `mount_key` + ICM-relative path; `tree_for/1` returns one ICM's tree)
- Modify: `backend/lib/valea/api/icm.ex` (actions take `mount_key` + `path`; add `icm_tree(mount_key)`)
- Modify: `backend/lib/valea/icm/references.ex`, `backend/lib/valea/icm/search.ex`, `backend/lib/valea/icm/backlinks.ex`, `backend/lib/valea/icm/link_rewrite.ex` (mount-key/ICM-relative addressing; drop the `rel_root || root` fork — always absolute root). `backlinks.ex`/`link_rewrite.ex` also stop scanning `Mounts.enabled/1` here and scan only the single target ICM as an interim; Task 5.6 widens them to primary+related once `Mounts.Context.resolve/2` exists.
- Test: `backend/test/valea/icm_test.exs`, `backend/test/valea/api/icm_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.mount_by_key/2`, `Valea.Icm.Locator`, `Valea.Paths.resolve_real/2`.
- Produces:
  - `Valea.ICM.tree_for(mount_key) :: {:ok, %{mount_key, title, tree}} | {:error, …}` — one ICM's tree (nodes carry ICM-relative `path`). The old `tree/0` (all mounts grouped) is replaced by per-ICM `tree_for/1`; the sidebar no longer needs the grouped union (Phase 9).
  - `Valea.ICM.page(mount_key, rel_path)`, `save_page(mount_key, rel_path, pm, base_hash)`, `create_page(mount_key, parent_rel, name)`, `create_folder(mount_key, parent_rel, name)`, `rename(mount_key, rel_path, new_name)`, `delete(mount_key, rel_path)` — each resolves the mount root via `mount_by_key/2` then contains via `Paths.resolve_real(rel_path, root)`. Containment logic (`contain/2`) is unchanged except the base becomes the ICM root directly (no `mounts/<name>` prefix handling).
  - `Valea.Api.ICM` actions gain a `mount_key` argument alongside `path` (ICM-relative), plus `icm_tree(mount_key, generation)`.

- [ ] **Step 1: Write the failing tests** — via a mounted ICM (as in 4.1 setup): `ICM.page("coaching", "Pricing/Current Pricing.md")` returns the page; `save_page` round-trips with a base hash; `tree_for("coaching")` lists `Pricing/` with an ICM-relative path; `create_page`/`rename`/`delete` operate ICM-relative; a `..` escape is denied.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** the re-keyed `Valea.ICM` functions (collapse the `mount_relative`/`to_workspace_rel` dual-clauses to the single absolute-root case), `tree_for/1`, and the `Api.ICM` action arg changes + `icm_tree`. Update `References`/`Search`/`Backlinks`/`LinkRewrite` to address by mount root directly (single-ICM scan for now).
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: re-key ICM page ops to (mount_key, relative_path) + icm_tree`.

### Task 4.3: Minimal frontend adaptation to the re-keyed ICM RPC

**Files:**
- Modify: `frontend/src/lib/api/client.ts` (page-op wrappers take `mountKey` + `path`; `icmTree(mountKey)`)
- Modify: `frontend/src/lib/stores/icm.svelte.ts` (`groups` carry `mountKey`; refetch per mount or aggregate)
- Modify: `frontend/src/lib/shell/nav.ts` (`icmToNav`/`flattenMountGroups` produce hrefs carrying the mount key)
- Modify: `frontend/src/lib/api/ash_rpc.ts` (regenerated)
- Test: `frontend/src/lib/shell/nav.test.ts` (if present) + affected Vitest

**Interfaces:**
- Keep the current Knowledge routes working (`/knowledge`, `/knowledge/[...path]`) by threading `mountKey` through node hrefs (e.g. `/knowledge/<mountKey>/<rel>`), so `bun run check`/`bun run test` pass. The full tree-in-list-pane + ICM switching UX is Phase 9; this task is the minimum to stay green after the backend signature change.

- [ ] **Step 1: Regenerate + adapt** — `cd backend && mix ash_typescript.codegen`; update the wrappers + store + nav transform; fix any `bun run check` type errors.
- [ ] **Step 2: Run gates** — `cd frontend && bun run check` (0), `bun run test` (green), `git diff --exit-code ../frontend/src/lib/api/` after codegen (clean/committed).
- [ ] **Step 3: Commit** — `chore: adapt frontend ICM addressing to (mountKey, path) + regen client`.

### Task 4.4: Re-key image upload/serve to `mount_key` + confirm the Assets/ stance

**Files:**
- Modify: `backend/lib/valea_web/controllers/files_controller.ex` (upload resolves the target ICM by `mount_key` + ICM-relative `page_path` instead of attributing a raw path; serve resolves the same way)
- Modify: `frontend/src/lib/editor/image-upload.ts` call site (send `mountKey`) — the path-vocabulary rewrite of this module is Task 9.6; here only the upload request gains `mountKey`
- Test: `backend/test/valea_web/files_controller_test.exs` (or the existing controller test)

**Interfaces:**
- Consumes: `Valea.Mounts.mount_by_key/2`, `Valea.Paths.resolve_real/2`.
- Produces: `POST /files/upload` takes `mount_key` + an ICM-relative `page_path`, resolves the mount root via `mount_by_key/2`, and writes the pasted image to `<icm_root>/Assets/<slug>-<hash8>.ext` (unchanged destination), contained by `resolve_real/2`. `GET /files/raw` resolves the same way. **Stance (locked in this review):** a user-pasted image is *user content the user asked to store in their own note*, not a Valea-generated runtime/settings artifact, so writing it into the external ICM's `Assets/` does not violate invariant 9 (which targets Valea's own logs/settings/db). The upload endpoint is driven by an explicit human paste/drop in the editor — the human is the approver — so it correctly does NOT pass through the agent `PermissionPolicy` ask-gate (that gate governs the *agent's* writes, spec §"Managed harness settings"). Document this asymmetry in the controller moduledoc so it is a stated decision, not an oversight.

- [ ] **Step 1: Write the failing test** — upload an image with `mount_key: "coaching"` + `page_path: "Notes/x.md"`; assert the file lands under `<coaching_root>/Assets/` and `GET /files/raw` serves it with `content-type` + `content-disposition: inline` + `x-content-type-options: nosniff`; a `mount_key` that isn't mounted → error; a `page_path` escaping the ICM → rejected.
- [ ] **Step 2: Run to verify failure** — FAIL (endpoint still attributes a raw path).
- [ ] **Step 3: Implement** — replace the `MemoryProposal.check_target/2` attribution with `mount_by_key/2` + `resolve_real/2`; add the stance moduledoc; keep the token-gated upload / token-exempt serve split and the atomic write.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: image upload/serve keyed by mount_key; document the Assets/ user-content stance`.

**Phase 4 exit check:** ICM files are addressed by `(mount_key, ICM-relative path)` end to end; `Valea.Icm.Locator` resolves id+path against the live mount table and attributes physical paths back to locators; image upload/serve is mount-key-keyed with a documented stance; suite green. Persisted records still store raw paths — Phase 7 moves queue/audit onto locators.

---

## Phase 5 — Session-scope resolver & permission-policy root split

**Milestone:** every session launches *inside its primary ICM*: `SessionScope.resolve/1` (C6) is the single authority that validates the primary ICM + resolves direct related ICMs (C4) + computes absolute read/write roots + materializes the managed settings/context (C7), `PermissionPolicy` splits `workspace_root` (protected state) from `cwd` (relative base = primary ICM root) from `read_roots` (absolute: primary + related + exact inputs), and `SessionServer`/`ProcessRuntime`/`Acp.Connection` run the subprocess with **cwd == the primary ICM's physical root**. `create_session` now requires a `mount_key`. The managed settings live under `<workspace>/runtime/sessions/<id>/`, never in the ICM.

Minor resequencing vs. the spec: this phase lands the `create_session(kind, mount_key, generation)` entry point (a session cannot launch without a primary ICM) and a minimal workflow scope so both `SessionServer` callers compile; Phase 6 enriches session *metadata* identity + grouped listing + follow-up, and Phase 7 does the workflow exact-grant + locator work.

### Task 5.1: `Valea.Mounts.Context` — related-ICM resolution from `CONTEXT.md`

**Files:**
- Create: `backend/lib/valea/mounts/context.ex`
- Test: `backend/test/valea/mounts/context_test.exs`

**Interfaces:**
- Consumes: `Valea.ICM.split_frontmatter/1` (or `Valea.Yaml`), `Valea.Mounts.mount_by_id/2`, `Valea.Paths.resolve_real/2`.
- Produces: `Valea.Mounts.Context.resolve(workspace, primary_mount) :: %{related: [resolved], issues: [issue]}` where `resolved = %{mount_key, id, root, entrypoint, manifest}` for each declared, enabled, healthy, non-escaping related ICM (C4), and `issue = %{id, name, reason}` (`:not_mounted | :disabled | :degraded | :duplicate_id | :entrypoint_escapes`) for the rest. Reads `<primary_mount.root>/CONTEXT.md` frontmatter `format: 1`, `related_icms: [{id, name, entrypoint}]`; missing `CONTEXT.md` or absent `related_icms` → `%{related: [], issues: []}`. Direct-only (no recursion), so cyclic declarations are inert.

- [ ] **Step 1: Write the failing tests** — with two mounted healthy ICMs where the primary's `CONTEXT.md` declares the other by id: `resolve/2` returns one `related` with the correct root + default `entrypoint: "CONTEXT.md"`. When the declared id isn't mounted: empty `related`, one `issue` with `reason: :not_mounted`. When `entrypoint` contains `../escape`: `reason: :entrypoint_escapes`.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — read/parse frontmatter; for each entry resolve `mount_by_id`, check enabled+`degraded==nil`, resolve the entrypoint via `Paths.resolve_real(entrypoint, root)` (must stay inside root), collect resolved vs issues.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: related-ICM resolution from CONTEXT.md frontmatter`.

### Task 5.2: `Valea.Agents.SessionScope.resolve/1` — the launch object

**Files:**
- Create: `backend/lib/valea/agents/session_scope.ex`
- Test: `backend/test/valea/agents/session_scope_test.exs`

**Interfaces:**
- Consumes: `Valea.Workspace.Manager.check_generation/1` + `current/0`, `Valea.Mounts.mount_by_key/2`, `Valea.Mounts.Context.resolve/2`, the session's harness adapter via the `Valea.Harness` behaviour (`Valea.Harnesses.ClaudeCode.launch/2`, which materializes `context.md` and computes the in-memory `managed_settings` posture JSON).
- Produces: `Valea.Agents.SessionScope.resolve(opts) :: {:ok, scope :: map()} | {:error, reason}` where `opts = %{kind, mount_key, generation, session_id, read_paths \\ [], write_paths \\ [], write_roots \\ []}` and `scope` is the C6 launch object. It: guards generation; resolves the workspace; looks up + validates the primary ICM (`{:error, :icm_unavailable}` if missing/disabled/degraded); resolves direct related ICMs (issues are attached as `scope.context_issues` for the UI/doctor — a chat proceeds with a degraded-context warning, a workflow's required-input check is Phase 7); computes `cwd = primary.root`, `managed_context` under `<workspace>/runtime/sessions/<session_id>/` (the posture is rendered in-memory by the harness, not written to disk); invokes the harness adapter (`Valea.Harness.launch/2`) to materialize context + return launch directives; returns the scope. This is the ONLY place these rules live (spec §"Introduce session-scope resolution").

- [ ] **Step 1: Write the failing tests** — with a mounted primary ICM: `resolve(%{kind: "chat", mount_key: "coaching", generation: g, session_id: "s1"})` returns a scope with `cwd == primary root`, `workspace.root == workspace`, a materialized `context.md` under `runtime/sessions/s1/` (and no `settings.json` on disk — the posture is in-memory), and `read_paths == []`. A stale generation → `{:error, :workspace_changed}`. An unknown/disabled mount_key → `{:error, :icm_unavailable}`. A declared related ICM appears in `scope.related_icms`.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** `resolve/1` per the interface; assemble the C6 map; call `SessionSettings.materialize!/1`.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: SessionScope.resolve builds the primary-ICM launch object`.

### Task 5.3: `Valea.Agents.PermissionPolicy` — workspace_root / cwd / read_roots split

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex`
- Test: `backend/test/valea/agents/permission_policy_test.exs`

**Interfaces:**
- Consumes: `Valea.Paths.resolve_real/2`.
- Produces: `PermissionPolicy.decide(item, ctx) :: :ask | {:allow, kind} | {:deny, kind}` where `ctx` now carries: `workspace_root` (absolute; protects operational state), `cwd` (absolute primary ICM root; base for *relative* candidate paths), `read_roots` (absolute list: primary root + related roots + exact task inputs), `session_kind`, `write_paths` (absolute), `write_roots` (absolute). The old `ctx.workspace` / `ctx.read_roots`(ws-relative) / `ctx.extra_roots` are replaced. Decision order (deny→allow→ask, unclassifiable=ask):
  1. **Deny** if any resolved candidate is inside a protected workspace dir (`<workspace_root>/{logs,config,secrets,runtime,.git}` or `<workspace_root>/app.sqlite*`), or the tool is `WebFetch`/`WebSearch`.
  2. **Deny** (symlink escape) if any raw candidate resolves outside every `read_root` and every write grant.
  3. **Allow read** if `kind ∈ read_kinds` and every candidate resolves inside some `read_root`.
  4. **Allow write** if `kind ∈ write_kinds` and `session_kind == "workflow"` and every candidate is in `write_paths` or under a `write_root`.
  5. Else **ask**.

Relative candidates resolve against **`cwd`** (was `workspace`) — this is the behavioral heart of the split. `read_roots` are absolute, so membership is `resolved == root or starts_with?(resolved <> "/", root <> "/")`.

- [ ] **Step 1: Write the failing tests**

```elixir
# backend/test/valea/agents/permission_policy_test.exs  (rewrite around the split)
defmodule Valea.Agents.PermissionPolicyTest do
  use ExUnit.Case, async: true
  alias Valea.Agents.PermissionPolicy, as: P

  setup do
    tmp = Path.join(System.tmp_dir!(), "pp-#{System.unique_integer([:positive])}")
    ws = Path.join(tmp, "ws"); icm = Path.join(tmp, "icm"); rel = Path.join(tmp, "related")
    for d <- [Path.join(ws, "logs"), Path.join(ws, "secrets"), icm, rel, Path.join(ws, "sources")], do: File.mkdir_p!(d)
    File.write!(Path.join(icm, "AGENTS.md"), "x")
    File.write!(Path.join(rel, "CONTEXT.md"), "x")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{ctx: %{workspace_root: ws, cwd: icm, read_roots: [icm, rel], session_kind: "chat", write_paths: [], write_roots: []}, ws: ws, icm: icm, rel: rel}
  end

  defp read(path), do: %{"rawInput" => %{"file_path" => path}, "toolName" => "Read", "kind" => "read"}
  defp write(path), do: %{"rawInput" => %{"file_path" => path}, "toolName" => "Write", "kind" => "write"}

  test "relative read resolves against the primary ICM cwd, not the workspace", %{ctx: ctx} do
    assert {:allow, _} = P.decide(read("AGENTS.md"), ctx)   # resolves under cwd == icm
  end

  test "reads in a related root are allowed", %{ctx: ctx, rel: rel} do
    assert {:allow, _} = P.decide(read(Path.join(rel, "CONTEXT.md")), ctx)
  end

  test "workspace operational state is denied", %{ctx: ctx, ws: ws} do
    assert {:deny, _} = P.decide(read(Path.join(ws, "logs/audit.jsonl")), ctx)
    assert {:deny, _} = P.decide(read(Path.join(ws, "secrets/x")), ctx)
  end

  test "reading the workspace sources is not auto-allowed for a chat", %{ctx: ctx, ws: ws} do
    assert :ask = P.decide(read(Path.join(ws, "sources/mail/messages/1.md")), ctx)
  end

  test "chat writes ask; workflow writes to an exact grant allow", %{ctx: ctx, icm: icm} do
    assert :ask = P.decide(write(Path.join(icm, "Pricing/x.md")), ctx)
    grant = %{ctx | session_kind: "workflow", write_paths: [Path.join(icm, "out.json")]}
    assert {:allow, _} = P.decide(write(Path.join(icm, "out.json")), grant)
  end

  test "a related root that is not granted is denied on symlink escape", %{ctx: ctx} do
    assert {:deny, _} = P.decide(read("/etc/passwd"), ctx)
  end

  test "root instruction files resolve against the primary ICM cwd, not the workspace", %{ctx: ctx} do
    assert {:allow, _} = P.decide(read("CLAUDE.md"), ctx)   # @root_files, now cwd == ICM-relative
  end
end
```

- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** the split. Replace `base_real(ctx.workspace)` with `base_real(ctx.workspace_root)` for the deny checks and `base_real(ctx.cwd)` for relative candidate resolution; make `read_roots` absolute-set membership; keep `Paths.resolve_real/2` + segment-boundary. Protected-dir list `~w(logs config secrets runtime .git)` under `workspace_root`.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: PermissionPolicy splits workspace_root / cwd / read_roots`.

### Task 5.4: `SessionServer` runs inside the primary ICM (cwd = ICM root)

**Files:**
- Modify: `backend/lib/valea/agents/session_server.ex` (`init/1`: consume a `scope`; process + ACP cwd = `scope.cwd`; wire managed settings/related roots; transcript under `scope.workspace.root`; policy_ctx = split shape)
- Modify: `backend/lib/valea/agents.ex` (`start_session/1` accepts a `scope`)
- Modify: `backend/test/support/agent_case.ex` (`start_session/3` builds a scope via `SessionScope` for a mounted ICM)
- Test: `backend/test/valea/agents/session_server_test.exs`

**Interfaces:**
- Consumes: the C6 `scope` from `SessionScope.resolve/1`.
- Produces: a session whose subprocess cwd (`ProcessRuntime.start(%{cd: scope.cwd})`) and ACP cwd (`Connection.new(%{cwd: scope.cwd, additional_roots: directives.additional_roots, managed_settings: directives.managed_settings})`, from the harness `launch/2` directives) are the primary ICM root; the transcript stays at `<scope.workspace.root>/logs/sessions/<id>.jsonl`; `policy_ctx = %{workspace_root: scope.workspace.root, cwd: scope.cwd, read_roots: [scope.primary_icm.root | related roots ++ scope.read_paths], session_kind: scope.kind, write_paths: scope.write_paths, write_roots: scope.write_roots}` — this `policy_ctx`, applied by `PermissionPolicy` on the ACP `request_permission` callback, is the authoritative enforcement (the settings file, when present, is only a pre-filter). The `ClaudeSettings.write!(workspace)` call is removed from `init/1`. `default_read_roots/1`/`default_extra_roots/1` are removed (the scope provides absolute read roots).

- [ ] **Step 1: Write/adjust the failing tests** — using `AgentCase` with a mounted ICM: after starting a session, assert (via the fake adapter's recorded launch) that the process cwd and ACP `session/new` `cwd` equal the primary ICM root (not the workspace); assert the fake adapter received the related root via `additionalDirectories` and the in-memory `managedSettings` posture; assert a relative `Read(AGENTS.md)` is allowed via the callback (resolves under the ICM) while `Read(<workspace>/sources/…)` is `:ask`.
- [ ] **Step 2: Run to verify failure** — FAIL (cwd is still the workspace).
- [ ] **Step 3: Implement** — change `init/1` to destructure `scope` from opts; set `cd: scope.cwd` and `cwd: scope.cwd`; build the split `policy_ctx`; obtain launch directives from the harness (`Valea.Harnesses.ClaudeCode.launch/2`) and pass `additional_roots`/`managed_settings` into `Connection.new/1`; keep transcript path anchored to `scope.workspace.root`; drop `ClaudeSettings.write!` and the `default_*_roots` helpers. Update `AgentCase.start_session/3` to `SessionScope.resolve/1` a scope for the given mounted ICM and pass it.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: SessionServer launches with cwd = primary ICM root + managed settings`.

### Task 5.5: `create_session(kind, mount_key, generation)` + minimal workflow scope

**Files:**
- Modify: `backend/lib/valea/api/agents.ex` (`create_session` takes `mount_key`; builds a scope via `SessionScope`)
- Modify: `backend/lib/valea/workflows/runner.ex:490-517` (`start_run` builds a scope via `SessionScope`; owning ICM = primary)
- Modify: `frontend/src/lib/api/client.ts` + `frontend/src/routes/chat/+page.svelte` (`createAgentSession(mountKey, generation)`)
- Modify: `frontend/src/lib/api/ash_rpc.ts` (regenerated)
- Test: `backend/test/valea/api/agents_test.exs`, `backend/test/valea/workflows/runner_test.exs`

**Interfaces:**
- Produces: `create_session(kind, mount_key, generation)` → resolves a scope via `SessionScope.resolve/1` (returning `:icm_unavailable` etc. as RPC errors) and starts the session. The Runner's `start_run` derives its scope from the workflow's owning ICM (the mount that owns the `Workflows/<file>.md`) as the primary ICM — so the workflow session's cwd is that ICM (spec §"Workflow session": no model/user choice after the workflow is selected). Full workflow input/grant/locator work is Phase 7; here `start_run` passes `write_paths: [staging_abs]`, `write_roots: [proposals dir]`, `read_paths: []` and the owning mount_key.

- [ ] **Step 1: Write the failing tests** — `create_session("chat", "coaching", gen)` starts a session whose scope cwd is the coaching ICM; `create_session("chat", "nope", gen)` → `icm_unavailable`; a workflow run's session cwd equals the owning ICM root.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — `create_session` gains `argument :mount_key`; call `SessionScope.resolve(%{kind: kind, mount_key: mount_key, generation: generation, session_id: <generated id>})`. To thread the generated id, generate it in `Valea.Agents.start_session` and let `SessionScope` run there, OR resolve the scope in the RPC with a pre-generated id and pass the scope into `start_session`. Choose one and keep it consistent (recommend: RPC generates id → resolves scope → `start_session(scope)`). Update Runner's `start_run` to resolve a workflow scope from the owning mount key.
- [ ] **Step 4: Regenerate + wire frontend** — `mix ash_typescript.codegen`; `chat/+page.svelte startSession()` passes the selected ICM's `mountKey` (for now, until Phase 9's sidebar `+` supplies it, default to the first enabled ICM or the `?icm=` query). Keep `bun run check` green.
- [ ] **Step 5: Gates + commit**

Run: `cd backend && mix test`; `mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/`; `cd frontend && bun run check`.

```bash
git add backend/lib/valea/api/agents.ex backend/lib/valea/workflows/runner.ex backend/test/ frontend/
git commit -m "feat: create_session(kind, mount_key) launches inside the primary ICM"
```

### Task 5.6: Scope search / backlinks / rename-rewrite to primary + related ICMs

**Files:**
- Modify: `backend/lib/valea/icm/search.ex` (`search` takes a primary `mount_key`; scans primary + related roots, not all enabled mounts)
- Modify: `backend/lib/valea/icm/backlinks.ex` (`backlinks` scans primary + related roots)
- Modify: `backend/lib/valea/icm/link_rewrite.ex` (`rewrite_all` on rename scans primary + related roots)
- Modify: `backend/lib/valea/icm.ex` (`rename/2` passes the primary mount_key into `LinkRewrite`), `backend/lib/valea/api/icm.ex` (`icm_search(query, mount_key, …)`, `references(mount_key, path)` carry the primary ICM)
- Modify: `frontend/src/lib/api/client.ts` + regen (thread `mountKey`; full palette/panel wiring is Task 9.6)
- Test: `backend/test/valea/icm/search_test.exs`, `backlinks_test.exs`, `link_rewrite_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.mount_by_key/2`, `Valea.Mounts.Context.resolve/2` (Task 5.1 — the primary's declared related ICMs).
- Produces: a shared `scoped_roots(workspace, mount_key) :: [root]` = `[primary.root | Context.resolve(workspace, primary).related |> Enum.map(& &1.root)]`. `Search.search`, `Backlinks.backlinks`, and `LinkRewrite.rewrite_all` operate over exactly this set instead of `Mounts.enabled(workspace)`. This makes editor-time cross-ICM reach match the session context boundary (decision (b) of this review): a rename in ICM A no longer silently rewrites links in an unrelated mounted ICM B; it reaches B only if A's `CONTEXT.md` declares B related. Workflow-reference rewrite (`References`) stays single-ICM (unchanged).

- [ ] **Step 1: Write the failing tests** — with three mounted ICMs A, B, C where A's `CONTEXT.md` declares B related: `Search.search(ws, q, "A")` returns hits from A and B but never C; `Backlinks.backlinks(ws, "A", page)` includes an inbound link authored in B, excludes one in C; renaming a page in A rewrites a confirmed link in B and leaves C untouched.
- [ ] **Step 2: Run to verify failure** — FAIL (today all three scan every enabled mount).
- [ ] **Step 3: Implement** — add `scoped_roots/2` (in `Valea.Mounts` or a shared helper); replace the `Mounts.enabled/1` iteration in all three modules with it; thread `mount_key` through the RPCs.
- [ ] **Step 4: Regenerate + gates** — codegen; `bun run check`/`bun run test`.
- [ ] **Step 5: Commit** — `feat: scope search/backlinks/rename-rewrite to the primary ICM + its related ICMs`.

**Phase 5 exit check:** a chat or workflow session's process + ACP cwd is the primary ICM's physical root; the workspace is not an ancestor of the cwd; managed settings/context are materialized under the hidden workspace and never in the ICM; the permission policy resolves relative paths against the ICM and denies workspace state; `mix test` + `bun run check` green. This is the point at which the core invariants (1, 4, 5) hold at runtime.

---

## Phase 6 — ICM-scoped session metadata, replay & grouped recent listing

**Milestone:** every transcript's line-1 metadata is `session/v1` with the workspace + ICM identity snapshot (C8), the backend exposes a grouped recent-session listing (≤5 per ICM, live first) for the sidebar and a full per-ICM history, and a follow-up session inherits the original's workspace + primary ICM (refusing when that ICM is no longer mounted).

### Task 6.1: `session/v1` metadata carries workspace + ICM identity

**Files:**
- Modify: `backend/lib/valea/agents/session_server.ex:423-445` (`open_transcript/1` writes the C8 fields from `scope`)
- Modify: `backend/lib/valea/agents.ex:120-187` (`list_sessions/0` reads the new fields)
- Test: `backend/test/valea/agents/session_server_test.exs`

**Interfaces:**
- Produces: transcript line 1 = C8 (`schema: "session/v1"`, `workspace_id`, `workspace_name`, `icm_mount`, `icm_id`, `icm_name`, `icm_root`, `kind`, `workflow`, `run_id`, `title`, `harness`, `generation`, `started_at`, `acp_session_id`). `Valea.Agents.list_sessions/0` returns these fields per session (so the grouped listing can key by `icm_mount`).

- [ ] **Step 1: Write the failing test** — start a session for a mounted ICM; read the transcript's first line; assert it contains `workspace_id`, `icm_mount`, `icm_id`, `icm_name`, `icm_root` matching the scope, and `schema == "session/v1"`.
- [ ] **Step 2: Run to verify failure** — FAIL (fields absent today).
- [ ] **Step 3: Implement** — build the meta map from `scope` in `open_transcript/1`; extend `list_sessions/0`'s per-file projection with the ICM fields.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: session/v1 metadata snapshots workspace + ICM identity`.

### Task 6.2: Grouped recent listing + per-ICM history RPCs

**Files:**
- Modify: `backend/lib/valea/agents.ex` (add `list_recent_sessions_by_icm/1`, `list_sessions_for/2`)
- Modify: `backend/lib/valea/api/agents.ex` (add `list_recent_sessions_by_icm`, `list_sessions(mount_key, cursor)` actions)
- Modify: `frontend/src/lib/api/client.ts`, `frontend/src/lib/api/ash_rpc.ts` (regenerated)
- Test: `backend/test/valea/agents_test.exs`, `backend/test/valea/api/agents_test.exs`

**Interfaces:**
- Produces:
  - `Valea.Agents.list_recent_sessions_by_icm(limit \\ 5) :: [%{mount_key, icm_name, sessions: [summary]}]` — groups sessions by `icm_mount`, at most `limit` per group, **live sessions first then newest ended** (spec §"ICM group behavior"). Groups ordered by workspace `icms:` config order. `summary = %{id, kind, title, workflow, run_id, started_at, status, live}`.
  - `Valea.Agents.list_sessions_for(mount_key, cursor) :: %{sessions: [summary], next_cursor}` — full filtered history for one ICM (paged).
  - RPC `list_recent_sessions_by_icm(limit: 5)` (C9) and `list_sessions(mount_key, cursor)`.

- [ ] **Step 1: Write the failing tests** — create several sessions across two mounted ICMs (some live via the fake adapter, some ended via `kill_session`); assert `list_recent_sessions_by_icm(5)` returns one group per ICM, ≤5 each, live before ended, newest-ended ordering; `list_sessions_for("coaching", nil)` returns only coaching sessions.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — scan `logs/sessions/*.jsonl` line-1 metadata, determine `live` via the Registry (a live `SessionServer` for the id), group + sort + cap; expose both RPCs.
- [ ] **Step 4: Regenerate + wire wrappers** — `mix ash_typescript.codegen`; add `listRecentSessionsByIcm`/`listSessionsFor` to `client.ts`. (Sidebar consumption is Phase 9.)
- [ ] **Step 5: Gates + commit** — tests + codegen diff + `bun run check`; `feat: grouped-by-ICM recent sessions + per-ICM history RPCs`.

### Task 6.3: `create_follow_up(session_id)` inherits the primary ICM

**Files:**
- Modify: `backend/lib/valea/agents.ex` (add `create_follow_up/2`)
- Modify: `backend/lib/valea/api/agents.ex` (add `create_follow_up` action)
- Modify: `frontend/src/lib/api/client.ts`, `frontend/src/lib/api/ash_rpc.ts` (regenerated)
- Test: `backend/test/valea/agents_test.exs`

**Interfaces:**
- Produces: `Valea.Agents.create_follow_up(session_id, generation) :: {:ok, %{id}} | {:error, :original_not_found | :icm_unavailable | :workspace_changed}` — reads the original transcript's `icm_mount`, resolves a fresh scope via `SessionScope.resolve/1` for that `mount_key`, starts a new session. When the ICM is no longer mounted/healthy, returns `:icm_unavailable` (the original transcript stays viewable; the UI shows a repair action — spec §"Session persistence"). RPC `create_follow_up(session_id, generation)` (C9).

- [ ] **Step 1: Write the failing test** — follow-up of a coaching session starts a new session with the same `icm_mount`; after `unmount_icm("coaching")`, follow-up returns `:icm_unavailable`.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** `create_follow_up/2` + the RPC action + wrapper.
- [ ] **Step 4: Regenerate + gates** — codegen diff clean, `bun run check`.
- [ ] **Step 5: Commit** — `feat: create_follow_up inherits primary ICM, refuses when unmounted`.

**Phase 6 exit check:** transcripts carry full workspace + ICM identity; the sidebar has a grouped-by-ICM recent-session feed (≤5, live-first) and per-ICM history to consume in Phase 9; follow-ups inherit the ICM and degrade gracefully; suite green.

---

## Phase 7 — Workflow ownership, exact Layer-4 grants & locator-keyed queue/audit

**Milestone:** a workflow is identified by `{icm_id, relative_path}`, its run is launched with the owning ICM as primary (cwd) and only the exact input + staging paths granted, and persisted records (queue memory targets, audit entries) carry stable locators (C5) resolved at approval/read time. `run_workflow(mount_key, relative_path, input_locator, generation)` derives the scope server-side; the client never sends a cwd.

### Task 7.1: Workflow registry keyed by `{icm_id, relative_path}`

**Files:**
- Modify: `backend/lib/valea/workflows.ex` (registry entries carry `{icm_id, mount_key, relative_path, resolved_path, name, …}`; `get/1` → `get(mount_key, relative_path)`)
- Modify: `backend/lib/valea/api/agents.ex` (`list_workflows` returns the new fields)
- Modify: `frontend/src/lib/api/client.ts`, `frontend/src/lib/api/ash_rpc.ts` (regenerated), workflow catalog UI call sites
- Test: `backend/test/valea/workflows_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.enabled/1` (each carries `manifest.id`), `Valea.Icm.Locator`.
- Produces:
  - `Valea.Workflows.list(workspace) :: [%{icm_id, mount_key, relative_path, resolved_path, name, description, enabled, trigger, sources, risk_level, approval, steps_preview}]` — union of `Workflows/*.md` across enabled healthy mounts; `relative_path` is ICM-relative (`Workflows/<file>.md`); `resolved_path` is the current absolute path; identity = `{icm_id, relative_path}`.
  - `Valea.Workflows.get(mount_key, relative_path) :: {:ok, entry} | {:error, :not_found | :not_in_icm}` — validates the mount owns the workflow (path stays inside the mount's `Workflows/`).
  - `list_workflows` RPC returns the new shape; each card carries ICM provenance and launching it is ICM-scoped (spec §"Workspace-wide views").

- [ ] **Step 1: Write the failing tests** — a mounted ICM with `Workflows/New Inquiry Triage.md`: `list/1` returns an entry with `icm_id` = the manifest id, `mount_key`, `relative_path == "Workflows/New Inquiry Triage.md"`, `resolved_path` absolute; `get("coaching", "Workflows/New Inquiry Triage.md")` resolves; `get("coaching", "Workflows/../icm.yaml")` → `:not_in_icm`.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — replace `workflow_path/2` keying with `icm_id`+`relative_path` (compute `relative_path = Path.relative_to(abs, mount.root)`); add `resolved_path`; rewrite `get/1`→`get/2` using `Mounts.mount_by_key/2` + `Workflows/` containment. Keep `triage_path`/`distill_path` as `{mount_key, relative_path}` lookups.
- [ ] **Step 4: Regenerate + gates** — codegen; update the workflow catalog call sites; `bun run check`.
- [ ] **Step 5: Commit** — `feat: workflow registry keyed by {icm_id, relative_path} with provenance`.

### Task 7.2: `run_workflow(mount_key, relative_path, input_locator)` with exact grants

**Files:**
- Modify: `backend/lib/valea/workflows/runner.ex` (`run/3` takes mount_key + relative_path + input_locator; scope via `SessionScope` with exact input read grant + staging write grants)
- Modify: `backend/lib/valea/api/agents.ex` (`run_workflow` action signature)
- Modify: `frontend` catalog launch call sites + codegen
- Test: `backend/test/valea/workflows/runner_test.exs`

**Interfaces:**
- Consumes: `Valea.Workflows.get/2`, `Valea.Icm.Locator.resolve/2` (input locator → absolute), `Valea.Agents.SessionScope.resolve/1`.
- Produces: `Valea.Workflows.Runner.run(mount_key, relative_path, input_locator, generation) :: {:ok, %{run_id, session_id}} | {:error, reason}` — validates workflow ownership; resolves the input locator (ICM-relative or a workspace source) to an absolute path, failing preflight (`:input_unavailable`) if it can't resolve or a required related ICM is missing (spec §"Related ICMs"); builds the scope via `SessionScope.resolve(%{kind: "workflow", mount_key: mount_key, generation: generation, session_id: id, read_paths: [input_abs], write_paths: [staging_proposal_abs], write_roots: [staging_proposals_dir]})`; keeps the server-owned run id/hashes/sidecar/finalize/audit. The agent proposes only at the exact granted paths. `run_generated/3` (distill) similarly writes the generated input into staging first, then grants it. `run_workflow(mount_key, relative_path, input_locator, generation)` RPC (C9); the client sends no cwd. **The run sidecar (`run.json`) additionally records `icm_id`, `mount_key`, and `icm_root`** so that `finalize/2` — a pure function of `(run_id, workspace)` invoked from both `on_turn_end` and crash recovery — can turn the agent's ICM-relative proposal `target_path` into an ICM locator (Task 7.3) and classify its risk (Task 7.5) without re-deriving the owning ICM. Add a test asserting the sidecar carries `icm_id`/`mount_key`/`icm_root`.

- [ ] **Step 1: Write the failing tests** — run a workflow with a workspace-source `input_locator` (`%{"kind"=>"workspace","path"=>"sources/mail/messages/1.md"}`): the session cwd is the owning ICM, the input abs path is in the scope's `read_paths`, and the staging proposal path is the only write grant; a generic chat in the same ICM cannot read that source (regression assertion). An `input_locator` whose ICM is unmounted → `:input_unavailable` before any subprocess spawns.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — rewrite `run/2`→`run/4` (or add `run/4` and delete `run/2`); resolve input via `Locator.resolve/2`; thread the grants into `SessionScope.resolve/1`; preserve `start_run`'s sidecar/finalize/`on_turn_end`. Update the RPC + catalog call sites.
- [ ] **Step 4: Regenerate + gates** — codegen; `bun run check`.
- [ ] **Step 5: Commit** — `feat: run_workflow scoped to owning ICM with exact input + staging grants`.

### Task 7.3: Queue memory-update targets as ICM locators; re-resolve at approval

**Files:**
- Modify: `backend/lib/valea/workflows/runner.ex` (`memory_envelope/5` stores a locator, not a raw path)
- Modify: `backend/lib/valea/workflows/memory_proposal.ex` (`check_target/2` returns a locator + resolved abs)
- Modify: `backend/lib/valea/queue.ex` (`apply_page_content/2` resolves the locator via `Locator.resolve/2`; envelope validation accepts the locator target)
- Test: `backend/test/valea/queue_test.exs`, `backend/test/valea/workflows/memory_proposal_test.exs`

**Interfaces:**
- Consumes: `Valea.Icm.Locator.for_path/2` (finalize: agent's granted target abs → locator), `Valea.Icm.Locator.resolve/2` (approval: locator → current abs).
- Produces: the memory-update queue payload's `proposed_action.target` becomes `%{"locator" => <ICM locator>, "base_sha256" => …, "content_markdown" => …}` (replacing the raw `target_path`). At approval, `apply_page_content/2` re-resolves the locator against the *current* mount table (spec §"Stable locators…": "missing, disabled, moved, or changed targets return to review instead of applying"), then applies the unchanged `check_base/2` hash guard. A moved-but-still-mounted ICM resolves fine; an unmounted/disabled/duplicate-id target returns the item to `pending/` with an `apply_conflict` audit.

- [ ] **Step 1: Write the failing tests** — a memory proposal whose target ICM is mounted applies on approval; after the ICM's path is repaired to a new location (re-mount at a new folder with the same id), a pending proposal re-resolves and still applies; after `unmount_icm`, approval returns `:apply_conflict` and the item goes back to `pending/`; the `check_base/2` hash-mismatch guard still blocks a changed page.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — at finalize, build the locator directly as `Locator.icm(sidecar.icm_id, target_rel)` after containment-validating the agent's ICM-relative `target_path` against the owning ICM root (the sidecar carries both from Task 7.2 — no absolute intermediate or `for_path/2` re-attribution needed); store it in the envelope; update `valid_payload?`/`valid_action_for_kind?` to accept `target.locator`; in `apply_page_content/2` replace `MemoryProposal.check_target` with `Locator.resolve/2` (map its errors to `:apply_conflict`) then keep `check_base/2`; update crash-recovery target resolution similarly (it reads the same sidecar `icm_id`).
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: memory-update queue targets as ICM locators, re-resolved at approval`.

### Task 7.4: Audit entries carry stable locator + resolved snapshot

**Files:**
- Modify: `backend/lib/valea/workflows/runner.ex` (workflow-run audit fields), `backend/lib/valea/queue.ex` (`action_executed`/`apply_conflict` fields)
- Test: `backend/test/valea/audit_test.exs` or the relevant runner/queue tests

**Interfaces:**
- Produces: audit entries for workflow runs and applied/blocked memory updates carry both the stable locator and the resolved physical path used (spec §"Stable locators…": "Transcripts and audit entries snapshot both the stable locator and the resolved physical path"). `Valea.Audit.append/2` is unchanged (it merges caller fields); callers now pass `%{"target" => %{"locator" => …, "resolved_path" => …}}` and `%{"workflow" => %{"icm_id" => …, "relative_path" => …, "resolved_path" => …}}` instead of raw path strings.

- [ ] **Step 1: Write the failing test** — approve a memory update; read the audit tail; assert the `action_executed` entry has both a `locator` (with `icm_id`) and a `resolved_path`.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — update the audit field construction at each call site to include the locator + resolved path.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: audit snapshots stable locator + resolved path`.

### Task 7.5: `RiskTier` on ICM identity; finalize + enrich call sites

**Files:**
- Modify: `backend/lib/valea/agents/risk_tier.ex` (`classify` takes an ICM locator / `(mount, rel_path)` and classifies the ICM-relative path directly)
- Modify: `backend/lib/valea/workflows/runner.ex:302` (`finalize_pair` classifies the target locator), `backend/lib/valea/agents/session_server.ex:279` (`enrich_item` attributes the touched absolute path via `Locator.for_path/2` then classifies)
- Test: `backend/test/valea/agents/risk_tier_test.exs`

**Interfaces:**
- Consumes: `Valea.Icm.Locator` (C5).
- Produces: `RiskTier.classify(locator_or_rel) :: "high" | "medium" | nil` that checks the **ICM-relative** path against `@behavior_files` (`AGENTS.md`/`CLAUDE.md`/`icm.yaml`) and the `Workflows/` prefix, WITHOUT relying on `Mounts.mount_for/2` attribution of a workspace path. This closes the regression the review found: once cwd == the ICM root, an agent's reference to `AGENTS.md`/`Workflows/*.md` is ICM-relative and the old workspace-path attribution returns `nil`, silently downgrading behavior-changing edits to "medium". `finalize_pair` classifies the memory-update target's ICM locator (its `path` is already ICM-relative). `enrich_item` (permission badge) has an absolute touched path; it calls `Locator.for_path(workspace, abs)` → ICM locator → `classify`. An off-ICM (workspace) locator classifies `nil` as before.

- [ ] **Step 1: Write the failing tests** — `classify(Locator.icm(id, "AGENTS.md")) == "high"`; `classify(Locator.icm(id, "Workflows/Distill Decisions.md")) == "high"`; `classify(Locator.icm(id, "Pricing/x.md")) == "medium"`; `classify(Locator.workspace("sources/mail/1.md")) == nil`. Plus a `finalize_pair` integration assertion that a proposal targeting `AGENTS.md` gets `risk_level: "high"`, not "medium".
- [ ] **Step 2: Run to verify failure** — FAIL (today `classify(workspace, "AGENTS.md")` → nil after the cwd move).
- [ ] **Step 3: Implement** — rework `classify` to take a locator (or `(mount, rel_path)`), strip to the ICM-relative path, and tier it directly; update both call sites.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: RiskTier classifies ICM-relative targets; fix finalize/enrich under cwd=ICM`.

**Phase 7 exit check:** workflows are ICM-owned and launch with exact input/staging grants only; queue targets and audit entries are locator-keyed and survive an ICM move (re-resolving at approval); memory-update risk tiers stay correct under cwd=ICM; a generic chat still cannot read workspace sources; suite green.

---

## Phase 8 — Multi-root watchers & doctor / degraded recovery

**Milestone:** the watcher runs one content listener per enabled ICM root plus the workspace `queue/`/`sources/`, recomputing the ICM root set when `config/workspace.yaml` `icms:` changes, and no longer regenerates `MOUNTS.md` or a workspace `.claude/settings.json`. `icm_doctor(mount_key)` reports per-ICM health for the external-only model: ref resolution, format-2 manifest, workspace-unique id, related-ICM resolvability, secrets hygiene, watcher liveness — driving the sidebar's degraded/repair states.

### Task 8.1: `Valea.ICM.Watcher` — per-ICM-root + workspace roots, no metadata regeneration

**Files:**
- Modify: `backend/lib/valea/icm/watcher.ex`
- Test: `backend/test/valea/icm/watcher_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.enabled/1` (each with an absolute `root`), the workspace root.
- Produces: the same broadcast contract (`{:icm_changed}` on `"icm"`, `{:mounts_changed}` on `"mounts"`, `{:queue_changed}` on `"queue"`) and `watched_roots/0`, but the watched set is: every enabled non-degraded ICM `root` (content → `{:icm_changed}`; a root's own `icm.yaml` → also `{:mounts_changed}`), plus workspace `queue/` (→ `{:queue_changed}`) and `sources/`, plus `config/` (a `config/workspace.yaml` change → `{:mounts_changed}` and a root-set recompute). The `mounts/` fixed watch is removed. On the discovery flush, **do not** call `MountsMd.regenerate/1` or `ClaudeSettings.write!/1` (both are gone/per-session) — `regenerate_workspace_metadata/1` is deleted from the watcher.

- [ ] **Step 1: Write the failing test** — with two enabled ICMs mounted, `watched_roots/0` contains both ICM roots (absolute) and the workspace `queue`/`sources`, and does NOT contain a `mounts/` path; editing a file under an ICM root broadcasts `{:icm_changed}`; editing `config/workspace.yaml` broadcasts `{:mounts_changed}` and adds/removes a root on recompute.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — replace `fixed_dirs/1` (`mounts/`,`queue/`,`config/`) with `queue/`,`sources/`,`config/`; feed the dynamic listener from `Mounts.enabled/1` roots; drop `regenerate_workspace_metadata/1` and its self-subscription; keep debounce + `Paths.resolve_real(".", path)` canonicalization + the `config/workspace.yaml`→recompute path.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: watcher watches ICM roots + workspace queue/sources; drop MOUNTS/settings regen`.

### Task 8.2: `icm_doctor` — external-only health + dup-id + related-ICM checks

**Files:**
- Modify: `backend/lib/valea/mounts/doctor.ex` (rewrite for the config-truth model; `run/2` for one mount_key)
- Modify: `backend/lib/valea/api/icms.ex` (`icm_doctor(mount_key, generation)` returns per-ICM checks)
- Modify: `frontend/src/lib/stores/mounts.svelte.ts` doctor consumption + codegen
- Test: `backend/test/valea/mounts/doctor_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.list/1` (degraded reasons already computed in Phase 3), `Valea.Mounts.Context.resolve/2` (related-ICM issues), watcher `watched_roots/0`.
- Produces: `Valea.Mounts.Doctor.run(workspace, mount_key) :: {:ok, %{mount_key, checks: [%{id, status, detail, remedy}], ok}}` with checks: `path_resolves`, `manifest_format2` (valid id), `unique_id` (no other mount shares the id), `related_icms` (each declared related resolves; surfaces `:not_mounted`/`:disabled`/`:entrypoint_escapes` from `Context.resolve/2`), `secrets_hygiene` (warn if the ICM root holds `secrets/` or `.env`-like files — Valea doesn't own the folder, so warn not deny), `watcher_live`. `run/1` (all mounts) stays for the workspace-wide diagnostics view. Degraded/missing ICMs report their reason + a repair remedy and expose no session action (spec §"ICM group behavior", §"Error handling").

- [ ] **Step 1: Write the failing tests** — a healthy ICM: all checks `ok`. Two mounts sharing an id: both fail `unique_id`. A primary whose `CONTEXT.md` declares an unmounted id: `related_icms` warns `:not_mounted`. A missing folder: `path_resolves` failed + a repair remedy present.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — rewrite `mount_checks/1` for external-only (drop the embedded/external branch); add `unique_id` + `related_icms` checks; wire `icm_doctor` RPC to `run/2`.
- [ ] **Step 4: Regenerate + gates** — codegen; `bun run check`.
- [ ] **Step 5: Commit** — `feat: icm_doctor reports external-only health, dup-id, related-ICM issues`.

**Phase 8 exit check:** watchers cover ICM roots + workspace queue/sources with no `MOUNTS.md`/settings regeneration; `icm_doctor` reports the full external-only health picture including dup-id and related-ICM problems; suite green. Backend refactor is functionally complete — Phases 9–10 rebuild the UI on top of it.

---

## Phase 9 — Sidebar ICM/session groups & Knowledge tree relocation

**Milestone:** the main sidebar shows mounted ICMs as project groups, each with its ≤5 most recent sessions (live first, status dot, "Show all…"), a `+` that starts a chat in that ICM, and a kebab menu; the recursive file tree moves entirely into the Knowledge route's list pane and switches by selected ICM; routes carry `?icm=<mount-key>` / `?session=<id>`.

### Task 9.1: Recent-sessions-by-ICM store

**Files:**
- Create: `frontend/src/lib/stores/recent-sessions.svelte.ts`
- Modify: `frontend/src/lib/stores/icm.svelte.ts` (live wiring: refresh recent-sessions on `icm_changed`/session events)
- Test: `frontend/src/lib/stores/recent-sessions.test.ts`

**Interfaces:**
- Consumes: `api.listRecentSessionsByIcm(5)` (Phase 6 wrapper), the `workspace:events` channel (already joined in `icm.svelte.ts:189`).
- Produces: a singleton `recentSessionsStore` with `groups: { mountKey, icmName, sessions: SessionSummary[] }[]` (`$state`), `refresh()`, and per-mount `sessionsFor(mountKey)`. Live-first ordering is server-provided; the store preserves it. Refresh is triggered on workspace open, on `mounts_changed`, and when a session's status changes.

- [ ] **Step 1: Write the failing test** — a Vitest over the store with a fake `api` returning two groups; assert `groups` is populated and `sessionsFor("coaching")` returns that group's sessions in server order.
- [ ] **Step 2: Run to verify failure** — `cd frontend && bun run test` → FAIL.
- [ ] **Step 3: Implement** the store (mirror `sessions-list.svelte.ts` shape; add grouping) and wire `refresh()` into the existing `wireIcmEvents` fan-out.
- [ ] **Step 4: Run to verify pass** — PASS.
- [ ] **Step 5: Commit** — `feat: recent-sessions-by-ICM store`.

### Task 9.2: `IcmProjects` sidebar component

**Files:**
- Create: `frontend/src/lib/components/shell/IcmProjects.svelte`
- Create: `frontend/src/lib/components/shell/icm-projects.ts` (pure grouping/ordering/expansion helpers)
- Modify: `frontend/src/lib/components/shell/index.ts` (export)
- Test: `frontend/src/lib/components/shell/icm-projects.test.ts`

**Interfaces:**
- Consumes: `mountsStore.mounts` (enabled + degraded, config order), `recentSessionsStore.groups`, `icmDoctor` for the Diagnose action, `api.createAgentSession(mountKey, generation)` + `goto`.
- Produces: a component rendering one row per enabled-or-degraded ICM (ordered by config order), each with (spec §"ICM group behavior"): manifest name label (row click → `/knowledge?icm=<key>`); a `+` that calls `createAgentSession(mountKey, gen)` then `goto('/chat?session=<id>')`; a kebab menu (New session, Open knowledge, Show workflows, Disable, Reveal folder, Diagnose); up to five sessions beneath, live-first with a status dot, each linking to `/chat?session=<id>`; a "Show all…" row (only when >5) → `/chat?icm=<key>` filtered history; a quiet "Start a session" row for a healthy empty ICM; a warning + repair (Diagnose) affordance and **no** new-session action for a degraded/missing ICM. The active ICM group is expanded; others keep local collapse state; a live session forces its group open. Disabled ICMs are omitted (they live in Workspace settings). Pure ordering/expansion/cap logic lives in `icm-projects.ts` and is unit-tested; the `.svelte` file is presentational over it.

- [ ] **Step 1: Write the failing test** — Vitest over `icm-projects.ts`: `orderGroups(mounts, recent)` drops disabled, keeps config order, merges degraded (no sessions), caps at 5 with live-first, and `showAll` is true only when a group has >5. Assert each case.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** `icm-projects.ts` (pure) then `IcmProjects.svelte` consuming it. Reuse `classifyMounts`/`buildMountsDisplay` from `knowledge/mount-sections.ts` where it fits; keep copy calm.
- [ ] **Step 4: Run to verify pass** — PASS (`bun run test` + `bun run check`).
- [ ] **Step 5: Commit** — `feat: IcmProjects sidebar component (groups + recent sessions)`.

### Task 9.3: Swap the sidebar tree for `IcmProjects`; relocate the tree into Knowledge

**Files:**
- Modify: `frontend/src/lib/components/shell/Sidebar.svelte:54-72` (remove the inline `IcmTree` block; render `IcmProjects` under an "ICMs" heading + a "Mount an ICM" footer action)
- Modify: `frontend/src/lib/components/shell/AppFrame.svelte:37`, `frontend/src/routes/+page.svelte:98` (drop the now-unused `icmNav` derivation for the sidebar)
- Modify: `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte` (render the recursive `IcmTree` in the `ListPane` `children` for the selected ICM; switch tree by `?icm=<key>`)
- Test: existing Knowledge/sidebar component tests updated

**Interfaces:**
- The sidebar no longer contains any folders/pages (spec §"File tree relocation"); Knowledge owns file navigation, showing the selected ICM's tree and replacing it when the selected ICM changes. `IcmTree.svelte` is reused inside Knowledge's list pane (it's already presentational over `NavTreeItem[]`).

- [ ] **Step 1: Implement** — replace the Sidebar block with `<IcmProjects />`; move `IcmTree` into the Knowledge list panes keyed off `?icm`; remove the dead `icmNav` props/derivations.
- [ ] **Step 2: Run gates** — `bun run check` (0), `bun run test` (green); manually verify in the Browser preview (see Verification below).
- [ ] **Step 3: Commit** — `feat: sidebar shows ICM projects; file tree lives in Knowledge`.

### Task 9.4: Route scheme — `?icm` / `?session`

**Files:**
- Modify: `frontend/src/routes/chat/+page.svelte` (honor `?icm=<key>` for new-session ICM selection and empty-state; `?session=<id>` authoritative), `frontend/src/routes/knowledge/+page.svelte` (`?icm=<key>` selects the ICM whose tree shows), `frontend/src/routes/workflows/+page.svelte` (optional `?icm=<key>` filter)
- Test: route-logic unit tests where pure

**Interfaces:**
- `/knowledge?icm=<mount-key>`, `/chat?icm=<mount-key>` (new-session/empty-state selection), `/chat?session=<session-id>` (authoritative; its metadata determines the ICM), `/workflows?icm=<mount-key>` (filter) (spec §"Routes"). The `icm` query is a selection, never a way to reassign an existing transcript.

- [ ] **Step 1: Implement** the query handling in each route; the session id wins when present.
- [ ] **Step 2: Run gates + verify preview** — `bun run check`/`bun run test`; drive the flows in the Browser preview.
- [ ] **Step 3: Commit** — `feat: ?icm / ?session route scheme for ICM-scoped navigation`.

### Task 9.5: Workspace-wide views carry ICM provenance

**Files:**
- Modify: `frontend/src/routes/+page.svelte` (Today — each prepared item shows its owning ICM), `frontend/src/routes/queue/[run_id]/+page.svelte` + queue list (show owning ICM), `frontend/src/routes/audit/+page.svelte` (show ICM provenance), `frontend/src/routes/mail/+page.svelte` + `frontend/src/lib/components/mail/MessageView.svelte` + `frontend/src/routes/calendar/+page.svelte` (an action must select an ICM or a workflow that identifies one)
- Modify: any backend view payloads that must surface `icm_mount`/`icm_name` (Today aggregation, queue/audit entries — the provenance is already in the data from Phases 6–7; expose the display fields)
- Test: affected route/component tests

**Interfaces:**
- The workflow catalog, Today, Queue, and Audit remain workspace-wide but each item shows its owning ICM (`icm_mount`/`icm_name`); Mail and Calendar do not choose an ICM themselves — an action launched from them opens a picker that selects an ICM (or a workflow that already identifies one) before starting a session, passing the selected message/event as an exact input locator (spec §"Workspace-wide views"; §"Permission and containment model": a "chat about this message" action names the target ICM and passes the message as an exact input).

- [ ] **Step 1: Implement** — surface `icm_name` on Today/Queue/Audit items; add the ICM/workflow picker to the Mail/Calendar action entry points (reuse the sidebar `IcmProjects` selection UI or a compact chooser); the picked ICM + exact input locator flow into `create_session`/`run_workflow`.
- [ ] **Step 2: Run gates + preview** — `bun run check`/`bun run test`; in-browser, confirm a Today item names its ICM and a "chat about this message" action requires an ICM selection.
- [ ] **Step 3: Commit** — `feat: workspace-wide views carry ICM provenance; mail/calendar actions select an ICM`.

### Task 9.6: Re-key editor link + image path math to `(mountKey, relative_path)`

**Files:**
- Modify: `frontend/src/lib/editor/page-link.ts` (`linkDestination`/`parentOf`/`pickerItems` drop the `isAbsolute(path)` embedded-vs-external fork; every ICM path is ICM-relative within a known `mountKey`)
- Modify: `frontend/src/lib/editor/image-upload.ts` (`resolveImageSrc`/`joinRelative` drop the same `isAbsolute` fork; `src` is ICM-relative, resolved via `GET /files/raw?mount_key=…&path=…`)
- Modify: `frontend/src/lib/components/palette/palette.ts` + `SearchPalette.svelte` (pass the selected ICM `mountKey` to `icmSearch`; results carry `mountKey`), `frontend/src/lib/components/knowledge/backlinks-panel.ts` consumers (references keyed by primary `mountKey`)
- Test: `frontend/src/lib/editor/page-link.test.ts`, `image-upload.test.ts`, the palette tests

**Interfaces:**
- The `isAbsolute(path)` "leading slash ⇒ external mount, else workspace-relative embedded" heuristic in `page-link.ts:28-30` and `image-upload.ts:68-69` no longer corresponds to anything real once Phase 4 collapses the backend `rel_root || root` fork (every path is now `(mount_key, ICM-relative)`). This task removes that heuristic so the link picker's relative-destination math and the image `src` resolution are *correct*, not merely `bun run check`-green (the vocabulary drift Phase 4.3 deferred). Cmd+K and the backlinks panel now operate against the selected ICM's `mountKey` (primary + related per Task 5.6).

- [ ] **Step 1: Write the failing tests** — `linkDestination` for a page in ICM `coaching` produces an ICM-relative destination with no leading-slash branch; `resolveImageSrc` builds a `/files/raw?mount_key=coaching&path=Assets/x.png` URL; the palette passes `mountKey` to `icmSearch`.
- [ ] **Step 2: Run to verify failure** — `cd frontend && bun run test` → FAIL.
- [ ] **Step 3: Implement** — delete the `isAbsolute` forks; thread `mountKey` into the picker, image src, palette, and backlinks calls; update the co-located `.test.ts` expectations.
- [ ] **Step 4: Run gates + preview** — `bun run check`/`bun run test`; in-browser: paste an image (round-trips via `/files/raw`), use `[[` to link a multi-word page, Cmd+K within the ICM.
- [ ] **Step 5: Commit** — `feat: editor link/image path math + palette keyed to (mountKey, relative_path)`.

**Verification (Browser preview):** after Task 9.3/9.4, start the dev server via `preview_start` (`.claude/launch.json` `dev` config → backend `mix phx.server` + frontend on `:4273`; see the Justfile `dev` recipe), open the app, create a workspace + mount an ICM (Phase 10 UI may still be in progress — use the `create_icm`/`mount_icm` RPCs or a seeded workspace), and confirm the sidebar shows the ICM group with its `+`, that `+` starts a chat whose transcript names that ICM, and that the file tree renders in Knowledge (not the sidebar). Capture a screenshot for the summary.

**Phase 9 exit check:** the sidebar is ICM projects + recent sessions with no file tree; Knowledge owns the tree and switches by ICM; routes carry `?icm`/`?session`; `bun run check`/`bun run test` green and the flow verified in-browser.

---

## Phase 10 — Onboarding (Start fresh / Use existing ICM) & id-based switcher

**Milestone:** users never create, locate, or type a workspace folder. Onboarding offers Start fresh (name → create a portable ICM at a visible default location → auto-create the hidden workspace → mount by reference → open a first session) and Use existing ICM (pick a folder → validate + preview → auto-create the hidden workspace → mount by reference in place → open Knowledge). The `WorkspaceSwitcher` switches by internal id with a live-session confirmation and no manual-path entry.

### Task 10.1: `inspect_icm` + workspace store carries `id`; switcher by id

**Files:**
- Modify: `backend/lib/valea/api/icms.ex` (add `inspect_icm(path)` → `%{ok, name, description, reason}` via `Manifest.load/1` + boundary sanity; no open workspace required)
- Modify: `frontend/src/lib/stores/workspace.svelte.ts` (add `id`; `switchTo(id)` → preflight → `openWorkspace(id)`)
- Modify: `frontend/src/lib/components/shell/WorkspaceSwitcher.svelte` (id-keyed recent list; remove the manual-path form `:157-177` and "Open another folder…" item; live-session confirmation via `workspaceSwitchPreflight`)
- Modify: `frontend/src/lib/api/ash_rpc.ts` (regenerated)
- Test: `backend/test/valea/api/icms_test.exs`, `frontend` switcher/store tests

**Interfaces:**
- Produces: `inspect_icm(path) :: %{"ok", "name", "description", "reason"}` (validates a folder is a healthy format-2 ICM without mounting it — used by onboarding/mount previews). The workspace store's `state` gains `id`; `switchTo(id)` runs `workspaceSwitchPreflight(id)` first and, if live sessions exist, confirms before `openWorkspace(id)`. The switcher lists `recent` by id and marks current by `id`.

- [ ] **Step 1: Write the failing tests** — backend: `inspect_icm(healthy_icm_path)` returns `ok: true` with the manifest name; a non-ICM folder returns `ok: false` + a reason. Frontend: a store test asserting `switchTo(id)` calls `openWorkspace` with an id and consults preflight.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** — the `inspect_icm` action; `id` in the store; the switcher rework (delete the manual-path branch; wire preflight + confirmation copy, calm tone). Regenerate the client.
- [ ] **Step 4: Run gates** — backend tests, codegen diff clean, `bun run check`/`bun run test`.
- [ ] **Step 5: Commit** — `feat: inspect_icm + id-based workspace switch (no manual path)`.

### Task 10.2: Onboarding — Start fresh

**Files:**
- Modify: `frontend/src/lib/components/onboarding/Onboarding.svelte` (two primary paths: Start fresh / Use existing ICM)
- Rewrite: `frontend/src/lib/components/onboarding/CreateWorkspaceDialog.svelte` → a "Start fresh" flow (ICM name → default folder `~/Documents/Valea/<name>/` with "Choose another location" → create)
- Modify: `frontend/src/lib/components/onboarding/onboarding-path.ts` (pure orchestration: `startFresh(name, folder, deps)`)
- Test: `frontend/src/lib/components/onboarding/onboarding-path.test.ts`

**Interfaces:**
- Consumes: `api.createWorkspace(name)`, `api.createIcm(name, path, generation)`, the Tauri dialog for "Choose another location", the default-folder suggestion.
- Produces: `startFresh(name, folder, deps)` orchestrates `createWorkspace(name)` → (workspace now open, generation known) → `createIcm(name, folder, generation)` → navigate to `/chat?icm=<mount-key>` (first session). Workspace name defaults from the ICM name, adjustable in a secondary field; the workspace path is never shown. Valea never creates ICM content under the hidden workspace (the ICM is created at `folder`).

- [ ] **Step 1: Write the failing test** — a Vitest over `startFresh` with fake deps asserting the call order (`createWorkspace` then `createIcm`) and that navigation targets the new ICM's session; error from `createIcm` surfaces without leaving a half-open state.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** `startFresh` + the dialog UI (default folder `~/Documents/Valea/<name>/`, calm copy).
- [ ] **Step 4: Run gates + preview** — `bun run test`/`bun run check`; drive Start fresh in the Browser preview end to end.
- [ ] **Step 5: Commit** — `feat: Start fresh onboarding (create ICM + hidden workspace + first session)`.

### Task 10.3: Onboarding — Use existing ICM

**Files:**
- Rewrite: `frontend/src/lib/components/onboarding/OpenWorkspaceFlow.svelte` → a "Use existing ICM" flow (pick folder → `inspect_icm` preview → create workspace + mount by reference → open Knowledge)
- Modify: `frontend/src/lib/components/onboarding/onboarding-path.ts` (`useExistingIcm(path, workspaceName, deps)`; remove `decideOnboardingMode`/adopt/move branches)
- Test: `frontend/src/lib/components/onboarding/onboarding-path.test.ts`

**Interfaces:**
- Consumes: `api.inspectIcm(path)`, `api.createWorkspace(name)`, `api.mountIcm(path, generation)`, the Tauri folder picker.
- Produces: `useExistingIcm(path, workspaceName, deps)` → `inspectIcm(path)` (preview name/description/location; block if not a healthy ICM) → `createWorkspace(workspaceName ?? icmName)` → `mountIcm(path, generation)` (by reference, no copy/move) → navigate to `/knowledge?icm=<mount-key>` with a prominent New session action. The workspace name defaults from the ICM name, editable, path never shown.

- [ ] **Step 1: Write the failing test** — a Vitest over `useExistingIcm` asserting `inspectIcm` → `createWorkspace` → `mountIcm` order and Knowledge navigation; a non-ICM path stops before creating a workspace.
- [ ] **Step 2: Run to verify failure** — FAIL.
- [ ] **Step 3: Implement** `useExistingIcm` + the flow UI (remove the old adopt/reference dual action and move-adopt path).
- [ ] **Step 4: Run gates + preview** — `bun run test`/`bun run check`; drive Use existing ICM in the Browser preview (mount a pre-created ICM folder, confirm it appears in place and history is empty).
- [ ] **Step 5: Commit** — `feat: Use existing ICM onboarding (mount by reference into a fresh workspace)`.

### Task 10.4: Sidebar "Mount an ICM" — Mount existing / Create new

**Files:**
- Create: `frontend/src/lib/components/shell/MountIcmAction.svelte` (the footer choice + validation preview)
- Modify: `frontend/src/lib/components/shell/IcmProjects.svelte` (footer "+ Mount an ICM")
- Modify: existing `frontend/src/lib/components/knowledge/MountFromElsewhereDialog.svelte` (repoint to `mount_icm` by reference; drop any move option)
- Test: `frontend` component tests

**Interfaces:**
- Consumes: `api.mountIcm(path, generation)` (with a directory picker + `inspect_icm` validation preview before writing config) and `api.createIcm(name, path, generation)` (name + a sensible visible default folder). Both operate on the currently open workspace and refresh `mountsStore`/`recentSessionsStore`.
- Produces: a small choice (Mount an existing ICM… / Create a new ICM…) surfaced from the sidebar footer and Workspace settings. Create asks for a name, offers a default visible folder, creates the portable ICM, then mounts it by reference; Valea never creates ICM content under the hidden workspace (spec §"Mount/create actions").

- [ ] **Step 1: Implement** the action + validation preview; wire it into `IcmProjects` and Workspace settings; ensure a disabled ICM appears in settings for re-enable.
- [ ] **Step 2: Run gates + preview** — `bun run check`/`bun run test`; in-browser: mount a second ICM, confirm both appear as projects and starting under one does not load the other.
- [ ] **Step 3: Commit** — `feat: sidebar Mount/Create ICM actions with validation preview`.

**Phase 10 exit check:** onboarding is Start fresh / Use existing ICM with no workspace-path prompt; the switcher is id-based with a live-session guard and no manual path; ICMs can be mounted/created from the sidebar; both flows verified in the Browser preview; suite green.

---

## Phase 11 — Delete legacy embedded-mount, migration, adoption & routing paths

**Milestone:** all superseded code is gone — no `MOUNTS.md` generator, no embedded `mounts/` discovery, no `External` split, no workspace-version migration, no adopt-by-move, no path-based workspace RPC, no `<workspace>/.claude/settings.json` writer, no legacy transcript reader, no dead `rel_root` branches. The suite is green with zero references to the removed surface. (spec §"Clean-cut implementation policy".)

### Task 11.1: Remove `MOUNTS.md`, `External`, `ClaudeSettings`, legacy `Api.Mounts`

**Files:**
- Delete: `backend/lib/valea/mounts/mounts_md.ex`, `backend/lib/valea/mounts/external.ex`, `backend/lib/valea/agents/claude_settings.ex`, `backend/lib/valea/api/mounts.ex`
- Modify: `backend/lib/valea/mounts.ex` (inline the boundary/ref-validation helpers that were in `External`), `backend/lib/valea/api.ex` (drop `Valea.Api.Mounts` registration)
- Modify: any remaining callers of the deleted modules (grep `MountsMd`, `ClaudeSettings`, `Valea.Mounts.External`, `Valea.Api.Mounts`)
- Delete/replace: tests for the removed modules

**Interfaces:** none new — pure removal. `Valea.Mounts` absorbs `External`'s `check_boundaries/2`/`validate_ref/2` as private functions (they're already called from `Valea.Mounts` since Phase 3).

- [ ] **Step 1: Grep the blast radius** — `cd backend && grep -rl "MountsMd\|Valea.Mounts.External\|ClaudeSettings\|Valea.Api.Mounts" lib test`. Every hit is removed or repointed in this task.
- [ ] **Step 2: Delete + inline + repoint** — delete the four modules, inline the two `External` helpers into `Valea.Mounts`, drop the `Api.Mounts` registration and its tests.
- [ ] **Step 3: Run the suite** — `cd backend && mix test` → PASS (zero warnings; a warning here means a dangling reference).
- [ ] **Step 4: Commit** — `refactor: delete MOUNTS.md, External, ClaudeSettings, legacy Mounts RPC`.

### Task 11.2: Remove migration, adopt, legacy template/fixtures, path-based Workspace RPC

**Files:**
- Delete: `backend/lib/valea/workspace/migration.ex`, `backend/lib/valea/workspace/adopt.ex`, `backend/priv/legacy_workspace_template/`, `backend/priv/migration_fixtures/`
- Modify: `backend/lib/valea/workspace/manager.ex` (drop the `Migration.migrate/1` call from the open pipeline), `backend/lib/valea/api/workspace.ex` (delete `inspect_path`/`inspect_workspace`/`adopt_workspace`/`open_workspace(path)`/`create_workspace(parent_dir,name)` — keep only the C9 id-based actions), `backend/lib/valea/agents.ex` (`list_sessions/0` ignores any transcript whose line 1 is not `session/v1`)
- Delete/replace: migration/adopt tests

**Interfaces:** none new. The Manager open pipeline no longer runs a version migration (all workspaces are born v5). `list_sessions/0` silently skips pre-redesign transcripts (spec §"Session persistence": no reader for old transcripts).

- [ ] **Step 1: Grep** — `grep -rl "Valea.Workspace.Migration\|Valea.Workspace.Adopt\|migration_fixtures\|legacy_workspace_template\|inspect_path\|adopt_workspace" lib test priv`.
- [ ] **Step 2: Delete + repoint** — remove the modules/dirs, drop the migration call, delete the legacy Workspace actions, add the `session/v1`-only guard in `list_sessions/0`.
- [ ] **Step 3: Run the suite** — `cd backend && mix test` → PASS, zero warnings.
- [ ] **Step 4: Commit** — `refactor: delete workspace migration, adopt-by-move, legacy templates + path RPCs`.

### Task 11.3: Remove dead `rel_root` branches + frontend legacy + regen

**Files:**
- Modify: `backend/lib/valea/icm.ex`, `backend/lib/valea/icm/references.ex`, `backend/lib/valea/icm/search.ex`, `backend/lib/valea/icm/backlinks.ex`, `backend/lib/valea/icm/link_rewrite.ex` (delete the now-unreachable embedded (`rel_root != nil`) branches and any workspace-relative normalization that no longer applies). `risk_tier.ex` was already reworked onto ICM locators in Task 7.5 — do not re-touch its logic here. Note: Step 1's `grep -rn "rel_root" lib` is authoritative for the full blast radius; the C10 module map named only four files, but `rel_root` also appears in `files_controller.ex`, `workflows.ex`, `workflows/memory_proposal.ex`, `workflows/runner.ex`, `icm/watcher.ex`, and `mounts/doctor.ex` — clean every hit the grep returns, not just the named files.
- Modify: `frontend/src/lib/stores/workspace.svelte.ts` (delete `adopt()`), `frontend/src/lib/api/client.ts` (delete `adoptWorkspace`/`inspectPath`/`inspectWorkspace`/`createWorkspace(parentDir,…)` wrappers), remove unused `sessions-list.svelte.ts` singleton if now dead, and any leftover onboarding files (`onboarding-path` adopt helpers, `MountFromElsewhereDialog` move option, `UnmountDialog` copy)
- Modify: `frontend/src/lib/api/ash_rpc.ts` (regenerated — the deleted actions disappear)
- Modify: tests referencing removed surface

**Interfaces:** none new. The `mount()` type may keep the `rel_root` field (always `nil`) or drop it; if dropped, update every struct-map site — otherwise leave it as a documented always-nil vestige. Recommend: **drop `rel_root`** from the `mount()` map now that no code branches on it, updating all consumers.

- [ ] **Step 1: Grep** — backend `grep -rn "rel_root" lib`; frontend `grep -rn "adopt\|inspectPath\|inspectWorkspace" src`.
- [ ] **Step 2: Delete + simplify** — remove dead branches; drop `rel_root`; delete frontend legacy; regenerate the client.
- [ ] **Step 3: Run all gates** — `cd backend && mix test` (0 warnings); `mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/` (clean); `cd frontend && bun run check` (0) + `bun run test` (green).
- [ ] **Step 4: Commit** — `refactor: drop dead rel_root branches + frontend adopt/inspect legacy`.

**Phase 11 exit check:** `grep -rn "MountsMd\|MOUNTS.md\|rel_root\|Migration\|Adopt\|ClaudeSettings\|adoptWorkspace" backend/lib frontend/src` returns nothing meaningful; `just test` is fully green with zero warnings; the codebase contains only the new model.

---

## Phase 12 — Documentation & acceptance sweep

**Milestone:** the as-built docs describe the new architecture, the superseded design docs are marked, the throwaway spike is cleaned up, and the six acceptance scenarios pass against the real packaged app.

### Task 12.1: Update as-built docs + supersede markers

**Files:**
- Modify: `docs/ARCHITECTURE.md` (workspace = hidden operational profile; ICM = portable context project mounted by reference; session cwd = primary ICM; SessionScope / locators / managed session settings; delete embedded-mount / MOUNTS.md / migration sections)
- Modify: `docs/VISION.md` (add the "your knowledge stays in folders you own; Valea keeps accounts/work/approvals/history in a private local workspace" principle — spec §"Onboarding" trust copy)
- Modify: `docs/superpowers/specs/2026-07-12-icm-mounts-design.md` and `…-icm-by-reference-design.md` (add a "Superseded by 2026-07-13-icm-project-workspaces" banner if not already present)
- Delete: `backend/scripts/spike/acp_launch_probe.exs` (throwaway; keep `docs/notes/acp-launch-contract.md`)
- Modify: the final product-contract paragraph into `docs/ARCHITECTURE.md` (spec §"Final product contract")

- [ ] **Step 1: Rewrite the affected `ARCHITECTURE.md` sections** to match the new model; remove references to embedded mounts, `MOUNTS.md`, workspace-as-project, and version migration.
- [ ] **Step 2: Add the VISION principle + trust copy; add supersede banners; delete the spike probe.**
- [ ] **Step 3: Verify no doc still describes the old model** — `grep -rn "MOUNTS.md\|mounts/<name>\|embedded mount\|adopt-by-move" docs` returns only historical/superseded contexts.
- [ ] **Step 4: Commit** — `docs: as-built architecture for ICM project workspaces; supersede prior mount designs`.

### Task 12.2: Acceptance scenarios against the packaged app

**Files:**
- Create: `docs/superpowers/acceptance/2026-07-13-icm-project-workspaces.md` (the run log / checklist)

Drive the real app (`just dev` or `just dev-desktop`; or a packaged build via `just build`) and confirm each spec §"Acceptance scenarios" case. Record pass/fail + notes in the acceptance doc. Do not check a box until observed.

- [ ] **Scenario 1 — Fresh start:** Start fresh, name "Mara Lindt Coaching", accept the visible ICM location, finish onboarding → a hidden workspace exists under `~/.valea/workspaces/…`, the ICM is created + mounted at the chosen location, it shows in the sidebar, and the first session's cwd is that ICM (verify via the session transcript's `icm_root`).
- [ ] **Scenario 2 — Existing ICM:** select an existing folder → a hidden workspace is created without a workspace-folder prompt, the ICM is mounted in place, and its Knowledge tree + New session action appear.
- [ ] **Scenario 3 — Two ICMs:** mount Legal alongside Coaching → both appear as projects; starting under Coaching does not load Legal unless Coaching declares it; starting under Legal uses Legal as cwd.
- [ ] **Scenario 4 — Related ICM:** Coaching declares Legal by id in `CONTEXT.md` → a Coaching session gets the resolved Legal root and follows Coaching's routing to Legal's entrypoint; no other mounted ICM joins.
- [ ] **Scenario 5 — Workspace separation:** create Consulting with a different mail setup, mount the same Legal ICM → switching stops the old runtime, swaps sidebar/account data, Legal is the same physical folder, and session/audit history stays separate; credentials remain keyed by workspace id.
- [ ] **Scenario 6 — Workflow:** run a Coaching workflow against one mail source → the session cwd is Coaching; only the exact mail input + staging outputs are granted; approval + audit stay in the Coaching workspace.
- [ ] **Testing-strategy sweep:** confirm the spec §"Testing strategy" cases are covered by the automated suites written across Phases 2–10 (registry/workspace, context/launch, permissions, sessions/workflows, frontend); note any gap and add a test.
- [ ] **Commit** — `docs: acceptance run for ICM project workspaces`.

**Phase 12 exit check:** as-built docs match reality, superseded docs are marked, all six acceptance scenarios pass against the real app, and `just test` is green. The refactor is complete.

---

## Final product contract (from the spec)

> A Valea workspace is a private local operational profile. An ICM is a portable user-owned context project. A mounted ICM is available to launch; it is not automatically part of another ICM's context. Every agent session runs inside exactly one primary ICM, and Valea supplies only the related context and working artifacts that the ICM or task explicitly names.
