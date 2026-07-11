# By-Reference ICM Mounts Implementation Plan (ICM Plan A2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an ICM live outside the workspace and be mounted by reference — the user's pre-existing knowledge folder stays where it is, one physical ICM can serve several workspaces — per `docs/superpowers/specs/2026-07-12-icm-by-reference-design.md` (READ IT for any ambiguity). This extends Plan A.

**Architecture:** External mounts are DECLARED in `config/workspace.yaml` (`kind: path`, `ref: <abs>`) since there is nothing under `mounts/` to discover. `Valea.Mounts` gains external-mount resolution alongside embedded discovery. The agent read boundary widens by exactly one resolved-real root per enabled external mount, coordinated across three places: the managed `.claude/settings.json` allow list, the permission policy's containment (generalized from one workspace root to a ROOT SET), and a per-mount watcher. External mount content is addressed by its real absolute path everywhere (no virtual prefix).

**Tech Stack:** As Plan A, plus the Phase-3 `Valea.Paths.resolve_real` containment machinery and `Valea.Agents.ClaudeSettings`.

## Global Constraints

- **This spec is a deliberate boundary widening.** Each enabled external mount adds exactly one root (its resolved-real absolute path) to the agent's read surface, declared by the user, visible in the doctor, and audited. Nothing else in the managed settings deny-list changes; deny still wins over allow.
- **Physical paths, no virtual prefix.** External mount content is addressed by its resolved absolute path in every agent-visible, workflow-contract, run-input, queue-envelope, and audit vocabulary. The mount NAME is a UI/config label only, never a path segment. (A virtual `mounts/<name>/…` alias would break agent tools, which operate on the real filesystem.)
- **Declaration joins discovery.** The effective mount set = discovered embedded mounts (Plan A) ∪ declared external mounts (this plan). A name collision between an embedded dir and a declared entry ⇒ both degraded, nothing mounted under that name.
- **`ref` guardrails (reject as invalid → degraded):** a ref inside the workspace root; a ref that is an ancestor of the workspace; the home directory itself or `/`. Refs are `~`-expanded and symlink-resolved (`resolve_real`-style) at load.
- **Containment is a ROOT SET.** A path is readable iff it resolves (realpath, symlink-before-`..`) inside SOME enabled root (workspace root ∪ external roots). A symlink inside an external mount that escapes it is denied unless it resolves into another enabled root. Write containment is UNCHANGED (staging paths only; ask-gated Write/Edit is the agent's ICM-edit path, now also valid inside external mounts).
- **Valea never mutates anything outside the workspace root** except edits the user/agent explicitly make to mounted pages. Never deletes/moves/rewrites an external folder; un-mounting removes only the config entry.
- **Secrets hygiene:** the doctor warns (does not deny) when an external mount root contains a `secrets/` dir or `.env`-like files — the workspace deny-list does not reach into folders Valea doesn't own.
- Backend `mix format`/`mix test`/no-warnings; frontend `bun run check` 0 / `bun run test`; commit trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; never push.

## File Structure

```
backend/lib/valea/
  mounts.ex                 # MODIFY — merge declared external mounts into list/enabled/mount_for (T2)
  mounts/external.ex        # NEW — parse config kind/ref, guardrails, resolve, degradation (T1)
  agents/permission_policy.ex # MODIFY — containment over a ROOT SET (T3)
  agents/claude_settings.ex   # MODIFY — per-enabled-external-mount Read allow entries (T4)
  agents/session_server.ex / start_session  # MODIFY — read_roots include external real roots (T3)
  icm/watcher.ex            # MODIFY — spawn a watcher per enabled external mount (T5)
  mounts/mounts_md.ex       # MODIFY — external mounts show real location + @<abs>/AGENTS.md (T6)
  mounts/doctor.ex          # NEW — mounts doctor section (resolves, manifest, secrets, watcher) (T7)
  api/mounts.ex             # MODIFY — declare_mount / undeclare_mount / mounts_doctor RPCs (T8)
  audit.ex usage            # MODIFY — mount_declared/enabled/disabled audit entries (T8)
frontend/src/lib/…          # MODIFY — "Mount a folder from elsewhere" + adopt-by-reference default (T9)
```

Task order: T1 external config model → T2 Mounts merge → T3 root-set containment → T4 settings allows → T5 external watchers → T6 MOUNTS.md external → T7 mounts doctor → T8 mounts RPCs + audit → T9 onboarding/Knowledge by-reference → T10 docs + acceptance.

---

### Task 1: `Valea.Mounts.External` — config model + guardrails + resolution

**Files:**
- Create: `backend/lib/valea/mounts/external.ex`
- Test: `backend/test/valea/mounts/external_test.exs`

**Interfaces (Produces):**
```elixir
defmodule Valea.Mounts.External do
  # Read the config/workspace.yaml `mounts:` section, return declared EXTERNAL
  # mounts (entries with kind: path) as resolved mount structs matching the
  # Plan-A `Valea.Mounts.mount` shape, with `rel_root: nil` and `root` = the
  # resolved-real absolute ref (or degraded with a reason).
  @spec declared(workspace :: String.t()) :: [Valea.Mounts.mount()]
  # Validate a candidate ref for declaration (used by declare_mount RPC before writing config).
  @spec validate_ref(workspace :: String.t(), ref :: String.t()) ::
          {:ok, resolved_abs :: String.t()} | {:error, reason :: atom()}
  # reasons: :inside_workspace | :ancestor_of_workspace | :home_or_root | :not_found |
  #          :no_manifest | {:invalid_manifest, String.t()}
end
```
Rules: expand `~`, resolve symlinks realpath-style; reject per the guardrails (`:inside_workspace` if the resolved ref is under the workspace root; `:ancestor_of_workspace` if the workspace root is under the ref; `:home_or_root` if ref == `$HOME` or `/`). A declared mount whose ref fails to resolve (missing path) is DEGRADED with `:not_found` (not dropped — config preserved, recovers later). Manifest load reuses `Valea.Mounts.Manifest.load/1` against the resolved root.

- [ ] **Step 1: Failing tests** — a valid external ref resolves to a mount struct (root = abs, rel_root nil, manifest loaded); `validate_ref` rejects inside-workspace / ancestor / `$HOME` / `/`; a missing ref → degraded `:not_found`; a ref without icm.yaml → `:no_manifest`; `~`-expansion works; symlink to a valid ICM resolves to its real path.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): external ICM mount config model + ref guardrails`

---

### Task 2: `Valea.Mounts` merges declared external mounts

**Files:**
- Modify: `backend/lib/valea/mounts.ex`
- Test: extend `backend/test/valea/mounts_test.exs`

`list/1` and `enabled/1` now return embedded ∪ external (via `External.declared/1`). `enabled` state for an external mount comes from the SAME `mounts.<name>.enabled` config key (default true). Name-collision rule: if a name exists both as an embedded dir AND a declared external entry, mark BOTH degraded (`"name used by both an embedded and an external mount"`), exclude from `enabled`. `mount_for/2` must resolve a path that lives under an external root too — so `mount_for` now checks each mount's `root` (absolute) as a prefix (realpath-safe), not just the `mounts/<name>` rel prefix. `set_enabled/2` is unchanged (writes the shared config key; works for external names).

- [ ] **Step 1: Failing tests** — one embedded + one external declared → `enabled/1` has both; a path under the external real root → `mount_for` returns the external mount; disabling the external name drops it from `enabled` but keeps the config; embedded/external name collision → both degraded; the external's `enabled` default is true when no config entry.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): Mounts merges declared external mounts with embedded`

