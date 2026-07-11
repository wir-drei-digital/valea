# ICM Mounts & Workspace Shell — Design (ICM Spec A of three)

**Date:** 2026-07-12 · **Status:** approved design, pre-plan (phase ordering vs. Calendar to be decided)
**Depends on:** 2026-07-10-agent-slice-design.md (policy contexts, workflows, queue), 2026-07-11-mail-design.md (workspace v3, migration patterns)
**Sibling specs:** Spec A2 — by-reference mounts (2026-07-12-icm-by-reference-design.md; external ICMs referenced in place — the ICM-first journey's end state); Spec B — memory & methodology depth (agent-proposed ICM edits via queue, decision logs); Spec C — Knowledge/editor UX (backlinks UI, templates, search). All build on this spec's structure.

## Goal

Restructure Valea around its two real units: the **workspace** as a standard
operational shell, and **ICMs as uniform, portable capability modules** that
mount into it. An ICM carries knowledge (markdown pages, media, PDFs),
job contracts (`Workflows/`), prompt fragments, and optionally agent tools
(`scripts/`) — mounting one gives the workspace both context and
capabilities, plugin-style. Every ICM must be usable by a bare Claude Code
session with no Valea present; the app is the convenience layer.

## Decisions (from brainstorm)

| Question | Decision |
| --- | --- |
| Model | **All-are-mounts, workspace owns the shell** ("B★ revised"). No privileged `icm/`, no primary pointer: the workspace shell (queue/sources/rules) is the standard interface; every ICM — including the seeded starter — is a uniform mount under `mounts/<name>/`. |
| What an ICM is | **A capability module**: knowledge in any file format + its own `Workflows/` + `prompts/` + optional `scripts/` + self-describing `AGENTS.md`. Workflows travel with the ICM — mounting a module brings its jobs. They stay portable because they target the shell's standardized conventions (`sources/mail/…`, queue paths are identical in every workspace). |
| Storage | **Real directories inside the workspace** (`mounts/<name>/`), provenance-agnostic: hand-made folder, unzipped archive, git clone — Valea doesn't care. By-reference/external mounts are future work; config reserves `kind:`/`ref:` for them. |
| Discovery | **Disk is truth.** A directory under `mounts/` containing a parseable `icm.yaml` is a mount. No registry to drift. |
| Relationship state | **`config/workspace.yaml` `mounts:` section** holds per-workspace relationship state only — today `enabled: false`; never ICM identity. Absent entry = enabled. |
| Writability | Mounts are **living structures**: human and agent may edit them (agent writes stay ask-gated exactly as today). No read-only flag this phase; one is reserved for future by-reference mounts. |
| Namespacing | **Path-native**: the workspace-relative path (`mounts/company/Offers/X.md`) is the one vocabulary across agent, editor, policy, audit, and disk. No alias layer. |
| Instructions | **ICM carries its map, workspace carries rules.** Each ICM ships an `AGENTS.md` describing itself (self-sufficient for bare Claude Code). The workspace root `AGENTS.md` holds the hard rules + proposal contract + shell map, and points at a **generated `MOUNTS.md`** index that routes to each enabled mount's `AGENTS.md`. |
| Deactivation | Per-mount enable/disable, workspace-side. Disabled = files untouched, but out of Knowledge, agent read roots, workflow registry, and reference index. Uniform — any mount can be off. |
| Backward compat | Not a constraint (no production users). Existing demo workspaces migrate via v4; historical audit paths remain historical facts. |

## Non-goals

By-reference/external-path mounts (config fields reserved here; designed
in Spec A2, implementable immediately after this spec). Zip/git import
automation (drop-in is manual; Valea detects). Agent-proposed memory
updates through the queue (Spec B). Backlinks UI, templates, search
(Spec C). Watch-triggers for workflows (Phase 6 — with the recorded rule
that a *mounted* workflow's trigger will require workspace-side opt-in).
Multiple simultaneously open workspaces. In-app git operations.

## Anatomy of an ICM (the portable unit)

```
<icm-root>/                 # mounts/<name>/ in a workspace, or a bare folder anywhere
  icm.yaml                  # manifest — presence makes this an ICM
  AGENTS.md                 # self-description: what this is, folder map, conventions
  CLAUDE.md                 # "@AGENTS.md"
  Workflows/*.md            # job contracts (same frontmatter format as today)
  prompts/                  # reusable prompt fragments (moved INTO the module)
  scripts/                  # optional agent tools, skills-style (run via ask-gated Bash)
  <any folders/files>       # knowledge: .md pages, media, PDFs, anything
```

### icm.yaml (manifest)

```yaml
format: 1                   # manifest format version
id: 6f9f0c9e-…              # uuid4, minted at creation; provenance metadata, NOT identity
name: "Mara Lindt Coaching" # display name
description: "Offers, clients, pricing, tone and policies for the coaching business."
```

Rules: the manifest never carries workspace-relationship state (the same
ICM directory must be shareable untouched). `id` is informational — the
mount's **path is its identity** within a workspace; two mounts may carry
the same `id` (a copied ICM) without conflict. Unknown keys are ignored
(forward compatibility). A missing or unparseable manifest means the
directory is not (or is a *degraded*) mount — see Error handling.

### Portability rules

- **ICM-relative references**: pages and workflow `sources:` refer to the
  ICM's own content by paths relative to the ICM root (`Offers/X.md`), so
  the module works regardless of its mount name or standalone location.
- Shell references (`sources/mail/messages/*.md`, staging output paths)
  use the standard workspace conventions, which are identical in every
  Valea workspace — the shell is the OS API; ICM workflows are programs
  written against it.
- Cross-mount references use full workspace paths (`mounts/other/…`) and
  are expected to break outside the composing workspace — that is the
  author's explicit choice.
- The ICM's own `AGENTS.md` must make the module self-sufficient for a
  bare Claude Code session started at the ICM root.

## Anatomy of the workspace (the operational shell)

```
<workspace>/
  AGENTS.md / CLAUDE.md     # RULES: hard rules, proposal contract, shell map, @MOUNTS.md
  MOUNTS.md                 # GENERATED index of enabled mounts (name, description,
  mounts/<name>/…           #   path, @mounts/<name>/AGENTS.md per mount)
  queue/                    # unchanged (staging/pending/processing/approved/rejected/applied)
  sources/                  # unchanged (mail/, calendar/, files/)
  logs/  secrets/  config/  # unchanged
  app.sqlite                # unchanged (cache)
```

The shell owns **no knowledge and no workflows itself**. `prompts/` leaves
the shell (moves into the starter ICM). The root `AGENTS.md` shrinks to
rules + shell map + the `MOUNTS.md` pointer; everything content-specific
lives in mounts.

### Discovery & lifecycle

- **Scan**: `mounts/*/icm.yaml` — parseable manifest ⇒ mount. The scan runs
  at workspace open and on `mounts/`-level filesystem changes (a watcher on
  `mounts/` itself), so dropping in a folder/clone/unzip appears live.
- **Relationship state** (`config/workspace.yaml`):

  ```yaml
  version: 4
  id: <workspace-uuid>
  mounts:                   # optional; absent section or entry = enabled
    company:
      enabled: false
      # reserved for future: kind: path|git|…, ref: …, writable: …
  ```

- **Lifecycle UX** (Knowledge): "New ICM" scaffolds `mounts/<name>/` with a
  fresh manifest + AGENTS.md skeleton; "Add existing" shows drop-in
  instructions (Valea detects); per-mount enable/disable toggle; removal is
  a filesystem operation the user performs (reveal-in-Finder affordance) —
  **Valea never deletes a mount**.
- **MOUNTS.md generation**: regenerated (atomic write) on every discovery
  change and enable/disable flip. Contents per enabled mount: name,
  description, workspace-relative path, `@mounts/<name>/AGENTS.md`
  reference. Degraded mounts are listed with a warning line and no
  @-reference. Agent-readable, Valea-managed.

## Composition semantics

- **Workflow registry**: `Workflows.list/0` = union over enabled mounts'
  `Workflows/*.md`. Identity = workspace-relative contract path (as today);
  entries carry mount provenance (manifest `name`) for display ("New
  Inquiry Triage · Company"). Same-named workflows in different mounts
  coexist; there is no shadowing. `run_workflow(path, input)` semantics are
  unchanged. Runs remain **manual-trigger only** this phase; recorded rule
  for Phase 6: watch-triggers declared by mounted workflows require
  workspace-side opt-in before they observe anything.
- **`sources:` resolution** (workflow contracts): resolve each entry
  **ICM-relative first** (against the contract's own mount root), then
  workspace-relative. Both resolutions remain inside `Paths.resolve_real`
  containment. Deterministic; a shared module's workflows survive any
  mount name.
- **Reference index**: built per enabled mount. Within a mount, links are
  ICM-relative; across mounts, `mounts/<name>/…`. Disabling a mount drops
  its pages from the index; inbound cross-references to it render as "in a
  deactivated mount", not as broken links.
- **Knowledge UI**: one top-level section per enabled mount (manifest name
  + description). With exactly one enabled mount, the grouping level
  collapses — visually today's single tree. Non-markdown files are listed
  with type icons; `.md` opens the editor, other files get preview/reveal.
  Disabled mounts sit in a collapsed "Deactivated" group with re-enable
  toggles; degraded mounts show a warning chip with the manifest error.
- **Agent instructions**: session context composes by routing, not
  concatenation — root `AGENTS.md` (rules) → `MOUNTS.md` (index) → each
  mount's `AGENTS.md` (self-description) → pages, following references on
  demand exactly like today's Layer 0/1 → Layer 3 flow.

## Agent boundary

Everything lives under the workspace root, so the Phase-3 hardening
carries over **unchanged**: cwd-scoped `Read(./**)` in the managed Claude
settings, symlink-escape denial (`resolve_real`), and the deny-list
(`secrets/`, `logs/`, `.claude/`, `app.sqlite*`). No new settings surface.

- **Policy `read_roots`**: shell roots (`sources`) + `mounts/<name>` per
  *enabled* mount, computed at session start and on mount changes. A
  disabled mount's paths fall outside the read roots ⇒ ask-gate, exactly
  like any out-of-scope read today. (`prompts` leaves the default roots —
  it now lives inside mounts.)
- **Writes**: unchanged posture. Human edits full CRUD via Knowledge;
  agent Write/Edit stays ask-gated; workflow-run staging writes stay
  confined to the exact staging path; the queue trust loop is untouched.
- **`scripts/`**: no new machinery — scripts are files the agent may read
  (in read roots) and may only execute through the existing ask-gated
  Bash. The ICM's `AGENTS.md` documents its own tools. No auto-approval
  of any kind is added by this spec.
- `icm.yaml` and `MOUNTS.md` are agent-readable, Valea-managed.

## ICM-paper mapping (restated for multi-ICM)

The paper assumes a single ICM as the whole agent architecture. Valea's
adaptation for composition: the **workspace shell** carries Layer 0/1
(root rules + routing via `MOUNTS.md`) and Layer 4 (queue/sources working
artifacts); each **mounted ICM** carries its own Layer 2 (its
`Workflows/` stage contracts) and Layer 3 (reference memory), described
by its own `AGENTS.md`. `docs/VISION.md` Principle 2 is updated
accordingly.

## Migration, scaffold, onboarding

- **ICM-aware onboarding (the ICM-first journey).** Users commonly have an
  ICM before they have Valea. When the open/create dialog is pointed at a
  directory that is not a workspace, Valea checks whether it is (or
  contains) an ICM — `icm.yaml` present, or a knowledge-shaped tree — and
  never dead-ends with "not a workspace". Instead it offers **adoption**:
  "This looks like a knowledge module — create a workspace around it?"
  Adoption paths: (a) *reference it in place* (once Spec A2 ships — the
  default, least invasive), or (b) *move it into the new workspace's
  `mounts/`* (this spec: the only path; requires explicit consent to
  relocate, with the original location shown). Copying is never offered —
  a silent fork of the user's knowledge is worse than either.
- **Scaffold/onboarding**: workspace creation asks for the business name;
  the starter ICM is seeded at `mounts/<slug>/` (slugged name) with a
  fresh manifest (new uuid, the given name), its own `AGENTS.md`
  (self-description of the seeded taxonomy), today's seeded pages +
  `Workflows/` + `prompts/` inside it. Root `AGENTS.md` template becomes
  rules + shell map + `@MOUNTS.md`. `MOUNTS.md` generated at scaffold.
- **Workspace v3 → v4 migration** (extends the existing idempotent
  `Valea.Workspace.Migration`):
  1. `File.rename` `icm/` → `mounts/<slug>/` (slug from the workspace
     folder name; if the target already exists, append `-2`, `-3`, … —
     never overwrite). **Renames are byte-preserving and permitted** under
     the migration contract (never delete, never overwrite content); this
     is recorded as an explicit contract clarification in the module doc.
  2. Write `mounts/<slug>/icm.yaml` (fresh uuid, name from workspace) and
     the ICM-level `AGENTS.md` **only if absent**.
  3. Move `prompts/` into the mount (rename; skip if a target exists).
  4. Root `AGENTS.md`: pristine (v3 seed hash) → replaced with the
     rules-only version; modified → left untouched + audited
     `migration_note` and a doctor warning (same posture as the v3
     triage-page rule).
  5. Generate `MOUNTS.md`; bump `config/workspace.yaml` to `version: 4`
     (marker written last, crash-idempotent re-run as in v2/v3).
- Historical audit entries and decided queue envelopes keep their old
  `icm/…` paths as historical facts; pre-v4 *pending* items referencing
  `icm/…` inputs will fail re-validation and can be rejected (accepted:
  no production users).
- Frontend constants (Today triage card, workflow edit links) re-point to
  `mounts/<slug>/Workflows/…` via the cockpit payload (the backend tells
  the frontend the seeded workflow's path rather than hardcoding it).
- The mail doctor's `workflow_contract` check scans the workflow registry
  (all enabled mounts) instead of one hardcoded path.

## Error handling

| Failure | Behavior |
| --- | --- |
| Missing/unparseable `icm.yaml`, or missing `name` | Degraded mount: warning chip in Knowledge + doctor entry; excluded from read roots, registry, index, `MOUNTS.md` @-refs; discovery never crashes |
| `mounts:` config entry for a nonexistent directory | Inert (ignored) |
| Duplicate manifest `id` across mounts | Allowed — path is identity; `id` is provenance |
| Empty `mounts/` | Knowledge empty state: "Create your first ICM"; agent sessions still work (shell only) |
| Mount removed while pages open | Editor surfaces the standard file-gone error; discovery watcher prunes nav/index |
| Same-named workflow in two mounts | Coexist (distinct paths); provenance label disambiguates in UI |
| Disabled mount referenced cross-mount | Inbound refs render "in a deactivated mount", not broken |

## Testing

- **Migration**: v3→v4 move semantics (byte-preserving renames, manifest
  minted once, prompts moved, pristine-vs-modified root AGENTS.md, marker
  last, idempotent re-run); v1→v4 chain still green.
- **Discovery**: valid/broken/absent manifests; live add/remove via the
  `mounts/` watcher; degraded-mount surfacing.
- **Relationship state**: enable/disable round-trip; absent entries
  default enabled; inert entries for missing dirs.
- **Composition**: registry union + provenance; same-name coexistence;
  `sources:` ICM-relative-first resolution (incl. containment); reference
  index scoping per enabled mount.
- **Agent boundary**: `read_roots` reflect exactly the enabled set;
  disabled-mount reads hit the ask-gate; deny-list untouched (regression).
- **MOUNTS.md**: regeneration on discovery/toggle; degraded mounts listed
  without @-refs; atomic write.
- **Frontend**: Knowledge grouping + single-mount collapse; deactivated
  group; non-md file listing; workflow provenance labels; Today card path
  from cockpit payload.
- **Bare-agent smoke** (manual, acceptance): start a plain Claude Code
  session at a mount root; verify the ICM self-describes (AGENTS.md map,
  workflows readable, ICM-relative references resolve).

## Acceptance scenario

Create a fresh workspace ("Mara Lindt Coaching") → Knowledge shows one
tree (single-mount collapse) seeded with the taxonomy; run the seeded
triage flow end-to-end (unchanged UX). Then drop a second ICM folder into
`mounts/` (hand-made, with manifest + AGENTS.md + one workflow) → it
appears in Knowledge as its own section and its workflow appears in the
registry with provenance; run it; disable the mount → its pages leave
Knowledge, its workflow leaves the registry, the agent can no longer read
it; re-enable → everything returns. Open an old v3 workspace → migration
moves the ICM under `mounts/`, everything keeps working. Finally: open a
mount folder with bare Claude Code and confirm it is self-sufficient.
