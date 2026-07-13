# Workspace Profiles, Mounted ICM Projects & ICM-Scoped Sessions — Design

**Date:** 2026-07-13

**Status:** approved design, implementation pending

**Supersedes as the target architecture:**
[ICM Mounts & Workspace Shell](2026-07-12-icm-mounts-design.md) and
[By-Reference ICM Mounts](2026-07-12-icm-by-reference-design.md) wherever they define embedded
`mounts/`, workspace-root agent routing, global mount composition, or
path-as-ICM-identity. Those documents remain the record of the currently
implemented design.

**Builds on:** the file-first agent, permission, workflow, queue, audit,
editor, mail, and methodology-depth machinery already implemented.

## Summary

Valea has two different concepts that the current implementation partially
conflates:

- A **workspace** is Valea's operational profile: connected email and
  calendar accounts, normalized sources, approval queue, audit log, session
  transcripts, configuration, and cache database.
- An **ICM** is a portable, user-owned context project: its identity,
  routing, workflows, reference knowledge, prompts, and optional scripts.

The current model starts every coding harness at the workspace root and uses
a generated `MOUNTS.md` to fan the agent into every enabled ICM. That makes
the agent decide which ICM matters before an ICM has had the chance to scope
the task. This is exactly the context-selection problem ICM is intended to
solve.

This design reverses that relationship:

1. Every session has one required **primary ICM**.
2. The coding harness process cwd and ACP cwd are the primary ICM's physical
   root.
3. The primary ICM's own `CLAUDE.md`, `AGENTS.md`, and `CONTEXT.md` provide
   Layers 0 and 1. A workflow inside it provides Layer 2; its pages provide
   Layer 3.
4. Other mounted ICMs are launchable projects, not a global context bundle.
   They join a session only when the primary ICM explicitly declares them as
   related context.
5. Layer 4 working artifacts remain in Valea's workspace and are given to a
   session as exact, task-specific inputs and output grants.
6. Workspaces live in Valea's private application directory. ICMs live
   wherever the user keeps them and are always mounted by reference.
7. The main sidebar shows mounted ICMs with their five most recent sessions,
   replacing the persistent knowledge file tree.

There are no production users. This is a clean structural replacement: no
legacy session compatibility, embedded-mount migration, or transitional
global routing is required.

## Goals

- Make the selected ICM, not the Valea workspace, the agent's execution and
  context root.
- Make ICM selection explicit at session creation and deterministic for
  workflow runs.
- Keep ICMs portable, independently runnable, and user-owned.
- Let one physical ICM participate in multiple Valea workspaces without
  copying it.
- Let workspaces remain useful operational boundaries for different account
  setups, ICM sets, queues, and audit histories.
- Remove the need for users to understand or choose a Valea workspace folder
  during onboarding.
- Preserve the current file-first, human-approval, symlink-hardened, audited
  security posture.
- Keep unrelated ICM instructions and workspace sources out of a session by
  default.

## Non-goals

- Concurrently active workspace runtimes. One workspace remains open at a
  time.
- Background sessions surviving a workspace switch.
- Cloud synchronization or team collaboration.
- Git operations or source-control management for ICM folders.
- A virtual filesystem that makes external ICMs appear under the workspace.
- Automatic semantic selection of related ICMs by the model.
- Backward compatibility with development workspaces or pre-redesign
  transcripts.
- A general dependency/package manager for ICMs. Related-ICM declarations are
  context routing, not versioned software dependencies.

## Terminology and invariants

| Term | Definition |
| --- | --- |
| Workspace | A Valea operational profile stored in Valea's private app directory. Owns integrations, sources, queue, audit, sessions, configuration, and SQLite cache. |
| ICM | A user-owned folder containing `icm.yaml`, context instructions, workflows, reference material, and optional tools. |
| Mount | A workspace-local relationship that references an ICM's physical folder. No files are copied or moved. |
| Mount key | A unique, stable key inside one workspace's `icms:` config mapping, used by UI and APIs. |
| ICM id | The stable UUID in `icm.yaml`. It identifies the portable ICM across workspaces. |
| Primary ICM | The one mounted ICM whose root is the cwd for a session. Required for every chat and workflow session. |
| Related ICM | Another mounted ICM explicitly declared by the primary ICM as optional context for that ICM's routing. |
| Session scope | The resolved workspace, primary ICM, related ICMs, exact inputs, write grants, managed harness settings, and generation used to launch one session. |