---

### Task 3: Root-set containment in the permission policy

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex`
- Modify: session start (`Valea.Agents.start_session` / `session_server.ex`) — pass the external real roots into `policy_ctx`
- Test: extend `backend/test/valea/agents/permission_policy_test.exs`

Generalize containment from a single workspace root to a root SET. Add `ctx[:extra_roots]` — a list of absolute external mount roots (from `Mounts.enabled` where `rel_root == nil`). A read is allowed iff its `resolve_real` result is contained in the workspace root (existing `read_roots` logic) OR under any `extra_roots` member. `resolve_real` semantics per root are UNCHANGED (symlink-before-`..`, realpath). A symlink inside an external root escaping it is denied unless it lands in another enabled root. The deny-list still applies to the workspace tree only (external mounts have no Valea-managed deny-list — that is the secrets-hygiene warning's job, T7). Write paths unchanged.

Session start computes `extra_roots = for m <- Mounts.enabled(ws), m.rel_root == nil, do: m.root` and puts it in `policy_ctx`.

- [ ] **Step 1: Failing tests** — a read under an `extra_roots` member is allowed; the same path with the mount disabled (absent from extra_roots) ask-gates; an escape symlink out of an external root is denied; a symlink from external root INTO the workspace sources/ resolves allowed; deny-list (`secrets/`) inside the WORKSPACE still wins; prefix-boundary correctness (`/ext/icm` root does not match `/ext/icm-other/…`).
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): permission policy contains over a root set (external mounts)`

---

### Task 4: Managed settings — external Read allows

**Files:**
- Modify: `backend/lib/valea/agents/claude_settings.ex`
- Test: extend `backend/test/valea/agents/claude_settings_test.exs`

