# By-Reference ICM Mounts — Design (ICM Spec A2)

**Date:** 2026-07-12 · **Status:** implemented historical design; superseded as the target architecture by [Workspace Profiles, Mounted ICM Projects & ICM-Scoped Sessions](2026-07-13-icm-project-workspaces-design.md)
**Depends on:** 2026-07-12-icm-mounts-design.md (Spec A — the mount model this extends). Implements the `kind:`/`ref:` fields Spec A reserved.

> This document records the first by-reference extension to the embedded
> mount model. The replacement design makes all ICM mounts by-reference,
> removes embedded discovery and global `MOUNTS.md` routing, and makes the
> selected ICM the session cwd.

## Goal

Let an ICM live **outside the workspace** and be mounted by reference:
the user's pre-existing knowledge folder (`~/company-icm`, a git
checkout, a Drive-synced directory) stays exactly where it is, and one
physical ICM can serve several workspaces. This completes the ICM-first
journey: people build knowledge modules before and independently of
Valea; the app attaches to them rather than swallowing them.

## Why a separate spec

Everything in Spec A is boundary-neutral (all files under the workspace
root). This spec is precisely the boundary change: each external mount
is a **deliberate, user-declared, config-visible widening of the agent's
read surface**, and it deserves its own review gate.

## Model

### Declaration (config joins discovery)

Embedded mounts stay discovery-only (disk is truth). External mounts
must be declared — there is nothing on disk under `mounts/` to discover:

```yaml
# config/workspace.yaml
version: 4
id: <workspace-uuid>
mounts:
  company:                      # mount name (identity within this workspace)
    kind: path                  # this spec: only "path"; future: git, zip, …
    ref: ~/Business/company-icm # absolute or ~-expanded; symlink-resolved at load
    enabled: true               # same relationship semantics as Spec A
```

- The mount set = **discovered embedded mounts ∪ declared external
  mounts**. A name collision between an embedded dir and a declared
  entry is a degraded state (both shown, neither mounted) — explicit
  beats silent shadowing.
- The `ref` target must contain a parseable `icm.yaml` (same manifest,
  same degraded-mount handling as Spec A when missing/broken).
- A `ref` pointing inside the workspace root is rejected as invalid
  (that is what embedded mounts are for); a `ref` pointing at the
  filesystem root, home directory itself, or any ancestor of the
  workspace is rejected (guardrail against absurdly wide grants).

### Same-ICM, many workspaces

Two workspaces referencing one physical ICM need no coordination: files
are the single truth, each workspace runs its own watcher, and the
editor's existing base-hash guard handles concurrent edits the same way
it handles any external modification today. The manifest `id` (shared)
is provenance, not identity — each workspace's mount name is local.

## Agent boundary (the heart of this spec)

Each enabled external mount widens the read boundary by exactly one
root, in three coordinated places:

1. **Managed Claude settings** (`.claude/settings.json`): the allow list
   gains `Read(<resolved-abs-ref>/**)` per enabled external mount. The
   existing deny rules are untouched and continue to win (deny >
   allow). Settings are regenerated on every mount change, workspace
   open, and session start — as today.
2. **Permission policy**: containment generalizes from "the workspace
   root" to a **root set** — workspace root + each enabled external
   mount's resolved real path. `resolve_real` runs per root with
   identical symlink-before-`..` semantics: a path is readable iff it
   resolves inside *some* root in the set; a symlink inside an external
   mount that escapes that mount resolves against the other roots or is
   denied. Write containment is unchanged (staging paths only —
   workflow writes never target external mounts through the run grant;
   ask-gated Write/Edit remains the agent's path for ICM edits, now
   also valid inside external mounts).
3. **Watchers**: one per enabled external mount (tree/reference
   invalidation), same debounce discipline as embedded mounts.

Additional boundary rules:

- **Secrets hygiene warning**: the doctor scans each external mount for
  a `secrets/` directory or `.env`-like files at its root and warns —
  an external ICM is agent-readable in full, and Valea's workspace
  deny-list does not reach into it. (Warning only; the user owns the
  folder.)
- **Audit**: enabling/disabling/declaring an external mount is audited
  (`mount_declared`, `mount_enabled`, `mount_disabled`, with the
  resolved path) — boundary changes leave a trail.
- Disabled external mounts are removed from all three places
  (settings allow entry, policy root set, watcher) — invisible to the
  agent, exactly like disabled embedded mounts.

## Composition semantics (deltas from Spec A)

- Registry, `sources:` ICM-relative-first resolution, reference index,
  and Knowledge UI treat external mounts identically to embedded ones.