Binding invariants:

1. A workspace is never an agent project and carries no agent-routing
   `CLAUDE.md`, `AGENTS.md`, or `MOUNTS.md`.
2. An ICM is never implicitly part of a session merely because it is mounted.
3. Every session has exactly one primary ICM.
4. Process cwd and ACP cwd are identical and equal the primary ICM's resolved
   physical root.
5. Relative agent paths resolve against the primary ICM, never the Valea
   workspace.
6. Workspace sources are not general chat context. They enter sessions only
   through exact task inputs or an explicit, reviewed grant.
7. The same physical ICM may be mounted in several workspaces; its content is
   not copied.
8. Workspace relationship state never modifies `icm.yaml` or any other ICM
   file.
9. Valea-generated runtime/settings files never land inside a user-owned ICM.
10. Persisted app locators use stable ICM id + ICM-relative path; physical
    absolute paths are resolved at I/O boundaries and may be snapshotted for
    audit.

## System model

```text
Valea application
  Workspace: Coaching business
    email/calendar configuration
    sources, queue, audit, session transcripts
    mounted ICMs
      Coaching  -> ~/Documents/Mara Coaching
      Legal     -> ~/Knowledge/Legal

  Workspace: Consulting
    different email/calendar configuration
    independent sources, queue, audit, session transcripts
    mounted ICMs
      Consulting -> ~/Work/Consulting ICM
      Legal       -> ~/Knowledge/Legal   # same physical ICM as above
```

Only the currently open workspace has a Repo, mail engine, watcher set,
audit writer, queue recovery task, and agent-session supervisor running.

## Workspace storage

Workspaces are created below Valea's private application root. The default
conceptual location is:

```text
~/.valea/workspaces/<workspace-slug>-<short-id>/
  workspace.yaml
  config/
    mail.yaml
    calendar.yaml
  sources/
    mail/
    calendar/
    files/
  queue/
    staging/
    pending/
    processing/
    approved/
    rejected/
    applied/
  logs/
    sessions/
    audit.jsonl
  runtime/                 # ephemeral, Valea-managed, git/export optional
    sessions/<id>/
      settings.json
      context.md
  secrets/                 # file-backed secrets if ever needed; keychain preferred
  app.sqlite
```

The actual root continues to respect `VALEA_APP_DIR` for tests and packaged
platform needs. Users name a workspace but do not choose this folder. The
workspace switcher and Settings may offer "Reveal workspace data" for
advanced inspection.

`runtime/` contains session-local launch material and may be swept after a
session terminates. Canonical transcripts and audit entries stay under
`logs/`.

### Workspace config

The clean format is workspace version 5:

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

Rules:

- The mapping key is the workspace-local mount key. It must be a safe
  basename-like slug and unique in the workspace.
- `path` is stored in the user's form (`~` is preserved) and expanded,
  symlink-resolved, and boundary-validated every time it is loaded.
- `enabled` defaults to `true` when absent.
- Identity and descriptive metadata come from the referenced ICM's
  `icm.yaml`, never from workspace config.
- Unknown relationship keys are preserved for forward compatibility.
- A physical root may appear only once in a workspace.
- An ICM id may appear only once in a workspace. Two folders with the same id
  are an ambiguous clone and both cannot be mounted simultaneously.
- A path inside the private workspace, the filesystem root, the home
  directory itself, or an ancestor of the workspace is rejected.
- Missing or invalid targets remain declared but degraded so the user can
  repair the relationship without re-entering it.

The set of mounted ICMs is config truth. There is no embedded `mounts/`
discovery pass.

## ICM anatomy and identity

```text
<icm-root>/
  icm.yaml
  CLAUDE.md
  AGENTS.md
  CONTEXT.md
  Workflows/*.md
  prompts/
  scripts/
  <reference folders and files>
```

Recommended `icm.yaml`:

```yaml
format: 2
id: 6f9f0c9e-3ccd-4fa5-a219-113a70618b55
name: "Mara Lindt Coaching"
description: "Offers, clients, pricing, tone and policies for the coaching business."
```