`ClaudeSettings.write!/1` (or its map builder) adds, for each ENABLED external mount, an allow entry `Read(<resolved-abs-root>/**)` (absolute-path glob — Claude Code allows absolute Read globs). Embedded mounts need NO new allow (they're under the cwd-scoped `Read(./**)`). The deny block is unchanged and still wins (deny > allow). Settings regenerate on every mount change / open / session start (already the case; ensure `write!` reads `Mounts.enabled` for the external set). Absolute paths in the allow list are the resolved-real ones.

- [ ] **Step 1: Failing tests** — with one enabled external mount, the written settings' allow list contains `Read(<abs>/**)`; disabling it removes the entry on regeneration; the deny block is byte-identical to before; two external mounts → two allow entries; an embedded-only workspace has no absolute Read allows.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): managed settings grant Read for enabled external mounts`

---

### Task 5: Watcher per external mount

**Files:**
- Modify: `backend/lib/valea/icm/watcher.ex` (+ how it's supervised in `runtime.ex`)
- Test: extend `backend/test/valea/icm/watcher_test.exs`

The single watcher currently covers `mounts/` + `queue/` (Plan A). Add: at watcher init (and on `{:mounts_changed}`), subscribe to each enabled external mount's real root; a change under any external root broadcasts `{:icm_changed}` (tree/reference refetch) with the same debounce discipline. Because external roots can change at runtime (enable/disable/declare), the watcher must be able to re-subscribe — restart the underlying `FileSystem` watcher with the new dir set on `{:mounts_changed}`, or run a small dynamic set of `FileSystem` processes keyed by root. Keep it simple: on `{:mounts_changed}`, recompute the dir set (`mounts/`, `queue/`, each enabled external root) and reinitialize the FileSystem subscription. Guard against a missing external root (skip, don't crash).

- [ ] **Step 1: Failing tests** — a change under an enabled external root → `{:icm_changed}`; after disabling that mount and a `{:mounts_changed}`, changes under that root no longer broadcast; a missing external root does not crash the watcher; queue/embedded watching still works.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): watch enabled external mount roots`

---

### Task 6: MOUNTS.md shows external location + abs @-ref

**Files:**
- Modify: `backend/lib/valea/mounts/mounts_md.ex`
- Test: extend `backend/test/valea/mounts/mounts_md_test.exs`

For an external mount, the block shows the display name, description, and the REAL location ("Company — mounted from ~/Business/company-icm") with an `@<resolved-abs>/AGENTS.md` reference (so both Valea-run and bare sessions can navigate there). Embedded mounts unchanged (`@mounts/<name>/AGENTS.md`). Degraded external mounts (missing ref) appear under "Needs attention" with the not-found reason and no @-ref.

- [ ] **Step 1: Failing tests** — an enabled external mount renders its real path + abs @-ref; an embedded mount still renders the relative form; a degraded (missing-ref) external mount shows the reason, no @-ref.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): MOUNTS.md renders external mount real locations`

---

### Task 7: Mounts doctor section

**Files:**
- Create: `backend/lib/valea/mounts/doctor.ex`
- Test: `backend/test/valea/mounts/doctor_test.exs`