- **Paths stay physical — no virtual prefix.** Spec A's principle is
  that the path on disk is the one vocabulary; for external mounts the
  path on disk is the **resolved absolute path**, and that is what
  agents, workflow contracts, run inputs, queue envelopes, and audit
  entries use. (A virtual `mounts/<name>/…` alias would break every
  agent tool — they operate on the real filesystem — and bare sessions
  besides.) The mount *name* is a UI grouping label and the config key,
  never a path segment. Within an external ICM, content stays
  ICM-relative (portability rule unchanged); only cross-boundary
  references pay the absolute-path cost, and those are explicitly
  non-portable by Spec A's rules anyway.
- `MOUNTS.md` lists each external mount with its display name and real
  location — "Company — mounted from ~/Business/company-icm" — with an
  `@<abs-path>/AGENTS.md` reference, so both Valea-run and bare
  sessions can navigate to it directly.
- Knowledge UI grouping is identical for both mount kinds (name +
  description header); the pane shows the real location for external
  mounts.

## Onboarding & lifecycle

- **Adopt-by-reference becomes the default adoption path** (Spec A's
  onboarding amendment): pointing the open dialog at an ICM offers
  "Use it where it is" (declare `kind: path`) first, "Move it into the
  workspace" second.
- Knowledge's "Add existing" gains "Mount a folder from elsewhere…"
  (directory picker → validate manifest → declare + enable).
- **Missing `ref` at open** (unplugged drive, renamed folder): degraded
  mount — visible with a warning ("folder not found at ~/…"), excluded
  from read roots/registry/index, config entry preserved. Recovery is
  checked at workspace open, on doctor runs, and via a manual re-scan
  affordance — deliberately no continuous polling of absent paths.
- **Un-mounting** an external ICM = removing its config entry (UI
  affordance); the external folder is never touched. Valea never
  deletes, moves, or rewrites anything outside the workspace root
  except edits the user/agent explicitly make to mounted pages.

## Trust & product framing

The first-run promise evolves from "your business runs on a folder you
own" to "your business runs on folders you own": the workspace (the
operational shell — queue, sources, audit) plus your knowledge modules,
wherever you keep them. Export/backup guidance names both. The doctor
gains a "Mounts" section: per external mount — path resolves, manifest
ok, secrets-hygiene check, watcher live.

## Error handling

| Failure | Behavior |
| --- | --- |
| `ref` missing/unresolvable at open | Degraded mount (warning, path shown); config preserved; recovers on re-check |
| `ref` inside workspace / ancestor of workspace / `~` or `/` itself | Config entry invalid → degraded with explicit reason; never mounted |
| Manifest missing/broken at `ref` | Degraded (same as Spec A) |
| Name collision embedded vs declared | Both degraded with explanation; nothing mounted under that name |
| External mount deleted while enabled | Watcher/read errors surface as degraded on next scan; agent reads hit ask-gate (root pruned on detection) |
| Symlink inside external mount escaping it | Denied unless it resolves into another enabled root (identical posture to workspace containment) |
| `secrets/`-like content in external mount | Doctor warning (user-owned; no silent deny reach-in) |

## Testing

- Policy root-set: reads inside each enabled external root allowed;
  disabled/degraded roots denied; escape-symlink denial per root;
  write-grant unchanged (staging only).
- Managed settings: allow entries appear/disappear with enable state;
  deny rules unchanged; regeneration on mount changes.
- Physical-path plumbing: ICM ops, registry entries, references, and
  editor loads/saves address external mounts by resolved absolute path;
  no alias appears anywhere in agent-visible or persisted vocabulary.
- Config validation: ref guardrails (workspace-interior, ancestor, `/`,
  `~`), collision handling, missing-path degradation + recovery.
- Multi-workspace share: two tmp workspaces referencing one ICM — edits
  visible to both, base-hash conflict surfaced, no watcher cross-talk.
- Doctor: mounts section checks incl. secrets-hygiene warning.
- Audit: mount_declared/enabled/disabled entries with resolved paths.

## Acceptance scenario

Have `~/Business/company-icm` (manifest + AGENTS.md + a workflow) and a
fresh workspace. Onboarding: point the open dialog at the ICM folder →
"Use it where it is" → workspace created, mount declared + enabled →
its pages appear under their own Knowledge section, its workflow runs
(contract addressed by real path), the agent reads its pages (allowed)
but a probe outside both roots still hits the ask-gate. Unplug the folder (rename it) → degraded
mount with clear warning, agent access gone; restore → recovers.
Declare the same ICM in a second workspace → edits made in one are
visible in the other. MOUNTS.md shows the real path; the doctor's
mounts section is green.