This design changes the old manifest-id rule: `id` is now stable ICM
identity, not merely provenance. It travels with the ICM when the same ICM is
moved or mounted into another workspace. Copying an ICM as a new independent
module requires minting a new id. A duplicate id in one workspace is a doctor
error and cannot enter a session scope.

`CLAUDE.md` imports the portable, harness-neutral files:

```markdown
@AGENTS.md
@CONTEXT.md
```

- `AGENTS.md` answers "where am I?": identity, rules, folder map, and
  conventions.
- `CONTEXT.md` answers "where do I go?": task routing, workflow map, shared
  resources, and optional related ICMs.
- `Workflows/*.md` answer "what do I do?": stage inputs, process, outputs,
  and approval behavior.
- Other content is stable reference material or ICM-local working material
  as defined by the ICM itself.

An ICM remains usable by a bare coding harness with no Valea present.

## Related ICMs

An ICM may declare other ICMs its routing can consult. This declaration is
explicit and portable; the model never selects from the workspace's full
mount catalog.

Proposed `CONTEXT.md` frontmatter:

```yaml
---
format: 1
related_icms:
  - id: 31201697-cff8-4d99-9dc5-b140e4178716
    name: "Legal & Administration"
    entrypoint: CONTEXT.md
---
```

Rules:

- `id` is required and resolves against enabled, healthy ICMs mounted in the
  current workspace.
- `name` is descriptive only and makes the declaration readable in diffs.
- `entrypoint` defaults to `CONTEXT.md` and must remain inside the related
  ICM root.
- Declaring a related ICM makes its root available to the session; it does
  not automatically inline all of its files.
- The primary ICM's routing text remains responsible for explaining when the
  related ICM is relevant and which entrypoint/page to read.
- Missing, disabled, duplicate-id, cyclic, or invalid related ICMs are
  surfaced by the doctor. A chat session may start with a visible degraded-
  context warning; a workflow whose declared inputs require the missing ICM
  fails preflight before spawning a harness.
- Related-ICM traversal is bounded and cycle-safe. A session scope includes
  the primary ICM plus the direct related ICMs declared by it. Related ICMs'
  own dependencies are not recursively granted unless the primary ICM also
  declares them. This keeps the read surface locally auditable.

Valea resolves ids to physical roots at launch and writes a session-local
`runtime/sessions/<id>/context.md` containing the resolved map. The harness
adapter supplies that bootstrap as Valea-managed session context and adds the
resolved related roots as additional directories. It must not cause those
directories' `CLAUDE.md` files to load globally; their entrypoints are read
only when the primary ICM's routing calls for them.

## Why cwd isolation is sufficient

Claude Code loads project instructions from the cwd and its ancestor
directories. With the new layout, the ICM is not nested under the Valea
workspace, so the workspace cannot be discovered by walking upward:

```text
cwd:        ~/Documents/Mara Coaching
workspace:  ~/.valea/workspaces/coaching-business-a2f3
```

The paths are siblings in the user's home hierarchy, not ancestors of one
another. If the ICM has `CLAUDE.md` and its ordinary parent folders do not,
there is no additional project `CLAUDE.md` to load. A user's global harness
instructions (for example `~/.claude/CLAUDE.md`) remain their intentional
personal configuration.

Valea still supplies explicit session settings so enforcement does not rely
on context-file behavior and so external ICMs never receive generated
`.claude/` files.

## Session scope and launch

Every session is created from a resolved launch object:

```elixir
%{
  workspace: %{
    id: workspace_id,
    root: workspace_root,
    generation: generation
  },
  primary_icm: %{
    mount_key: "coaching",
    id: icm_id,
    root: resolved_icm_root,
    manifest: manifest
  },
  related_icms: [resolved_related_icm],
  cwd: resolved_icm_root,
  read_paths: exact_task_inputs,
  write_paths: exact_files,
  write_roots: exact_directories,
  managed_settings: session_settings_path,
  managed_context: session_context_path
}
```

### Chat session

Default read surface:

- Primary ICM root.
- Direct related ICM roots declared by the primary ICM.
- Session bootstrap/context file supplied by Valea.

Not included by default:

