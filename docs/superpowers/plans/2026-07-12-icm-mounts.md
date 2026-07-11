# ICM Mounts & Workspace Shell Implementation Plan (ICM Plan A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Valea from a single hardcoded `icm/` tree into an all-are-mounts model — the workspace is a standard operational shell, and every ICM is a uniform portable capability module discovered under `mounts/<name>/` — per `docs/superpowers/specs/2026-07-12-icm-mounts-design.md` (READ IT for any ambiguity).

**Architecture:** A new `Valea.Mounts` module is the single composition point: it discovers mounts (a `mounts/<name>/` dir with a parseable `icm.yaml`), reads workspace-side relationship state (`config/workspace.yaml` `mounts:`), and exposes the effective enabled-mount list with resolved roots + manifest metadata. Every existing consumer (`Valea.ICM`, `Valea.Workflows`, `Valea.ICM.References`, the watcher, the permission policy's `read_roots`, the ICM RPC surface, the frontend Knowledge tree) is generalized from "the `icm/` root" to "a mount root, keyed by mount name". The agent boundary is unchanged (everything stays under the workspace root); only the set of reference roots grows per enabled mount.

**Tech Stack:** Elixir 1.15+/OTP, Phoenix 1.8, Ash 3 + AshSqlite + ash_typescript, yaml_elixir, file_system, SvelteKit/Svelte 5 runes, Tailwind v4.

## Global Constraints

Binding on every task; the spec is the source of truth when in doubt.

- **All-are-mounts, no privileged `icm/`.** There is no top-level `icm/` after this plan. Every ICM lives at `mounts/<name>/`. The workspace shell owns `queue/`, `sources/`, `logs/`, `config/`, `secrets/`, rules-`AGENTS.md`, and the generated `MOUNTS.md` — no knowledge, no workflows.
- **Discovery is truth for embedded mounts.** A `mounts/<name>/` directory containing a parseable `icm.yaml` (with a non-empty `name`) is a mount. `config/workspace.yaml` `mounts:` holds ONLY relationship state (`enabled`); never ICM identity. Absent config section or absent entry ⇒ enabled.
- **Path-native namespacing.** The workspace-relative path (`mounts/<name>/Offers/X.md`) is the one vocabulary across agent, editor, policy, audit, and disk. No alias layer.
- **ICM-relative references inside a mount.** A workflow's `sources:` and a page's links resolve ICM-relative first (against the contract's own mount root), workspace-relative second. Both stay inside `Paths.resolve_real` containment.
- **Agent boundary unchanged.** Managed `.claude/settings.json` deny rules (`secrets/`, `logs/`, `.claude/`, `app.sqlite*`) and the `Read(./**)` cwd-scoped allow are untouched. Symlink-escape denial (`resolve_real`, realpath-before-`..`) unchanged. `read_roots` = `sources` + `mounts/<name>` per enabled mount (no more `icm`, no more `prompts` at the root — `prompts/` moves inside the mount).
- **Migration never deletes or overwrites a user-modified file.** v3→v4 uses byte-preserving `File.rename` (an explicit contract clarification to add to the module doc) and pristine-hash detection for the root `AGENTS.md`, mirroring the v2/v3 posture. Version marker written LAST (crash-idempotent re-run).
- **Frontmatter injection hardening unchanged** (C0/DEL rejection in every YAML value path).
- **Manifest format:** `icm.yaml` carries `format: 1`, `id: <uuid4>`, `name:`, `description:`. Unknown keys ignored. `id` is provenance, NOT identity — the mount's path/name is its identity; duplicate ids across mounts are allowed.
- Backend: `mix format` clean, `mix test` green, no compiler warnings. Frontend: `bun run check` 0 errors, `bun run test` green.
- Commits end with trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Never push to origin.
- Run backend tests from `backend/`, frontend from `frontend/`.

## File Structure (locked decomposition)

```
backend/lib/valea/
  mounts.ex                 # NEW — discovery + relationship state + effective mount list (T2)
  mounts/manifest.ex        # NEW — icm.yaml parse/validate/write (T1)
  mounts/mounts_md.ex       # NEW — MOUNTS.md generation (T7)
  icm.ex                    # MODIFY — generalize icm_root/0 → per-mount root context (T3)
  icm/references.ex         # MODIFY — ICM-relative within a mount (T4)
  icm/watcher.ex            # MODIFY — watch mounts/ + queue; mounts-level rescan event (T6)
  workflows.ex              # MODIFY — union over enabled mounts, provenance (T5)
  workflows/runner.ex       # MODIFY — sources: ICM-relative-first resolution (T5)
  workspace/scaffold.ex     # MODIFY — v4 markers + starter mount + MOUNTS.md (T8)
  workspace/migration.ex    # MODIFY — v3→v4 (T9)
  workspace/runtime.ex      # MODIFY — watcher args, mount change notifications (T6)
  agents/permission_policy.ex # MODIFY — read_roots default; docstring (T10)
  agents/session_server.ex  # MODIFY — compute per-mount read_roots at session start (T10)
  api/icm.ex                # MODIFY — tree grouped by mount; error map (T11)
  api/mounts.ex             # NEW — mounts RPCs: list/enable/disable/create/adopt (T12)
  api.ex                    # MODIFY — register Mounts resource + rpc_actions (T12)
  cockpit.ex / api/cockpit.ex # MODIFY — seeded workflow path from discovery (T13)
  mail/doctor.ex            # MODIFY — workflow_contract scans registry (T13)
backend/priv/workspace_template/  # v4: no icm/, mounts/<starter>/, rules AGENTS.md, MOUNTS.md (T8)
frontend/src/lib/stores/mounts.svelte.ts   # NEW — MountsStore (T14)
frontend/src/lib/stores/icm.svelte.ts      # MODIFY — grouped tree (T14)
frontend/src/routes/knowledge/…            # MODIFY — per-mount sections, deactivated group (T15)
frontend/src/lib/components/onboarding/…   # MODIFY — ICM-aware adoption (T16)
frontend/src/lib/components/today/*, mail/* # MODIFY — workflow path from payload (T13/T15)
```

Task order: T1 manifest → T2 Mounts core → T3 ICM per-mount → T4 references → T5 workflows/runner → T6 watcher → T7 MOUNTS.md → T8 template+scaffold → T9 migration v4 → T10 read_roots → T11 ICM RPC grouping → T12 mounts RPCs → T13 seeded-path indirection (cockpit/doctor) → T14 FE stores → T15 Knowledge UI → T16 onboarding adoption → T17 docs + acceptance sweep.

---

### Task 1: `Valea.Mounts.Manifest` (icm.yaml)

**Files:**
- Create: `backend/lib/valea/mounts/manifest.ex`
- Test: `backend/test/valea/mounts/manifest_test.exs`

**Interfaces (Produces):**
```elixir
defmodule Valea.Mounts.Manifest do
  defstruct format: 1, id: nil, name: nil, description: nil
  # load a mount dir's icm.yaml
  @spec load(icm_root :: String.t()) ::
          {:ok, %Manifest{}} | {:error, :missing | {:invalid, String.t()}}
  # render a fresh manifest (for scaffold/create/migration); id/name/description in
  @spec render(%{id: String.t(), name: String.t(), description: String.t()}) :: String.t()
  # write! atomically (tmp+rename) to <icm_root>/icm.yaml
  @spec write!(icm_root :: String.t(), attrs :: map()) :: :ok
end
```
Rules: `load/1` reads `<icm_root>/icm.yaml` via `YamlElixir.read_from_file`; `{:error, :missing}` when absent; `{:error, {:invalid, reason}}` when unparseable or `name` blank/non-string; `format` defaults to 1 if absent, `description` to `""`. Unknown keys ignored. `render/1` emits the four keys with YAML-string escaping (reuse the C0/DEL-rejecting `Valea.Mail.Settings`-style `yaml_string` shape — extract a shared `Valea.Yaml.escape/1` if cleanest, or inline; do not import Mail).

- [ ] **Step 1: Failing tests** — valid manifest round-trips (write! then load equal); missing file → `:missing`; blank `name` → `{:invalid, _}`; unknown key ignored; `format` defaults to 1; a `name` containing `\n` is rejected/escaped (injection).
- [ ] **Step 2–4: verify fail → implement → green + `mix format` + full `mix test`.**
- [ ] **Step 5: Commit** — `feat(backend): ICM manifest (icm.yaml) parse/render/write`

---

### Task 2: `Valea.Mounts` core — discovery + relationship state + effective list

**Files:**
- Create: `backend/lib/valea/mounts.ex`
- Test: `backend/test/valea/mounts_test.exs`

**Interfaces:**
- Consumes: `Manifest.load/1` (T1).
- Produces (binding — every later task reads these):

```elixir
defmodule Valea.Mounts do
  # A resolved mount. `root` is the ABSOLUTE path; `rel_root` is
  # workspace-relative ("mounts/<name>"). `enabled` from config. `degraded`
  # carries a reason string when the manifest is missing/broken (still listed
  # for the UI, excluded from the effective set).
  @type mount :: %{
          name: String.t(),           # mounts/<name> dir basename = the mount name/identity
          rel_root: String.t(),       # "mounts/<name>"
          root: String.t(),           # absolute
          manifest: %Valea.Mounts.Manifest{} | nil,
          enabled: boolean(),
          degraded: String.t() | nil
        }

  # ALL discovered mounts (enabled + disabled + degraded), sorted by name.
  @spec list() :: {:ok, [mount]} | {:error, :no_workspace}
  @spec list(workspace :: String.t()) :: [mount]   # pure form for tests/callers with a root

  # Only enabled, non-degraded mounts. THE composition set.
  @spec enabled() :: {:ok, [mount]} | {:error, :no_workspace}
  @spec enabled(workspace :: String.t()) :: [mount]

  # Resolve a workspace-relative path to the mount that owns it (or nil).
  @spec mount_for(rel_path :: String.t()) :: {:ok, mount} | {:error, :not_in_mount | :no_workspace}
  @spec mount_for(workspace :: String.t(), rel_path :: String.t()) :: mount | nil

  # Relationship-state mutation (updates config/workspace.yaml mounts: section).
  @spec set_enabled(name :: String.t(), boolean()) :: :ok | {:error, term()}
end
```

Discovery: `Path.wildcard(Path.join(workspace, "mounts/*"))` |> filter `File.dir?` |> for each, `Manifest.load(dir)` — `{:ok, m}` with non-blank name ⇒ mount; `{:error, reason}` ⇒ degraded mount (still listed). `enabled` from `read_config_mounts(workspace)[name]["enabled"]`, default `true` when absent.

Config read/write: `config/workspace.yaml` parsed with YamlElixir; `set_enabled/2` reads the current YAML map, sets `mounts.<name>.enabled`, writes back atomically PRESERVING `version`/`id` and any reserved keys (`kind`/`ref`) — round-trip through a small renderer that keeps unknown mount keys. (A mount name is a safe basename — reject names with `/`/`..`.)

- [ ] **Step 1: Failing tests** (tmp workspaces built by hand): two valid mounts + one manifest-less dir → `list/1` has 3 (one degraded), `enabled/1` has 2; a config `mounts: {b: {enabled: false}}` → `enabled/1` excludes b, `list/1` still shows b as disabled; `mount_for/2` maps `mounts/a/Offers/X.md` → mount a, `sources/x` → nil; `set_enabled` round-trips and preserves `version`/`id` + a reserved `kind:` key on another mount; degraded mount never appears in `enabled/1`.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): Valea.Mounts — discovery, relationship state, effective set`

---

### Task 3: Generalize `Valea.ICM` to per-mount roots

**Files:**
- Modify: `backend/lib/valea/icm.ex` (replace `icm_root/0` with a mount-root resolver)
- Test: extend `backend/test/valea/icm_test.exs`

**Interfaces:**
- Consumes: `Mounts.mount_for/2`, `Mounts.enabled/1` (T2).
- Produces: `Valea.ICM` public functions keep their SAME names/arities but now accept/return workspace-relative paths under `mounts/<name>/…` instead of `icm/…`. `tree/0` returns a LIST of per-mount trees (see below). `page/1`, `save_page/3`, `create_page/2`, `create_folder/2`, `rename/2`, `delete/1` take a full `mounts/<name>/…` rel path.

Change `icm_root/0` (currently `Path.join(ws, "icm")`) → `mount_root_for(rel_path)`:
```elixir
# resolve the mount that owns rel_path; containment is then checked against
# THAT mount's root, exactly as before but per-mount.
defp mount_root_for(rel_path) do
  with {:ok, mount} <- Mounts.mount_for(rel_path) do
    {:ok, mount.root}         # absolute mount root; `contain/2` unchanged below it
  end
end
```
`tree/0` becomes:
```elixir
# returns {:ok, [%{mount: name, title: manifest_name, root_rel: "mounts/<name>", tree: <node>}]}
# one entry per ENABLED mount; the per-mount `tree` node is the existing build_tree output
def tree do
  with {:ok, mounts} <- Mounts.enabled() do
    {:ok, Enum.map(mounts, fn m ->
      %{mount: m.name, title: m.manifest.name, root_rel: m.rel_root,
        tree: build_tree(m.root, m.root)}
    end)}
  end
end
```
`contain/2`, `build_tree/2`, `split_frontmatter/1`, name validation, hashing — UNCHANGED (they already take a root). Rel paths returned in nodes must be workspace-relative (`mounts/<name>/…`), so `build_tree` node paths are prefixed with `m.rel_root` (or keep build_tree mount-relative and prefix at the tree/0 boundary — pick one, be consistent). The moduledoc's "the icm/ tree" wording updates to "each mounted ICM tree".

- [ ] **Step 1: Failing tests** — with two enabled mounts, `tree/0` returns 2 entries with correct titles + `mounts/<name>/…` node paths; `page("mounts/a/Offers/X.md")` reads mount a's file; a path in a DISABLED mount → `{:error, :not_found}` (not in `enabled`, `mount_for` still resolves but page gates on enabled? — DECISION: `page/1` resolves via `mount_for` regardless of enabled so the editor can still open a disabled mount's page if the UI ever allows it; enabled-gating is a read_roots/agent concern, not an editor one — assert page reads a disabled mount fine, and document it); create/rename/delete/save operate within the resolving mount's containment; a `..` escape across mount boundary is denied.
- [ ] **Step 2–4: implement → green → format → full test** (many ICM tests will need path updates from `icm/…` to `mounts/<name>/…` — update fixtures, do not weaken assertions).
- [ ] **Step 5: Commit** — `feat(backend): ICM operates per-mount root; tree grouped by mount`

---

### Task 4: `Valea.ICM.References` — ICM-relative within a mount

**Files:**
- Modify: `backend/lib/valea/icm/references.ex`
- Test: extend `backend/test/valea/icm/references_test.exs`

Currently references scan `{workspace}/icm/Workflows/*.md` for the literal `icm/<rel>`. Generalize: a reference from a workflow in mount M is ICM-relative to M (the literal `<rel>` relative to M's root), so `referencing_workflows/1` and `rewrite/2` operate within a mount. Signature adjustment:
```elixir
# rel_path is now workspace-relative "mounts/<name>/<inner>"; resolve its mount,
# scan THAT mount's Workflows/ for the ICM-relative needle "<inner>", rewrite in place.
@spec referencing_workflows(rel_path :: String.t()) :: {:ok, [String.t()]} | {:error, term}
@spec rewrite(old_rel :: String.t(), new_rel :: String.t()) :: {:ok, non_neg_integer} | {:error, term}
```
Both old_rel/new_rel must be in the SAME mount (a rename never crosses mounts). The needle is the mount-relative inner path, not `icm/<rel>`. Update the moduledoc accordingly.

- [ ] **Step 1: Failing tests** — a workflow in mount a whose `sources:` lists `Offers/X.md` (ICM-relative) is found by `referencing_workflows("mounts/a/Offers/X.md")`; `rewrite` updates it to the new inner path; a same-named page in mount b is NOT matched (mount isolation).
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): ICM references are ICM-relative within a mount`

---

### Task 5: `Valea.Workflows` union + `Runner` ICM-relative-first `sources:`

**Files:**
- Modify: `backend/lib/valea/workflows.ex` (union over enabled mounts, provenance)
- Modify: `backend/lib/valea/workflows/runner.ex` (`sources:` resolution)
- Test: extend `backend/test/valea/workflows_test.exs`, `backend/test/valea/workflows/runner_test.exs`

`Workflows.list/0`: replace the single `@dir "icm/Workflows"` glob with a union over `Mounts.enabled()` — for each mount, glob `<mount.root>/Workflows/*.md`, parse, and set `path` to the workspace-relative `mounts/<name>/Workflows/<file>` and a new `mount` field = `manifest.name` (provenance). Sort by `path`. `get/1` resolves the owning mount from the path and validates `under <mount>/Workflows/`.

`Runner.run/2`'s `sources:`/input handling: when resolving a workflow's declared `sources:` entries, try ICM-relative (against the contract's mount root) first, then workspace-relative; both through `resolve_real` containment. (Today `sources:` are only read by the agent, not the Runner — confirm; if the Runner does not itself resolve `sources:`, then this task only updates the workflow `path`/registry and the prompt text that names the input, and the ICM-relative-first rule is documented as the agent-facing convention in the mount `AGENTS.md` template — do the minimal correct thing and note it in the report.)

- [ ] **Step 1: Failing tests** — two enabled mounts each with a `Workflows/` page → `list/0` returns both with distinct `path` + `mount` provenance; same workflow filename in both coexists (no shadow); disabling a mount drops its workflows from `list/0`; `get("mounts/a/Workflows/X.md")` returns it, `get` on a disabled mount's path → still resolvable? (match T3's decision — registry uses `enabled`, so `list/0` excludes disabled, but `get/1` by explicit path may still parse; assert the chosen behavior).
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): workflow registry unions enabled mounts with provenance`

---

### Task 6: Watcher watches `mounts/` + mount-change notifications

**Files:**
- Modify: `backend/lib/valea/icm/watcher.ex`
- Modify: `backend/lib/valea/workspace/runtime.ex` (watcher child args)
- Test: extend `backend/test/valea/icm/watcher_test.exs`

The watcher currently watches `{ws}/icm` + `{ws}/queue`. Change to watch `{ws}/mounts` + `{ws}/queue`. A change under `mounts/` broadcasts `{:icm_changed}` on `"icm"` (unchanged event — consumers refetch the grouped tree). ADD: a change to a `mounts/*/icm.yaml` OR a top-level `mounts/*` dir add/remove ALSO broadcasts `{:mounts_changed}` on a new `"mounts"` topic (discovery/enabled-set may have changed → `read_roots`, registry, MOUNTS.md must recompute). Keep the per-tree debounce discipline (separate timer for mounts vs queue). Runtime passes `Path.join(root, "mounts")` instead of `Path.join(root, "icm")`.

- [ ] **Step 1: Failing tests** — a write under `mounts/a/Offers/X.md` → `{:icm_changed}`; adding `mounts/b/icm.yaml` → both `{:icm_changed}` and `{:mounts_changed}`; queue change still → `{:queue_changed}`; debounce isolation preserved.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): watch mounts/; emit mounts_changed on discovery changes`

---

### Task 7: `MOUNTS.md` generation

**Files:**
- Create: `backend/lib/valea/mounts/mounts_md.ex`
- Test: `backend/test/valea/mounts/mounts_md_test.exs`

**Interface:**
```elixir
# Regenerate <workspace>/MOUNTS.md from the current enabled/degraded mount set.
# Atomic tmp+rename. Called at scaffold, migration, mount enable/disable, and on
# {:mounts_changed}. Format: a generated-file header note + one block per enabled
# mount (### <manifest.name>\n<description>\npath: mounts/<name>\n@mounts/<name>/AGENTS.md),
# then a "Deactivated" list, then a "Needs attention" list for degraded mounts (with reason,
# no @-ref). Managed by Valea; agent-readable.
@spec regenerate(workspace :: String.t()) :: :ok
```

- [ ] **Step 1: Failing tests** — two enabled + one disabled + one degraded → the file has an @-ref for each enabled mount's AGENTS.md, lists the disabled one under Deactivated, lists the degraded one with its reason and NO @-ref; regeneration is atomic (no `.tmp` left); idempotent (same input → identical bytes).
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): MOUNTS.md generation`

---

### Task 8: Workspace template v4 + Scaffold

**Files:**
- Modify template under `backend/priv/workspace_template/`: DELETE the top-level `icm/` and `prompts/`; CREATE `mounts/starter/` containing the former `icm/` contents (AGENTS.md self-description, CLAUDE.md, Workflows/*, the seeded pages) + `prompts/` (moved in) + a template `icm.yaml` (`format: 1`, `id: TEMPLATE`, `name: "Starter"`, description); rewrite root `AGENTS.md`/`CLAUDE.md` to rules-only (hard rules, proposal contract, shell map, `@MOUNTS.md`); add a template `MOUNTS.md`.
- Modify: `backend/lib/valea/workspace/scaffold.ex` — `@marker_dirs` becomes `~w(mounts queue logs queue/staging queue/processing)` (drop `icm`); after `cp_r`, mint the starter mount's real `icm.yaml` (fresh uuid, name = the workspace name passed to `create/2` — thread it through), rename `mounts/starter` → `mounts/<slug-of-name>`, and generate `MOUNTS.md` via `MountsMd.regenerate`.
- Test: extend `backend/test/valea/workspace/scaffold_test.exs`

`Scaffold.create/1` currently takes only `target`. Add the workspace name: `create(target, name)` (onboarding already collects a name). Slug the name for the mount dir (lowercase, ascii, `-`). If `create/1` callers exist, add a default `name = Path.basename(target)`.

**Interfaces (Produces):** `Scaffold.valid?/1` now checks the new marker set; `Scaffold.create/2`.

- [ ] **Step 1: Failing tests** — fresh scaffold has `mounts/<slug>/icm.yaml` (real uuid, given name), no top-level `icm/` or `prompts/`, root `AGENTS.md` contains `@MOUNTS.md` and NOT the proposal-example pages, `MOUNTS.md` lists the starter mount, `valid?/1` true; the starter mount's `AGENTS.md` is self-describing (its own map, not the shell rules).
- [ ] **Step 2–4: implement → green (MANY existing tests scaffold workspaces and reference `icm/…` — update them to `mounts/<slug>/…`; the slug for `Path.basename(tmp)` is deterministic) → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): workspace template v4 — all-are-mounts scaffold`

---

### Task 9: Migration v3 → v4

**Files:**
- Modify: `backend/lib/valea/workspace/migration.ex` (`@current_version 4`, `ensure_v4/2`)
- Test: extend `backend/test/valea/workspace/migration_test.exs`

`ensure_v4(root, v)` (runs after `ensure_v3`; each step idempotent; version marker written LAST):
1. If `icm/` exists and `mounts/<slug>/` does not: `File.rename(icm, mounts/<slug>)` where slug = slug of `Path.basename(root)`; if target exists, append `-2`,`-3`,…. **Add to the module doc: "byte-preserving renames are permitted; the never-delete/never-overwrite contract forbids destroying or clobbering CONTENT, not relocating a tree."**
2. If `prompts/` exists and `mounts/<slug>/prompts/` does not: `File.rename` it inside the mount.
3. Write `mounts/<slug>/icm.yaml` (fresh uuid, name from `Path.basename(root)`) only if absent; write the mount `AGENTS.md` from template only if absent.
4. Root `AGENTS.md`: pristine (v3 seed sha — compute + hardcode from the CURRENT template before T8 edits it, `git show HEAD:...`) → replace with the rules-only v4 version; modified → leave + `Valea.Audit` `migration_note` + doctor warning (same posture as v3 triage-page rule).
5. `MountsMd.regenerate(root)`.
6. Ensure `mounts/` marker dir exists; write `config/workspace.yaml` version 4 (+ preserve id) LAST.

- [ ] **Step 1: Failing tests** — build a v3 workspace from OLD template bytes (embed as fixtures): migrate → `icm/` gone, `mounts/<slug>/` present with manifest + moved prompts, root AGENTS.md replaced (pristine) or preserved (modified) + audited, `MOUNTS.md` present, version 4; re-run is a no-op; a target-name collision appends `-2`; v1→v4 and v2→v4 chains still pass.
- [ ] **Step 2–4: implement → green (full suite — every workspace-open test now migrates to v4) → format.**
- [ ] **Step 5: Commit** — `feat(backend): workspace v3→v4 migration — icm/ → mounts/<slug>/`

---

### Task 10: Per-mount `read_roots`

**Files:**
- Modify: `backend/lib/valea/agents/permission_policy.ex` (`@default_read_roots`, docstring)
- Modify: `backend/lib/valea/agents/session_server.ex` (compute read_roots at session start)
- Test: extend `backend/test/valea/agents/permission_policy_test.exs`, session tests

`@default_read_roots` becomes `["sources"]` (drop `icm`, `prompts`). The session's `policy_ctx.read_roots` is computed at session start as `["sources"] ++ Enum.map(Mounts.enabled(ws), & &1.rel_root)` (each `"mounts/<name>"`). Where sessions are started (`Valea.Agents.start_session` / Runner), populate `read_roots` from `Mounts.enabled`. The policy's `all_in_read_roots?` already checks `top in read_roots` — `mounts/x` is a two-segment root, so extend the top-segment check to match multi-segment roots (compare the leading path components, not just the first). A disabled mount is absent from read_roots ⇒ its reads ask-gate.

- [ ] **Step 1: Failing tests** — policy allows a read under `mounts/a/…` when `mounts/a` ∈ read_roots; denies (ask) a read under `mounts/b/…` when b is disabled/absent; `sources/…` still allowed; deny-list (`secrets/…`) still wins; a two-segment root `mounts/a` correctly matches `mounts/a/Offers/X.md` but not `mounts/ab/…` (prefix-boundary correctness). Session-start test: an enabled mount appears in the started session's `read_roots`.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): per-mount agent read roots`

---

### Task 11: ICM RPC returns grouped tree

**Files:**
- Modify: `backend/lib/valea/api/icm.ex` (the `:tree` action + any path-shaped returns)
- Run: `just codegen`; commit regenerated `ash_rpc.ts`
- Test: extend `backend/test/valea_web/icm_rpc_test.exs`

The `:tree` action's constrained return becomes a list of mount groups: `{ mounts: [{ mount, title, rootRel, tree }] }` (typed map; `tree` node shape unchanged). `page`/`save`/`create`/`rename`/`delete` args are already path strings — now `mounts/<name>/…`; no signature change, just the values. Keep the casing/typing conventions of the existing resource (see its moduledoc). Error map unchanged.

- [ ] **Step 1: Failing tests** — `icm_tree` returns groups per enabled mount with titles; `icm_page("mounts/<slug>/…")` round-trips; codegen not stale.
- [ ] **Step 2: Implement + `just codegen` (frontend type errors expected until T14).**
- [ ] **Step 3: Green (backend) → format → commit** — `feat(backend): ICM tree RPC grouped by mount`

---

### Task 12: Mounts RPC surface

**Files:**
- Create: `backend/lib/valea/api/mounts.ex`
- Modify: `backend/lib/valea/api.ex` (register resource + rpc_actions)
- Run: `just codegen`; commit regenerated client
- Test: `backend/test/valea_web/mounts_rpc_test.exs`

Actions (mirror `Valea.Api.Queue`/`Mail` patterns; generation guards on mutations; string-key boolean returns per the ash_typescript 0.17.3 workaround):

| rpc | args | returns |
| --- | --- | --- |
| `list_mounts` | – | `mounts: [typed]` (name, title, description, relRoot, enabled, degraded) from `Mounts.list()` |
| `set_mount_enabled` | name, enabled, generation | `saved: boolean` (string-key); calls `Mounts.set_enabled` then `MountsMd.regenerate` + broadcast `{:mounts_changed}` |
| `create_mount` | name, description, generation | `relRoot: string` — scaffold a new empty `mounts/<slug>/` (manifest + AGENTS.md skeleton) via a new `Mounts.create/3`; regenerate MOUNTS.md |

Add `Valea.Mounts.create(workspace, name, description) :: {:ok, mount} | {:error, term}` (mints uuid, writes manifest + a minimal self-describing AGENTS.md, mkdir the dir). Onboarding "adopt-by-move" (spec A) is handled at the Manager/onboarding layer in T16, not here.

- [ ] **Step 1: Failing tests** — list returns discovered mounts incl. degraded flag; set_mount_enabled toggles config + regenerates MOUNTS.md + broadcasts (assert on `"mounts"` topic); create_mount makes a valid new mount that `Mounts.list` then shows; workspace_changed/not_open mapping.
- [ ] **Step 2: Implement + codegen.**
- [ ] **Step 3: Green → format → commit** — `feat(backend): mounts RPC surface (list/enable/create)`

---

### Task 13: Seeded-workflow path indirection (cockpit + doctor)

**Files:**
- Modify: `backend/lib/valea/cockpit.ex` + `backend/lib/valea/api/cockpit.ex` — today payload's triage card carries the seeded workflow's REAL path (discover it: the first enabled mount's `Workflows/New Inquiry Triage.md` if present) instead of a hardcoded `icm/…`
- Modify: `backend/lib/valea/mail/doctor.ex` — `workflow_contract` scans the workflow registry (`Workflows.list/0`) for a triage-shaped workflow instead of the hardcoded `icm/Workflows/New Inquiry Triage.md`
- Test: extend cockpit + mail doctor tests

The cockpit payload gains `triage_workflow_path` (the discovered path, or nil). The doctor's contract check iterates registry entries and warns if any references the legacy `normalized/`/`.json` input. Remove the hardcoded `@triage_rel`-style constants from these consumers (migration.ex keeps its own for the pristine-hash check — that's a different concern).

- [ ] **Step 1: Failing tests** — cockpit payload carries the real `mounts/<slug>/Workflows/…` triage path; with no such workflow, nil; doctor finds the triage workflow via the registry and passes/warns correctly across mounts.
- [ ] **Step 2–4: implement → green → format → full test.**
- [ ] **Step 5: Commit** — `feat(backend): seeded workflow path via discovery, not hardcoded icm/`

---

### Task 14: Frontend MountsStore + grouped ICM store + client wrappers

**Files:**
- Create: `frontend/src/lib/stores/mounts.svelte.ts`
- Modify: `frontend/src/lib/stores/icm.svelte.ts` (consume grouped tree)
- Modify: `frontend/src/lib/api/client.ts` (wrappers: listMounts, setMountEnabled, createMount)
- Modify: `frontend/src/lib/socket.ts` (`onMountsChanged` handler on the new `"mounts"` topic)
- Test: `frontend/src/lib/stores/mounts.test.ts`, extend `icm.test.ts`

**Interfaces:** `MountsStore` — `mounts: MountSummary[]` (name, title, description, relRoot, enabled, degraded), `refresh()`, `setEnabled(name, enabled, gen)`, `create(name, desc, gen)`, `handleMountsChanged()` (refetch + trigger icm refetch). The ICM store's tree becomes `MountGroup[]` (mount, title, rootRel, tree). Wire the `mounts_changed` push (added to `joinWorkspaceEvents`) → both stores refetch.

- [ ] **Step 1: Failing vitest** — MountsStore populates from mocked api; setEnabled surfaces error codes; handleMountsChanged refetches; ICM store parses grouped tree.
- [ ] **Step 2: implement, `bun run test` + `bun run check` (0 errors now that the client regenerated).**
- [ ] **Step 3: Commit** — `feat(frontend): mounts store + grouped ICM tree`

---

### Task 15: Knowledge UI — per-mount sections, deactivated group, workflow provenance

**Files:**
- Modify: `frontend/src/routes/knowledge/…` (tree renders one section per enabled mount; single-mount collapse; a "Deactivated" collapsed group with re-enable toggles; degraded warning chips; non-md files listed with type icons/preview)
- Modify: `frontend/src/lib/components/workflows/*` (provenance label "· <mount>"), `today/*`, `mail/MessageView.svelte` (TRIAGE_WORKFLOW from the cockpit payload, not a hardcoded const)
- Test: extend the relevant component/pure-logic tests

Single-mount collapse: when exactly one enabled mount, render its tree at top level (visually today). Multiple → a header per mount (title + description). Deactivated mounts sit in a collapsed group; toggling calls `mountsStore.setEnabled`. Non-`.md` files (media/PDF) render as leaf rows with a reveal/preview affordance (open in editor only for `.md`). Workflow cards show the mount provenance chip. Replace the hardcoded `TRIAGE_WORKFLOW` in MessageView/InquiryTriageCard with the path from the cockpit/today payload (T13).

- [ ] **Step 1: Failing tests** (pure-logic where possible, per the repo's no-render-harness convention) — grouping + single-mount collapse decision; deactivated-group inclusion; degraded chip; provenance label; triage path sourced from payload.
- [ ] **Step 2: implement → `bun run test` + `bun run check` 0 errors.**
- [ ] **Step 3: Commit** — `feat(frontend): mounts-aware Knowledge + workflow provenance`

---

### Task 16: ICM-aware onboarding (adopt-by-move)

**Files:**
- Modify: `backend/lib/valea/workspace/manager.ex` (or a new `Valea.Workspace.Adopt`) — a "create workspace adopting an existing ICM folder" path: scaffold a shell, then MOVE the pointed-at ICM dir into `mounts/<slug>/` (consented), validating it has/gets a manifest
- Modify: `frontend/src/lib/components/onboarding/*` — when the open dialog is pointed at a non-workspace dir that IS/contains an ICM (`icm.yaml` present, or knowledge-shaped), offer "Create a workspace around this knowledge module" with a move-consent step showing the original path; never offer copy
- Add: an `inspect_path` RPC (or extend the existing `inspect_workspace`) returning `{kind: "workspace"|"icm"|"other", …}` so the frontend can branch
- Test: backend adopt tests + frontend onboarding pure-logic tests

Adopt-by-move: `Adopt.create_with_icm(parent_dir, name, icm_source_path)` — reject if `icm_source_path` is inside an existing workspace or is the source of a currently-open workspace; scaffold the shell WITHOUT the starter mount (or scaffold then remove starter), `File.rename` the source into `mounts/<slug>/`, ensure a manifest (mint if absent, name from the folder), regenerate MOUNTS.md, open it. Copy is never implemented. (By-reference adoption is Spec A2 — this task does move-only and leaves a clear seam.)

- [ ] **Step 1: Failing tests** — `inspect_path` classifies a workspace dir, an ICM dir (has icm.yaml), and a plain dir; adopt-by-move relocates the folder into `mounts/<slug>/`, mints a manifest if absent, never copies, rejects a source inside a workspace; frontend logic picks the ICM-adoption branch for kind:"icm".
- [ ] **Step 2–4: implement → backend + frontend green → format/check.**
- [ ] **Step 5: Commit** — `feat: ICM-aware onboarding — adopt an existing knowledge folder by move`

---

### Task 17: Docs + VISION principle + acceptance sweep

**Files:**
- Modify: `docs/ARCHITECTURE.md` — replace the ICM/Layer section with the mounts model (workspace shell = Layers 0/1/4, each mount = its own Layers 2/3; discovery; MOUNTS.md; per-mount read_roots; migration v4)
- Modify: `docs/VISION.md` — Principle 2 restated for multi-ICM composition; roadmap notes ICM-mounts shipped-pending-merge
- Acceptance sweep: `cd backend && mix test` (record counts), `cd frontend && bun run test && bun run check`, `mix format --check-formatted`, `mix compile --warnings-as-errors`, `cargo check` (desktop unaffected but confirm)
- [ ] **Step 1: Docs edits.**
- [ ] **Step 2: Full acceptance sweep with recorded counts.**
- [ ] **Step 3: Commit** — `chore: ICM mounts — architecture docs + acceptance`

---

## Self-Review (authoring)

- **Spec coverage:** manifest (T1), discovery+relationship state (T2), per-mount ICM ops (T3), ICM-relative references (T4), registry union + provenance + sources resolution (T5), watcher + mounts_changed (T6), MOUNTS.md (T7), template/scaffold v4 (T8), migration v4 with byte-preserving renames + pristine root AGENTS.md (T9), per-mount read_roots + unchanged deny-list (T10), grouped ICM RPC (T11), mounts RPCs (T12), seeded-path indirection + doctor registry scan (T13), FE stores (T14), Knowledge grouping + single-mount collapse + non-md files + provenance (T15), ICM-aware onboarding adopt-by-move (T16), docs + acceptance (T17). Bare-agent self-sufficiency is a property of the starter mount's `AGENTS.md` authored in T8 (+ manual smoke in T17).
- **Deferred to A2 (by-reference):** external `kind`/`ref` config, root-SET containment, external `Read` allows, physical-path plumbing for external mounts, doctor mounts section, multi-workspace sharing. This plan's config reader (T2) must preserve unknown `kind`/`ref` keys so A2 slots in without rework.
- **Type consistency:** `Mounts.mount` shape (T2) consumed by T3/T5/T7/T10/T12; `tree/0` grouped shape (T3) consumed by T11/T14/T15; `mounts_changed` topic (T6) consumed by T7/T12/T14; provenance `mount` field (T5) consumed by T15.
- **Placeholder scan:** two decisions are flagged for the implementer to settle in-task and record (T3/T5 `page`/`get` behavior on a disabled mount's explicit path; T5 whether the Runner itself resolves `sources:` or only the agent does) — these are genuine "confirm against current code" points, not vague placeholders; each names the exact check.