Mirror the `Valea.Agents.Doctor` / `Valea.Mail.Doctor` shape (`%{checks: [%{"id"|"label"|"status"|"detail"|"remedy"}], ok}`). Per external mount: `ref_resolves` (path exists + passes guardrails), `manifest_ok`, `secrets_hygiene` (warn `"failed"` if a `secrets/` dir or `.env`-like file exists at the mount root), `watcher_live` (best-effort: the mount root is in the current watched set). Embedded mounts get a lighter check (manifest_ok). A degraded mount surfaces its reason. Never leaks file contents; paths are fine to show (they're user-declared).

- [ ] **Step 1: Failing tests** — a healthy external mount → all ok; a missing ref → ref_resolves failed + later checks unknown; a mount root containing `secrets/` → secrets_hygiene failed with the warning remedy; embedded mount → manifest_ok only.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): mounts doctor (resolve/manifest/secrets/watcher)`

---

### Task 8: Mounts RPCs — declare/undeclare + doctor + audit

**Files:**
- Modify: `backend/lib/valea/api/mounts.ex` (add `declare_mount`, `undeclare_mount`, `mounts_doctor`)
- Modify: `backend/lib/valea/mounts.ex` — `declare_external/3` + `undeclare/2` (config writers) + audit calls
- Run: `just codegen`; commit regenerated client
- Test: extend `backend/test/valea_web/mounts_rpc_test.exs`

Actions (generation-guarded mutations; string-key boolean returns):

| rpc | args | returns |
| --- | --- | --- |
| `declare_mount` | name, ref, generation | `declared: boolean` (string-key) — calls `External.validate_ref` (map errors), then writes `mounts.<name>: {kind: path, ref, enabled: true}` to config, regenerate MOUNTS.md, audit `mount_declared` (name + resolved path), broadcast `{:mounts_changed}` |
| `undeclare_mount` | name, generation | `undeclared: boolean` — remove the config entry only (never touch the folder), regenerate, audit `mount_disabled`?/`mount_undeclared`, broadcast |
| `mounts_doctor` | generation | `checks: [raw]`, `ok` (string-key) |

Also: `set_mount_enabled` (Plan A) now audits `mount_enabled`/`mount_disabled` with the resolved path when the mount is external. `Mounts.declare_external(ws, name, ref)` validates + writes config preserving other entries. Un-declare is config-only.

- [ ] **Step 1: Failing tests** — declare_mount with a valid ref writes config + regenerates MOUNTS.md + audits + broadcasts; an invalid ref (inside workspace) → error code, no config change; undeclare removes the entry, leaves the folder; mounts_doctor returns the section; enable/disable of an external mount is audited with the path.
- [ ] **Step 2: implement + codegen.**
- [ ] **Step 3: Green → format → commit** — `feat(backend): declare/undeclare external mounts + mounts doctor RPC`

---

### Task 9: Onboarding + Knowledge — by-reference adoption

**Files:**
- Modify: `frontend/src/lib/components/onboarding/*` — adopt-by-reference becomes the DEFAULT adoption path (from Plan A's ICM-aware onboarding): pointing the open dialog at an ICM offers "Use it where it is" (declare kind:path) first, "Move it in" second
- Modify: `frontend/src/routes/knowledge/…` (or the mounts UI) — "Add existing" gains "Mount a folder from elsewhere…" (directory picker → `declare_mount`); external mounts show their real location; a doctor/mounts panel surfaces `mounts_doctor`
- Modify: `frontend/src/lib/stores/mounts.svelte.ts` — `declare(name, ref, gen)`, `undeclare(name, gen)`, `doctor(gen)` wrappers
- Test: extend onboarding + mounts pure-logic/store tests

Use the desktop directory picker (Tauri dialog — already a dependency) for choosing an external folder; in browser dev, a path text input with the "dev only" note. The onboarding adoption branch (kind:"icm" from `inspect_path`, Plan A T16) now defaults to reference, with move as the secondary choice.

- [ ] **Step 1: Failing tests** — MountsStore declare/undeclare/doctor call the right RPCs; onboarding adoption logic defaults to reference for an ICM; the Knowledge "mount from elsewhere" flow validates + declares.
- [ ] **Step 2: implement → `bun run test` + `bun run check` 0 errors.**
- [ ] **Step 3: Commit** — `feat(frontend): mount an external ICM folder by reference`

---

### Task 10: Docs + acceptance sweep

**Files:**
- Modify: `docs/ARCHITECTURE.md` — external mounts section (config model, root-set containment, settings allows, physical paths, doctor, watcher)
- Modify: `docs/VISION.md` — first-run promise evolves to "folders you own" (workspace + external knowledge modules); roadmap note
- Acceptance sweep: backend `mix test` (counts), frontend `bun run test` + `bun run check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`
- [ ] **Step 1: Docs edits.**
- [ ] **Step 2: Sweep with recorded counts.**
- [ ] **Step 3: Commit** — `chore: by-reference mounts — architecture docs + acceptance`

---

## Self-Review (authoring)

- **Spec coverage:** config model + guardrails (T1), Mounts merge + collision (T2), root-set containment (T3), settings allows (T4), external watchers (T5), MOUNTS.md real locations (T6), doctor incl. secrets hygiene (T7), declare/undeclare/doctor RPCs + audited boundary changes (T8), onboarding + Knowledge by-reference (T9), docs + acceptance (T10). Multi-workspace sharing needs no code (files are truth + existing base-hash guard) — covered by a test in T2 and the acceptance scenario in T10.
- **Depends on Plan A seams:** the `mount` struct with `rel_root` (nil for external), the `mounts_changed` topic, `Mounts.enabled/list/mount_for/set_enabled`, the mounts RPC resource, `MountsMd.regenerate`, and Plan A T2's requirement that the config reader PRESERVE `kind`/`ref` keys. If Plan A is not yet merged, this plan sequences strictly after it.
- **Type consistency:** external mount uses the SAME `Valea.Mounts.mount` shape (rel_root: nil, root: abs); `extra_roots` (T3) derived from `Mounts.enabled` where `rel_root == nil`; `validate_ref` reason atoms (T1) mapped to RPC error codes (T8).
- **Boundary invariants restated for the reviewer:** deny-list unchanged and still wins; write containment unchanged (staging only); external roots are read-only-by-policy for the agent except via ask-gated Write/Edit; every declare/enable/disable audited; no external-folder mutation by Valea.