- `sources/`.
- Queue contents.
- Other mounted ICMs.
- Another workspace.

Writes and Bash remain ask-gated. A mounted ICM being readable does not make
it automatically writable.

### Workflow session

The workflow's owning ICM is always the primary ICM. No model or user choice
is needed after the workflow has been selected.

In addition to the chat surface, the workflow session receives:

- The workflow contract.
- Each validated declared input, resolved ICM-relative or supplied as an
  exact workspace source path.
- The exact staging proposal file grant.
- The exact memory-proposal staging directory grant where the contract
  permits it.

The server continues to own run id, hashes, sidecars, queue envelopes,
validation, finalization, and audit. The agent proposes only at the exact
paths it is given.

### Process and ACP cwd

Both must be the primary ICM root:

```elixir
ProcessRuntime.start(%{cd: scope.cwd, ...})
Connection.new(%{cwd: scope.cwd, ...})
```

`workspace_root` is retained separately for transcripts, queue, audit,
source materialization, generation checks, and runtime ownership.

### Managed harness settings

Valea writes session-local settings under the hidden workspace and passes
them through the harness adapter. For Claude Code the desired adapter
contract uses its session settings/additional-directory capabilities rather
than writing `<icm>/.claude/settings.json`.

The managed policy must:

- Allow reads in the primary and resolved related ICM roots.
- Allow exact task input paths.
- Ask for Edit, Write, and Bash unless an exact workflow grant applies.
- Deny the private workspace's `logs/`, `config/`, `secrets/`, runtime
  settings, `.git/`, and SQLite files.
- Avoid auto-loading instructions from related additional directories.
- Preserve user-level harness configuration except where Valea's stronger
  session enforcement overrides it.

The implementation starts with an adapter spike proving that
`claude-agent-acp` can receive this launch configuration. No runtime refactor
lands until the managed-settings path is demonstrated end to end.

## Permission and containment model

`PermissionPolicy` separates three bases:

- `workspace_root`: protected operational state and exact Layer 4 inputs.
- `cwd`: base for every relative agent path.
- `read_roots`: absolute resolved roots for the primary ICM, direct related
  ICMs, and exact task inputs.

All path decisions continue through `Paths.resolve_real` with segment-boundary
membership. Symlink escape from any ICM root is denied unless the resolved
target lands inside another explicitly granted root. A disabled, degraded,
or unmounted ICM is absent from the root set.

Workspace source access is least-privilege:

- A generic chat does not receive the mail/calendar tree.
- A workflow receives only the source files or source directories its
  validated contract/run needs.
- A future "chat about this message" action must name the target ICM and pass
  the selected message as an exact input.

## Stable locators versus physical paths

Coding harness filesystem tools operate on real physical paths. Persisted
Valea records use stable logical locators so moving an ICM does not invalidate
workflow definitions, pending memory updates, or UI links.

ICM locator:

```json
{
  "kind": "icm",
  "icm_id": "6f9f0c9e-3ccd-4fa5-a219-113a70618b55",
  "path": "Pricing/Current Pricing.md"
}
```

Workspace locator:

```json
{
  "kind": "workspace",
  "path": "sources/mail/messages/42.md"
}
```

Rules:

- ICM `path` is relative to that ICM's root and passes the owning-root
  containment gate.
- Workspace `path` is relative to the current workspace and passes the
  workspace containment gate.
- Runtime prompts may additionally name resolved absolute paths because that
  is what coding tools consume.
- Transcripts and audit entries snapshot both the stable locator and the
  resolved physical path used for forensic reconstruction.
- Queue memory-update targets use the stable ICM locator plus base hash. On
  approval, the current workspace mount table resolves the id again; missing,
  disabled, moved, or changed targets return to review instead of applying.
- Workflow registry entries are identified by `{icm_id, relative_path}`.
  Display payloads also include mount key, ICM name, and resolved path.

This logical locator is application persistence, not a virtual filesystem:
the agent never opens `icm://...`; it receives a real path.

## Session persistence

Sessions are stored in the active workspace because their inputs, approvals,
integration state, and audit history belong to that operational profile.

Fresh metadata schema:

```json
{
  "schema": "session/v1",
  "id": "...",
  "workspace_id": "74fa36f2-...",
  "workspace_name": "Coaching business",
  "icm_mount": "coaching",
  "icm_id": "6f9f0c9e-...",
  "icm_name": "Mara Lindt Coaching",
  "icm_root": "/Users/mara/Documents/Mara Coaching",
  "kind": "chat",
  "workflow": null,
  "run_id": null,
  "harness": "claude_code",
  "generation": 3,
  "started_at": "2026-07-13T12:00:00Z"
}
```

There is no reader or UI path for old workspace-scoped transcripts. Existing
development workspaces may be deleted and recreated during implementation.

Follow-up sessions inherit the original session's workspace and primary ICM.
If that ICM is no longer mounted or healthy, the transcript stays viewable
but follow-up creation is disabled with a repair action.

## Workspace lifecycle and switching

Workspaces remain useful because different profiles may have different:

- Email and calendar accounts.
- Mounted ICM sets.
- Sources and queues.
- Approval and audit histories.
- Integration configuration and keychain credentials.

The switcher remains in the sidebar footer. It lists recent workspaces, marks
the current one, and offers:

- New workspace…
- Workspace settings.
- Reveal workspace data (advanced).

Only one workspace runtime is active. Switching performs:

1. Flush or block on an unsaved Knowledge edit.
2. If any session process is live, show a confirmation that switching stops
   the active sessions. Busy sessions are never silently killed by a casual
   click.
3. Stop the old workspace runtime: agent sessions, ICM watchers, mail engine,
   audit writer, queue recovery, and Repo.
4. Open the selected workspace and start its runtime.
5. Advance the workspace generation so stale mutations fail with
   `workspace_changed`.
6. Replace the mounted-ICM/session sidebar groups and workspace-wide views.

Ended transcripts remain in the old workspace and reappear when it is opened
again. Keeping sessions alive across workspace switches is deferred.

## Main navigation and session UX

The main sidebar no longer renders the ICM file tree. It shows mounted ICMs
as project groups with recent sessions:

```text
Today
Mail
Calendar
Workflows

ICMs

Mara Lindt Coaching                         +
  Prepare follow-up email
  Review pricing update
  Distill recent decisions
  Session preparation
  Review inquiry workflow
  Show all…

Legal & Administration                      +
  Review contract language
  Compare cancellation policies

+ Mount an ICM
```

### ICM group behavior

- One row per enabled or degraded mount, ordered by workspace config order
  initially; explicit pin/reorder is deferred.
- Row label uses manifest name; secondary affordances can reveal the physical
  location.
- Clicking the ICM row opens its Knowledge view.
- The `+` button starts a chat session with that ICM as primary and navigates
  to it.
- A kebab menu offers New session, Open knowledge, Show workflows, Disable,
  Reveal folder, and Diagnose.
- Up to five sessions render beneath the group, newest first. Live sessions
  sort before ended sessions and show a status dot.
- "Show all…" appears only when more than five sessions exist and opens the
  session list filtered to that ICM.
- The active ICM group is expanded. Other groups remember their local
  collapsed/expanded state; a live session forces its group open.
- A healthy ICM with no sessions shows a quiet "Start a session" row.
- A degraded/missing ICM shows its warning and repair action, remains
  navigable to diagnostics, and has no new-session action.
- A disabled ICM is omitted from the main list and appears in Workspace
  settings, where it can be re-enabled.

### Mount/create actions

The bottom action opens a small choice:

- Mount an existing ICM…
- Create a new ICM…

Mount uses a directory picker and validation preview before writing config.
Create asks for an ICM name, offers a sensible visible default folder, creates
the portable ICM there, then mounts it by reference. Valea never creates ICM
content under the hidden workspace.

### Routes

Suggested route state:

```text
/knowledge?icm=<mount-key>
/chat?icm=<mount-key>
/chat?session=<session-id>
/workflows?icm=<mount-key>      # optional filter
```

The session id is authoritative when present; its metadata determines the
ICM. The `icm` query is the new-session/empty-state selection, not a way to
reassign an existing transcript.

### File tree relocation

Knowledge owns file navigation:

- The main sidebar contains no folders or pages.
- The Knowledge route's list pane shows the selected ICM's tree.
- Switching the selected ICM replaces the tree.
- Page CRUD operates on stable `{icm_id, relative_path}` locators and resolves
  the current physical root server-side.
- Mounted ICM management lives in Workspace settings and the sidebar actions,
  not inside the file tree.

## Workspace-wide views

Today, Mail, Calendar, Queue, Audit, and the workflow catalog remain
workspace-wide because they represent the current operational profile.

- The workflow catalog is the union of workflows from enabled, healthy
  mounted ICMs, but each card carries ICM provenance and launching it is
  deterministically ICM-scoped.
- Today may aggregate prepared work across ICMs; every item shows its owning
  ICM.
- Queue and audit entries carry workspace id plus ICM id/mount provenance
  where applicable.
- Mail and calendar do not choose an ICM themselves. An action launched from
  them must select an ICM or a workflow that already identifies one.

## Onboarding

Users should not be asked to create, locate, or open a workspace folder.
Onboarding presents two primary paths.

### Start fresh

1. Ask what the ICM/business/project is called.
2. Use that name for the first ICM and default workspace name; allow the
   workspace name to be adjusted in a secondary field.
3. Offer a visible default ICM folder such as
   `~/Documents/Valea/<ICM name>/`, with "Choose another location" as an
   optional control.
4. Create the portable ICM at that location.
5. Create the hidden workspace automatically below `~/.valea/workspaces/`.
6. Mount the new ICM by reference.
7. Open the ICM's guided setup/first session.

### Use an existing ICM

1. Pick a folder.
2. Validate `icm.yaml`, instruction entrypoints, duplicate identity, and
   basic health.
3. Preview the ICM name, description, and location.
4. Default the new workspace name from the ICM name, editable without
   exposing the workspace path.
5. Create the hidden workspace automatically.
6. Mount the selected ICM by reference without copying or moving it.
7. Open its Knowledge view with a prominent New session action.

### Additional workspaces

The footer switcher offers New workspace… for a different account set or
operational boundary. The same onboarding choices apply. A workspace may
start with one ICM but can mount more later.

Trust copy evolves to:

> Your knowledge stays in folders you own. Valea keeps connected accounts,
> prepared work, approvals, and history in a private local workspace.

## API direction

The exact Ash action names may be refined in the implementation plan, but the
domain boundary is fixed.

### Workspace

- `current_workspace`
- `list_workspaces`
- `create_workspace(name)` — path is app-owned, not an argument.
- `open_workspace(id)` — id/key, not a user-entered filesystem path.
- `workspace_switch_preflight(id)` — reports live sessions/dirty blockers.

### ICM mounts

- `list_icms(generation)`
- `mount_icm(path, generation)`
- `create_icm(name, path, generation)`
- `set_icm_enabled(mount_key, enabled, generation)`
- `unmount_icm(mount_key, generation)` — config-only; folder untouched.
- `icm_doctor(mount_key, generation)`
- `icm_tree(mount_key, generation)`

### Sessions

- `create_session(kind, mount_key, generation)`
- `list_recent_sessions_by_icm(limit: 5)` — grouped payload for the main
  sidebar.
- `list_sessions(mount_key, cursor)` — complete filtered history.
- `create_follow_up(session_id, generation)` — inherits ICM.

### Workflows

- Registry items return `{icm_id, mount_key, relative_path, resolved_path,
  name, ...}`.
- `run_workflow(mount_key, relative_path, input_locator, generation)` validates
  ownership and derives the session scope; the client does not send an
  arbitrary cwd.

## Backend restructuring map

### Replace embedded mount composition

- `Valea.Mounts` becomes a config-backed ICM registry of path references.
- Remove `Valea.Mounts.MountsMd` and generated `MOUNTS.md`.
- Remove embedded `mounts/*` discovery and adopt-by-move.
- `Valea.Mounts.Manifest` upgrades to stable identity semantics.
- Watchers run once per enabled ICM root plus the workspace queue/source
  roots.

### Introduce session-scope resolution

A new module such as `Valea.Agents.SessionScope` owns:

- Mount-key lookup and health validation.
- Stable-id uniqueness checks.
- Direct related-ICM resolution.
- Absolute read/write root computation.
- Session-local settings/context materialization.
- The launch object consumed by every harness.

Neither `Valea.Api.Agents` nor `Valea.Workflows.Runner` re-derives these
rules.

### Split runtime roots

- `SessionServer` stores both `workspace` and `cwd`.
- `ProcessRuntime` and `Acp.Connection` use `cwd`.
- Transcript/audit/queue operations use `workspace`.
- `PermissionPolicy` resolves relative candidates against `cwd` and protects
  workspace state by absolute root.
- `ClaudeSettings` becomes a session settings renderer/materializer rather
  than a writer to `<workspace>/.claude/settings.json`.

### Re-key file operations

- ICM editor, references, workflows, risk classification, and memory proposal
  execution take stable ICM locators.
- The registry resolves locators to current physical paths at the I/O
  boundary.
- Workspace files retain workspace-relative locators.

### Frontend

- Replace `IcmTree` in the main `Sidebar` with an `IcmProjects`/session-group
  component.
- Move the tree entirely into Knowledge's list pane.
- Add grouped recent-session state keyed by mount key.
- Retain `WorkspaceSwitcher`, but switch by internal workspace id and remove
  manual workspace path entry from the normal flow.
- Replace create/open/adopt onboarding with Start fresh / Use existing ICM.

## Error handling

| Failure | Behavior |
| --- | --- |
| ICM folder missing | Degraded mount remains in config/sidebar diagnostics; no session/workflow launch. |
| Missing or invalid `icm.yaml` | Mount rejected during onboarding or degraded after an external change. |
| Duplicate ICM id in one workspace | Both relationships flagged ambiguous; second mount cannot be enabled until one id changes. |
| Same physical root declared twice | Reject second declaration without changing config. |
| Related ICM not mounted/disabled/degraded | Doctor warning; chat starts with degraded-context warning, required workflow fails preflight. |
| Related entrypoint escapes root | Hard invalid; never granted. |
| ICM moved | User repairs mount path; stable locators resume resolving. Pending writes revalidate before apply. |
| ICM disappears mid-session | Reads fail/ask; watcher marks degraded; transcript remains; no new turn after a fatal scope loss. |
| Workspace switch with live sessions | Explicit confirmation; accepted switch stops them before opening the next workspace. |
| Workspace switch with dirty editor | Flush first; block switch if flush fails. |
| Session request without mount key | Validation error; no global fallback when multiple or single ICMs exist. |
| Workflow path does not belong to requested mount | Reject before session creation. |
| Managed harness settings cannot be applied | Harness preflight fails; never start with a silently widened permission model. |

## Security and trust consequences

- Mounting an ICM is a workspace-local filesystem trust grant and is audited.
- Related ICMs do not widen every session globally; they widen only sessions
  whose primary ICM declares them.
- A workspace's email/calendar sources are never implied by choosing an ICM.
- The hidden workspace prevents operational implementation files from being
  mistaken for project context.
- User-owned ICMs receive no Valea-generated settings, logs, database files,
  or queue artifacts.
- Same-ICM/many-workspaces sharing means edits are immediately visible in
  every workspace that mounts it; the existing content-hash conflict guard
  remains required.
- Credentials stay keyed by workspace id in the system keychain, so mounting
  the same ICM into another workspace does not share accounts or secrets.

## Clean-cut implementation policy

Because the application is not in production:

- Replace the workspace template instead of migrating it.
- Remove old workspace-path onboarding and embedded mounts outright.
- Do not read legacy session transcripts.
- Update or replace fixtures and tests rather than adding compatibility
  branches.
- Development workspaces are recreated from the new onboarding flow.
- Historical design docs remain for rationale but are marked superseded.
- `docs/ARCHITECTURE.md` remains an as-built document until this spec is
  implemented; implementation must update it task-by-task or in the final
  documentation task.

## Testing strategy

### Registry and workspace

- Hidden workspace creation without a caller-supplied path.
- Workspace list/switch by id and independent mail/ICM configs.
- Config-only ICM mount/unmount; no ICM file mutation.
- `~` preservation, realpath resolution, missing targets, boundary
  guardrails, duplicate roots, duplicate ids.
- Same physical ICM mounted into two workspaces.

### Context and launch

- Chat session process cwd and ACP cwd both equal primary ICM root.
- Workspace root is not an ancestor and no workspace instruction file loads.
- Primary instructions load; unrelated ICM instructions do not.
- Direct related ICM is available without globally loading its instructions.
- Transitive undeclared relation is unavailable.
- Missing related ICM warning versus required-workflow preflight failure.
- Session-local managed settings/context are created under the hidden
  workspace and never in the ICM.

### Permissions

- Relative reads resolve against primary ICM.
- Primary and direct related roots allowed; unrelated mounted ICM denied or
  ask-gated per tool semantics.
- Generic chat cannot read workspace mail/calendar sources automatically.
- Workflow exact source and staging grants succeed.
- Symlink escapes from every root fail closed.
- Workspace logs/config/secrets/database stay denied.

### Sessions and workflows

- Session metadata carries workspace + mount + ICM identity snapshots.
- Grouped recent-session result returns at most five per ICM, live first,
  then newest ended.
- Follow-up inherits ICM and refuses when the mount is unavailable.
- Workflow ownership deterministically selects cwd.
- Stable locators survive an ICM path repair/move.
- Pending memory update re-resolves id/path and hash at approval.

### Frontend

- Sidebar ICM groups, expansion behavior, max-five sessions, Show all, live
  dot, empty and degraded states.
- `+` creates a session for the correct mount key.
- Mount/create actions and validation preview.
- Knowledge tree appears only in the Knowledge list pane and switches by ICM.
- Workspace switch confirmation for live sessions and block on failed edit
  flush.
- Start fresh / Use existing ICM onboarding creates the hidden workspace and
  correct mount relationship.

### Acceptance scenarios

1. **Fresh start:** choose Start fresh, name "Mara Lindt Coaching", accept
   the visible ICM location, and finish onboarding. Valea creates a hidden
   workspace, creates and mounts the ICM, shows it in the sidebar, and starts
   a session whose cwd is that ICM.
2. **Existing ICM:** select an existing folder. Valea creates a hidden
   workspace without asking for a workspace folder, mounts the ICM in place,
   and shows its Knowledge tree and New session action.
3. **Two ICMs:** mount Legal alongside Coaching. Both appear as projects.
   Starting under Coaching does not load Legal unless Coaching declares it;
   starting under Legal uses Legal as cwd.
4. **Related ICM:** Coaching declares Legal by ICM id. A Coaching session gets
   the resolved Legal root and follows Coaching's routing to the Legal
   entrypoint; no other mounted ICM joins.
5. **Workspace separation:** create Consulting with a different email setup
   and mount the same Legal ICM. Switching workspaces stops the old runtime,
   swaps the sidebar/account data, and Legal remains the same physical folder
   while session/audit history stays separate.
6. **Workflow:** run a Coaching workflow against one mail source. The session
   cwd is Coaching; only the exact mail input and staging outputs are granted;
   approval and audit stay in the Coaching workspace.

## Implementation sequence

The later implementation plan should split this design into independently
testable tasks in this order:

1. Harness launch spike: session-local settings/context, cwd, and additional
   roots through `claude-agent-acp`.
2. Hidden workspace storage and id-based workspace lifecycle.
3. Config-backed external-only ICM registry and stable manifest identity.
4. Stable ICM/workspace locator types and containment resolution.
5. Session-scope resolver and permission-policy root split.
6. ICM-scoped chat session creation, metadata, replay, and grouped recent
   listing.
7. Workflow ownership, exact Layer 4 grants, queue/audit locator changes.
8. Multi-root watchers and doctor/degraded recovery.
9. Main sidebar ICM/session groups and Knowledge tree relocation.
10. Start fresh / Use existing ICM onboarding and workspace switcher changes.
11. Delete old embedded-mount, MOUNTS routing, adoption, migration, and legacy
    transcript paths.
12. Update `ARCHITECTURE.md`, templates, acceptance documentation, and run the
    real packaged-app scenarios.

## Final product contract

> A Valea workspace is a private local operational profile. An ICM is a
> portable user-owned context project. A mounted ICM is available to launch;
> it is not automatically part of another ICM's context. Every agent session
> runs inside exactly one primary ICM, and Valea supplies only the related
> context and working artifacts that the ICM or task explicitly names.
