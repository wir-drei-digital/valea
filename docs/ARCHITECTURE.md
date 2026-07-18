# Valea — Architecture

Condensed map of the standing decisions. Full reasoning per feature lives in
[docs/superpowers/specs/](superpowers/specs/); this file states outcomes, not
rationale, and grows with each feature/spec.

> **Status note:** This document records Valea's currently implemented
> architecture, including the ICM project-workspaces redesign specified in
> [Workspace Profiles, Mounted ICM Projects & ICM-Scoped
> Sessions](superpowers/specs/2026-07-13-icm-project-workspaces-design.md):
> hidden, id-based Valea workspace profiles; every ICM mounted by reference
> (there is no embedded-mount form); one primary ICM — and cwd — per agent
> session; project-oriented sidebar navigation. The two prior mount designs —
> [ICM Mounts (Plan
> A)](superpowers/specs/2026-07-12-icm-mounts-design.md) and [By-Reference
> ICM Mounts (Plan
> A2)](superpowers/specs/2026-07-12-icm-by-reference-design.md) — described
> an embedded/global-composition model (a workspace-relative `mounts/<name>/`
> tree, generated `MOUNTS.md` routing, `.claude/settings.json` written into
> the workspace) that has been fully replaced; both are banner-marked
> superseded and remain only as historical record.
>
> A Valea workspace is a private local operational profile. An ICM is a
> portable, user-owned context project. A mounted ICM is available to launch;
> it is not automatically part of another ICM's context. Every agent session
> runs inside exactly one primary ICM, and Valea supplies only the related
> context and working artifacts that the ICM or task explicitly names.
>
> **Spec D (agent-native ICMs)** — [Agent-native ICMs
> design](superpowers/specs/2026-07-16-agent-native-icms-design.md) — deleted
> the entire Phase-3/Spec-B workflow pipeline outright (`Valea.Workflows`,
> `Valea.Workflows.Runner`, `Valea.Workflows.MemoryProposal`/`Distill`,
> `Valea.Queue`'s proposal kinds and executors, `Valea.Mail.MailboxOps`/
> `DraftMime` (the latter resurrected by Spec E as the push composer), and every RPC/UI surface built on them — `/workflows`,
> `/queue/[run_id]`, the Distill/triage actions) and replaced it with one
> kind-agnostic **session-with-context primitive**, a **today.json** cockpit
> the agent maintains directly, **adopt-a-folder** mounting, a **depth-aware**
> `RiskTier`, ICM-internal **secrets deny-by-default**, and a **3-layer prose**
> starter seed (see "Agent slice" and "Dynamic-tree riders" below). Valea no
> longer interprets ICM structure at all — the agent interprets an ICM's
> prose; Valea supplies containment, identity, ask-gated approval, sync, and
> UI. The 2026-07-12 Methodology Depth design (Spec B) and the 2026-07-10
> Agent Slice design's queue/workflow sections are superseded by this; both
> remain only as historical record (see the Spec index at the bottom of this
> file).

## System shape

Three serving modes, one Phoenix app:

```
dev            backend :4200 (mix phx.server)  +  frontend :4273 (vite dev)
dev-desktop    backend :4200                    +  Tauri window (spawns vite dev itself)
production     desktop sidecar :4817 — Phoenix serves the built SPA; window loads it from http://localhost:4817
```

- **Backend:** Elixir / Phoenix / Ash, SQLite (AshSqlite). Binds loopback only.
- **Frontend:** SvelteKit static SPA (Svelte 5 runes, no SSR — ever), Bun, Tailwind v4 + shadcn-svelte.
- **Desktop:** Tauri v2. `main.rs` spawns the backend as a Burrito-packaged sidecar binary on the fixed port 4817, polls until reachable, then shows the window; kills the sidecar on exit. Dev builds skip the sidecar entirely. In production the window loads the SPA **from the sidecar origin** — `tauri.conf.json` sets `build.frontendDist` to the URL `http://localhost:4817` (not a bundled asset dir), where `just package-backend` has baked the SPA into the backend's `priv/static`. Because the window renders same-origin with the backend, the frontend's relative `/rpc/run` and `/socket` URLs reach the sidecar unchanged (no `PUBLIC_API_URL`/`PUBLIC_WS_URL` injection needed). The window is only shown after the port polls ready, so loading from the sidecar origin never races the boot.
- Web (non-desktop) release: `just build` bakes the SPA into `backend/priv/static` and produces a standalone Phoenix release.

## Workspace model

A Valea **workspace** is a hidden, app-owned operational profile — never a
user-chosen folder and never an agent project. It owns connected-account
configuration, normalized sources, the approval queue, the audit log, session
transcripts, and its own SQLite cache; it carries no agent-routing
`CLAUDE.md`/`AGENTS.md`. Everything a user actually authors — business
memory, workflows, routing — lives in one or more **ICMs** the workspace
mounts by reference (see [ICM project workspaces](#icm-project-workspaces)
below); nothing canonical lives in the workspace folder itself.

- **Storage.** Workspaces live under `Valea.App.Config.workspaces_dir/0` —
  `<app-data-dir>/workspaces/` (e.g. `~/Library/Application Support/valea/workspaces/`
  on macOS; overridable via `VALEA_APP_DIR` for tests/packaging). Each
  workspace is a directory named `<slug>-<id-prefix8>` (`Valea.Workspace.Manager.create/1`:
  `Scaffold.slugify(name)` + the first 8 hex chars of a freshly minted UUID).
  Inside: `config/workspace.yaml` (`version: 5`, the persistent `id`/`name`,
  and the `icms:` mount map — see below), `sources/`, `queue/{staging,pending,processing,approved,rejected,applied}/`,
  `logs/{sessions/,audit.jsonl}`, `runtime/sessions/<id>/` (ephemeral
  per-session materialized settings/context, sweepable), `secrets/`, and
  `app.sqlite`. The UI never sees or asks for this path — workspaces are
  addressed everywhere by `id`, never by filesystem location (see "Id-based
  identity" below).
- **Backend boots workspace-less.** Boot order: Telemetry → PubSub →
  `Workspace.Supervisor` → Endpoint. `Workspace.Supervisor` (`Supervisor`,
  `rest_for_one`) holds a `DynamicSupervisor` plus the `Workspace.Manager`
  GenServer. The Ecto Repo is *not* a static supervision child — it starts
  under the `DynamicSupervisor` only while a workspace is open, so there is
  no database until then.
- **App-level config** (`Valea.App.Config`) is a small JSON file in the OS
  app-data dir: `known_workspaces` (each entry `id`/`name`/`slug`/`path`/
  `last_opened_at`) + `last_opened` (an id) + the trusted `harness_command`.
  A plain module (not a process) — solves bootstrapping before any workspace
  exists, without a database. `path` is the internal on-disk locator the
  Manager needs to boot the workspace; it is stored in the registry but never
  sent to or accepted from the UI, which addresses workspaces by `id` only
  (`workspace_by_id/1`, `last_opened_id/0`).
- **Id-based identity.** `Valea.Workspace.Manager.create/1` mints a UUID,
  scaffolds the hidden folder (`Valea.Workspace.Scaffold.create/3` — a bare
  marker tree from `backend/priv/workspace_template/` plus a freshly written
  `config/workspace.yaml`, `icms: {}`; no starter ICM, no root
  `AGENTS.md`/`CLAUDE.md`, no `.claude/`), opens it, and records it in app
  config keyed by that id. `open/1` takes an id (never a path), looks it up
  in `App.Config`, validates the workspace's marker structure
  (`Scaffold.valid?/1`), starts `Valea.Repo` under the `DynamicSupervisor`
  pointed at `{path}/app.sqlite`, runs Ecto migrations, starts
  `Valea.Workspace.Runtime` (the ICM watcher, audit writer, queue-recovery
  task, and agent session supervisor — see below), re-reads the persistent
  `id`/`name` back off `config/workspace.yaml`, records the open in app
  config, and broadcasts `{:workspace_opened, %{path:, name:, id:}, generation}`
  on the `"workspace"` PubSub topic. `close/0` (broadcasts
  `{:workspace_closed}`) and `current/0` (`{:ok, %{path:, name:, id:}} |
  {:error, :no_workspace}`) round it out. At boot,
  `handle_continue(:auto_open, _)` reopens `App.Config.last_opened_id()`
  automatically if it still names a known, valid workspace (falls back to
  workspace-less otherwise, clearing the stale `last_opened` pointer).
  `switch_preflight/1` is a read-only check the frontend calls before
  switching: it validates the target id is known and reports the
  *currently* open workspace's live agent sessions, so the UI can confirm a
  switch that would stop them — it performs no teardown itself.
- **Rollback is two-tier, and only one tier is implemented today.**
  Process-level: `open_workspace/2,3` in `Manager` starts the Repo, runs
  migrations, then starts `Runtime` one step at a time, accumulating started
  pids; if any step fails, every pid started so far is torn down via
  `DynamicSupervisor.terminate_child/2` before the error returns — a
  half-opened workspace never keeps a Repo or Runtime running under a name a
  later open/create could mistake for success, and the Manager's own
  `generation` counter never advances for an open that didn't finish.
  Filesystem-level: `Valea.Workspace.Scaffold.create/3` (`File.mkdir_p` +
  `File.cp_r` from the template) has **no rollback** — if `File.cp_r` fails
  partway through copying `backend/priv/workspace_template/`, the
  partially-written target directory is left on disk as-is; nothing deletes
  it. In practice this window is small (a local recursive copy of a few
  dozen small template files) and no acceptance test has hit it, but it's a
  known gap, not a designed guarantee.
- Migrations run **at workspace open**, in every environment — not at
  release boot, since the database doesn't exist until a workspace is open.
  Every workspace this Manager can open is born at its final v5 on-disk
  shape (`Scaffold.create/3`); there is no versioned on-disk upgrade step —
  the workspace-version migration chain that once carried v1→v4 workspaces
  forward has been deleted along with the model it served (Phase 11
  clean-cut; development workspaces from that era are recreated via the
  current onboarding flow, not migrated).
- Open/create failures are loud and specific; a workspace is never presented
  as healthy when half-seeded (process-level, per above).

## API layer

- **`ash_typescript`**: Ash actions on the `Valea.Api` domain (`backend/lib/valea/api.ex`, extension `AshTypescript.Rpc`) exposed as typed RPC, with a generated TypeScript client (`frontend/src/lib/api/ash_rpc.ts`, committed) giving end-to-end type safety. No AshJsonApi, no hand-maintained client types. All seven resources (`Workspace`, `ICM`, `Cockpit`, `Agents`, `Audit`, `Mail`, `Icms`) are data-layer-less Ash resources — thin adapters over plain Elixir modules (`Valea.Workspace.Manager`, `Valea.ICM`, `Valea.Cockpit`, `Valea.Agents`, `Valea.Audit`, `Valea.Mail.*`, `Valea.Mounts`), not Ecto-backed.
- **RPC action list** (`rpc_action(:name, :action)` in `Valea.Api`, generated TS function name in parens):
  - `Valea.Api.Workspace`: `get_workspace` → `:current` (`getWorkspace`) — reports `{open, path, name, id}`, `open: false` when no workspace; `create_workspace` → `:create_workspace` (`createWorkspace`, arg `name` — the path is app-owned, never a caller argument); `open_workspace` → `:open_workspace` (`openWorkspace`, arg `id`); `close_workspace` → `:close_workspace` (`closeWorkspace`); `recent_workspaces` → `:recent` (`recentWorkspaces`); `workspace_switch_preflight` → `:workspace_switch_preflight` (`workspaceSwitchPreflight`, arg `id` — reports the CURRENTLY open workspace's live sessions a switch to `id` would stop); `runtime_check` → `:runtime_check` (`runtimeCheck`).
  - `Valea.Api.ICM`: `icm_tree` → `:tree` (`icmTree`, arg `mount_key`) — ONE mounted ICM's tree, `{mount_key:, title:, tree:}`, every node `path` relative to that ICM's own root (task 4.2's re-key; a caller that needs every enabled ICM's tree calls this once per mount key); `icm_page` → `:page` (`icmPage`, args `mount_key, path`).
  - `Valea.Api.Icms`: `list_icms` → `:list_icms` (`listIcms`) — every `icms:`-config entry (enabled/disabled/degraded), typed `mountKey`/`id`/`name`/`description`/`root`/`enabled`/`degraded` (`id` the manifest's stable UUID, `null` for a degraded mount with no loadable manifest; `root` always the resolved absolute path — every mount is by-reference, there is no embedded form); `mount_icm` → `:mount_icm` (`mountIcm`, args `path, generation`) — mounts an existing, already-healthy external ICM folder; `adopt_icm` → `:adopt_icm` (`adoptIcm`, args `path, name, generation`) — mints a minimal `{format: 2, id, name}` identity file into a manifest-less folder (the ONLY write) and mounts it (see "Dynamic-tree riders" → adopt-a-folder below); `create_icm` → `:create_icm` (`createIcm`, args `name, path, generation`) — mints a brand-new ICM at `path` (seeding `backend/priv/icm_template/`) and mounts it, the only other mutation that writes into an ICM's own folder; `set_icm_enabled` → `:set_icm_enabled` (`setIcmEnabled`, args `mount_key, enabled, generation`); `unmount_icm` → `:unmount_icm` (`unmountIcm`, args `mount_key, generation`) — config-only, never touches the folder; `icm_doctor` → `:icm_doctor` (`icmDoctor`, args `mount_key, generation`) — per-mount health checks; `inspect_icm` → `:inspect_icm` (`inspectIcm`, arg `path`) — the "what's in this folder" mount/onboarding preview, now also reporting `adoptable`. See [ICM project workspaces](#icm-project-workspaces) below.
  - `Valea.Api.Cockpit`: `cockpit_today` → `:today` (`cockpitToday`) — the `today.json` cockpit aggregation (see "Today = a file the agent maintains" below).
  - `Valea.Api.Agents`: `create_agent_session` → `:create_session` (`createAgentSession`, args `mount_key, generation`, optional `context_doc, input`) — the session-with-context primitive (see "Session creation, permission asks, and audit" below); `list_agent_sessions` → `:list_sessions` (`listAgentSessions`); `list_recent_sessions_by_icm` → same name (`listRecentSessionsByIcm`, arg `limit`); `list_sessions` → `:list_sessions_for` (`listSessions`, args `mount_key`, optional `cursor`); `create_follow_up` → same name (`createFollowUp`, args `session_id, generation`); `harness_doctor` → same name (`harnessDoctor`).
  - `Valea.Api.Audit`: `list_audit_entries` → same name (`listAuditEntries`, arg `limit`) — relocated from the deleted `Valea.Api.Queue` (Spec D §A); `Valea.Audit` itself is queue-independent.
  - `Valea.Api.Mail`: see "RPC + channel events" under Mail below.
- **Transport: Phoenix channels first, HTTP fallback.** One socket (`ValeaWeb.UserSocket`, path `/socket`) carries two independent channel topics: `ash_typescript_rpc:client` (ash_typescript's channel-RPC transport — every `icmTree()`-style call goes here when the channel is joined) and the single consolidated **`workspace:events`** channel, joined once from `frontend/src/routes/+layout.svelte` via `wireIcmEvents()` (`frontend/src/lib/stores/icm.svelte.ts`) and pushing two event names: `workspace` (`{open, name?, path?}`, on open/close) and `icm_changed` (`{}`, on any change under `{workspace}/icm`, debounced 200ms by `Valea.ICM.Watcher`). There is no per-feature channel sprawl — `workspace:events` is the one realtime channel, and non-realtime RPC prefers `ash_typescript_rpc:client` but transparently falls back to plain `POST /rpc/run` (`ValeaWeb.RpcController.run/2`) when the socket/channel isn't joined (see `frontend/src/lib/api/client.ts`).
- Plain controllers only where RPC doesn't fit — e.g. `GET /api/health` (`ValeaWeb.HealthController`, returns `{"status":"ok"}`) for sidecar port polling from Tauri.
- Codegen is part of the build: `just codegen` runs `mix ash_typescript.codegen`; `just test` fails if the checked-in client is stale.
- Errors follow ash_typescript's structured error shape; the frontend maps a workspace-not-open error to the onboarding screen.
- **Unconstrained `:map` RPC actions stay snake_case on the wire.** `Workspace`, `ICM`, and `Mail` actions are all typed `:map` or `{:array, :map}` (no Ash embedded/typed schema) because they wrap plain Elixir data, not Ecto structs. ash_typescript's camelCase output formatter only reformats keys it can see in a typed schema (`constraints fields: [...]`) — a field left as a bare, unconstrained `:map`/`{:array, :map}` (no nested `fields:` of its own) is opaque to it even when the surrounding action is otherwise fully typed, so its generated TS type is loose (`Record<string, any>` or similar) and its actual keys arrive exactly as the backend wrote them: snake_case. Concrete example: `Valea.Api.Mail`'s `mail_status` action (`backend/lib/valea/api/mail.ex`) declares `constraints fields: [accounts: [type: {:array, :map}, allow_nil?: false]]` — the action itself is typed, but the per-account entries have no nested `fields:`, so `Valea.Mail.Engine.status/1`'s keys ride through un-camelized; the wire payload genuinely contains `last_sync_at`, `last_error`, `workspace_id` — not their camelCase equivalents. The same applies to `icm_tree`'s `tree` field (`Valea.Api.ICM`'s `:tree` action, deliberately unconstrained per its own inline comment), whose nested node keys include `page_count`. Frontend code that consumes these fields normalizes explicitly rather than trusting the generated type: see `normalizeMailAccountStatus` in `frontend/src/lib/stores/mail.svelte.ts` (checks `raw.last_sync_at`/`raw.last_error`/`raw.workspace_id` and maps to the typed camelCase `MailAccountStatus` shape) and `normalizeIcmNode` in `frontend/src/lib/stores/icm.svelte.ts` (same pattern for `page_count`/`pageCount`). Any new `:map`-typed field left without its own `fields:` constraint needs the same explicit normalization at the call site — do not trust a generated `Record<string, any>` type to already be camelCase.

## ICM editor (Phase 2)

- **Markdown ↔ ProseMirror converter** (`backend/lib/valea/markdown/prose_mirror.ex`, `.../profile.ex`): vendored from `magus/lib/magus/markdown/prose_mirror.ex` (header comment records the origin + Valea's divergences — positional `profile` arg, `to_markdown/2` returns `{:ok, md}`, blockquote serializer drops the trailing space on blank quote lines). MDEx-based, pure/IO-free. `Valea.Markdown.Profile` is the Valea profile: every callback (`post_process/1`, `node_to_markdown/1`, `inline_node_to_markdown/1`) is the identity/default — no custom node lifting, standard CommonMark + GFM only (the paper's "plain text as interface" principle; no callouts/wikilinks/tags/`magus://` links/image blocks). **Determinism contract** (`backend/test/valea/markdown/determinism_test.exs`): every seed ICM page under this suite's own fixture copy of the starter-mount content, `backend/test/fixtures/starter_icm/**/*.md` (a v5 hidden workspace's `priv/workspace_template` ships no starter ICM at all, so nothing under `priv/` carries this content anymore — the fixture was copied once, Task 11.3, to stay stable independent of what any workspace scaffold ships), excluding the ICM's own `AGENTS.md`/`CLAUDE.md` and `prompts/*.md`, round-trips `markdown → PM JSON → markdown` byte-identically, and a second pass is a fixed point — enforced by test, not just convention; the editor never sees markdown, only tiptap's ProseMirror JSON, converted at the backend boundary.
- **`Valea.ICM` write operations** (`backend/lib/valea/icm.ex`): `save_page(rel_path, pm_map, base_hash)` — SHA-256-hex hash guard (`sha256_hex/1` of the current file bytes must equal `base_hash` or the call returns `{:error, :page_changed}`, magus-style optimistic concurrency adapted to files, no lock files, no mtime), then `ProseMirror.to_markdown/1` and an atomic write; `create_page/2` / `create_folder/2` (shared `normalize_name/1` — NFC-normalize, trim, reject empty/`/`/`\`/leading `.`, `.md` auto-appended for pages; parent-must-be-a-directory guard); `rename/2` and `delete/1` work for both pages and folders (folder rename collects every nested `.md` first, then rewrites references for each). All writes share one `atomic_write/2` helper (tmp file + `File.rename!` in the same directory) and pass through the existing containment chokepoint (`contain/2`). `page/1` (existing read) now also returns `hash` (SHA-256 hex of the bytes at read time) and `prosemirror` (converted JSON) — a conversion failure is loud (`{:error, {:conversion_failed, msg}}`), never a silently-degraded page.
- **Rename/delete reference safety**: `delete/1` performs no reference cleanup of its own; `icm_entry_references/1` (backed by `Valea.ICM.Backlinks` — see "Backlinks" under Knowledge & editor depth below) lets the UI warn before a destructive delete. A rename's own link-rewrite is `Valea.ICM.LinkRewrite`'s job (see "Link conventions and the rename rewrite" below); the workflow-frontmatter reference union `Valea.ICM.References` used to also maintain (`Workflows/*.md` `sources:` entries) was deleted along with the workflow subsystem (Spec D §A) — page-link rename integrity is unaffected, it was always `LinkRewrite`'s job alone.
- **RPC — first constrained/typed returns**: `save_icm_page`, `create_icm_page`, `create_icm_folder`, `rename_icm_entry`, `delete_icm_entry`, `icm_entry_references` (all on `Valea.Api.ICM`) are the first RPC actions in the app to declare `constraints fields: [...]` on their `:map` return, so ash_typescript emits real typed TS interfaces instead of `Record<string, any>` — e.g. generated `SaveIcmPageFields = UnifiedFieldSelection<{hash: string, savedAt: string, ...}>[]`, not the Phase-1 `Record<string, any>` shape described above. This begins retiring that caveat for new surface without retro-typing `icm_tree`/`icm_page`/`cockpit_today` (out of scope). `Valea.Api.ICM.error_for/1` centralizes error mapping for every action on the resource: `:no_workspace` → `"workspace_not_open"`, other atoms → `to_string/1`, anything else (tuple reasons like `{:conversion_failed, msg}` or `{:rewrite_failed, file, reason}`) → `inspect/1` (never `to_string/1` on a tuple — it raises). Root-level creates use `argument :parent_path, :string, constraints: [allow_empty?: true]` so `create_icm_page("", "Name")` is valid. The existing `:page` action stays unconstrained (Phase-1, not retro-typed) but its map now carries the two new fields (`hash`, `prosemirror`) alongside the old ones.
- **Editor component family** (`frontend/src/lib/components/editor/`): `PageEditor.svelte` — tiptap 2.27.x on Svelte 5 (magus lifecycle pattern: editor built in `$effect` + `untrack`, destroyed in cleanup + `onDestroy`, exported `getJSON/setContent/focus/isEmpty`). Extensions: StarterKit, Placeholder, Link, Typography, TaskList/TaskItem, Table family, plus three framework-agnostic extensions vendored from `tiptap_phoenix` into `frontend/src/lib/editor/vendor/` (`slash_command.js`, `bubble_menu.js`, `drag_handle.js` — each with an origin header, `pushEvent`/LiveView plumbing stripped) and its `tiptap.css` (every `--ttp-*` variable re-mapped onto Paper & ink tokens, no DaisyUI vars live). `PageMeta.svelte` renders the save-status + context-cost meta line; `ConflictBanner.svelte` renders the amber suggestion-card conflict UI. `frontend/src/lib/stores/page-editor.svelte.ts` (`PageEditorStore`, one instance per open page, no singleton) is the save-loop state machine: states `clean | dirty | saving | conflict`; `noteChange` arms a 1000ms debounce, redirties (rather than losing an edit) if a change lands while a save is already in flight; `flush()` awaits an immediate save (called on route-leave and before the raw-view toggle); `externalChange(hash)` — driven by the route re-checking `icm_page`'s hash whenever the watcher's `icm_changed` fires — silently reloads while `clean`, or raises `conflict` while `dirty`/`saving`, with own-echo detection (a save's own resulting hash is not mistaken for a foreign conflict); `resolveReload()` discards local edits for disk truth, `resolveKeepMine()` refetches the hash and resaves the local JSON on top (last-write-wins recovery). `frontend/src/lib/api/client.ts` is still the sole `ash_rpc` importer, wrapping the six new generated calls (`saveIcmPage`, `createIcmPage`, `createIcmFolder`, `renameIcmEntry`, `deleteIcmEntry`, `icmEntryReferences`) in the same `{ok,data}|{ok:false,error}` envelope as Phase 1. Tree CRUD UI (`frontend/src/lib/components/knowledge/`: `NewEntryDialog`, `RenameDialog`, `DeleteDialog`, `EntryMenu`) shows the reference impact before a rename/delete confirms (`icmEntryReferences`) and never does optimistic tree surgery — the existing watcher → `icm_changed` pipeline is what refreshes the nav tree and list pane after every write.

## Agent slice

Real ACP agent sessions running against a primary ICM, a chat UI, and a
live, ask-gated permission model — the agent reads and interprets an ICM's
own prose (its `AGENTS.md`/`CLAUDE.md` map, `CONTEXT.md` routing tables, and
whatever documents a session names), and every side effect the agent
attempts passes through the same permission ask-gate a human answers in the
moment. There is no separate staged-approval queue and no
Valea-interpreted "workflow" format (Spec D §A deleted that pipeline
outright — see the Spec D banner at the top of this file); a document that
used to be a workflow contract is now just a markdown file the agent is told
to read and follow. Zero custom tools or MCP servers — the workspace file
tree is the agent's entire API (VISION.md principle 5).

### Trust model

The Claude adapter and the Claude Code runtime are **trusted infrastructure**
running as the user with the user's own credentials — Valea does not claim
OS-level sandboxing this phase (recorded hardening option for later). What it
provides is defense-in-depth for an honest-but-fallible agent, in layers: (1)
an in-memory `managedSettings` posture (never written to disk — see
"Permission model" below) routes risky operations to Valea's ACP permission
callback instead of silent auto-approval; (2) `PermissionPolicy`
decides allow/deny/ask with hard-deny precedence — including a hard
deny-by-default on ICM-internal secret material (see "Dynamic-tree riders"
below) — and audits every decision; (3) every write the agent makes goes
through that same ask-gate live, in the moment — there is no backend-staged
proposal file or deferred approval step for the agent to hand off to; the
human reviewing a permission ask (via `PermissionCard`'s line-diff, see
"Chat teaching" below) IS the approval; (4) `logs/audit.jsonl` + per-session
transcript files make every action reconstructable.

### Agent runtime

`Valea.Acp.Connection` (`backend/lib/valea/acp/connection.ex`) is a pure
codec (vendored from the `legend` donor, protocol brought current) — no IO,
just `{state, items, frames, effects}` reductions over ACP protocol version
1 (`@protocol_version 1`). Session start prefers `session/resume` (if
`sessionCapabilities.resume` is advertised) → `session/load` (full replay,
deduped by `messageId` against the persisted timeline) → `session/new`.
Config is `session/set_config_option`; `session/set_mode` is kept only as a
deprecated fallback. `session/cancel` answers every pending permission
request with `{outcome: "cancelled"}` before sending the cancel notification.
NDJSON lines are capped at 1 MiB (oversized/undecodable lines logged and
dropped, never crash the session); tool-call output is tail-kept at 64 KiB.
Unknown agent→client requests get a JSON-RPC `-32601` reply rather than
hanging the turn.

`Valea.Agents.SessionServer` (one GenServer per session, `restart:
:temporary`, under `Valea.Agents.SessionSupervisor`) spawns the adapter
through `Valea.Agents.ProcessRuntime` — an `erlexec` wrapper (vendored from
legend's `LocalPty`) run with `{:group, 0}, :kill_group, :monitor` so
`stop/1` kills the adapter's **entire process group**, never orphaning
children; this is the packaging risk item proven live in the Burrito
sidecar (Task 1). stderr is logged and truncated, never fed to the JSON
decoder. A 30 s handshake watchdog fails the session with a doctor-readable
reason if the adapter never answers `initialize`. Every timeline item is
appended to `logs/sessions/<id>.jsonl` as it arrives — line 1 is a
`session/v1` metadata record — a full workspace + ICM identity snapshot
(`workspace_id`/`workspace_name`/`icm_mount`/`icm_id`/`icm_name`/`icm_root`)
plus `id`, `acp_session_id`, `kind` (always `"chat"` now — see the
session-with-context primitive below), `workflow`/`run_id` (kept in the
schema, always `nil` post-Spec-D), `context_doc`/`input` (the
session-with-context primitive's own two locators, recorded verbatim),
`harness`, `generation`, `started_at`; the file is canonical, so a backend crash loses
nothing and a restart replays sessions read-only straight from disk
(`Valea.Agents.attach_or_replay/1`: live Registry hit, else fold the file).
Broadcasts go out on PubSub topic `agent_session:<id>`, generation-stamped.
Prompts are one-turn-at-a-time; a user's own prompt is echoed into the
timeline only once actually sent (the adapter doesn't echo it back on a
fresh session).

The harness seam is `Valea.Harness` (a 3-callback behaviour: `definition/0`,
`acp_command/1`, and `launch/2` — given the resolved `SessionScope` launch
object and its session directory, a harness materializes whatever bootstrap
files it needs and returns the directives the ACP launch path uses to spawn
and configure the adapter subprocess) with `Valea.Harnesses.ClaudeCode` as
the only implementation. The executable is resolved from **trusted app
config** (`Valea.App.Config`), never from a workspace or ICM file — an
opened folder can never make Valea execute an arbitrary binary.
`Valea.Agents.Env` passes the subprocess
a minimal allowlisted environment (`HOME`, `PATH`, `USER`, `LANG`/`LC_*`,
`TMPDIR`, `SHELL`, Claude/Anthropic auth vars when present) — never the
backend's own environment, so secrets like `SECRET_KEY_BASE` cannot leak
into the agent process. `Valea.Agents.Doctor` probes Node 22+, the adapter
binary (`--version`), and auth (`claude-agent-acp --cli auth status`),
returning ok/failed/unknown per check with a copyable remedy — probes run
through the same erlexec group-kill so a hung adapter can't leave orphans
during a doctor check.

### Permission model

**No settings file is ever written into or near an ICM.** `Valea.Agents.SessionSettings`
(`backend/lib/valea/agents/session_settings.ex`) is the successor to the
deleted `Valea.Agents.ClaudeSettings` (which used to write
`<workspace>/.claude/settings.json`, relying on `./**` globs anchored to
`cwd == workspace` — an assumption that stopped holding once a session's cwd
became an external ICM root, not the workspace). `content/1` renders the
permission posture as ABSOLUTE-path globs from the resolved `SessionScope`
(see [ICM project workspaces](#icm-project-workspaces) below): `allow`
covers `Read(<primary-icm-root>/**)` + `Read(<related-icm-root>/**)` per
resolved related ICM + each exact task input/write grant; `ask` covers
`Write`, `Edit`, `Bash`; `deny` covers the WORKSPACE's own protected
subdirectories (`logs/`, `config/`, `secrets/`, `runtime/`, `.git/`) and
SQLite files, plus `WebFetch`/`WebSearch` (no network at the harness layer
either) — AND, since Spec D §D5, a glob mirror of the ICM-internal secrets
deny tier: `Read`/`Edit`/`Write` denied on any `secrets/` directory segment,
`.env`/`.env.*` basename, `*.pem`, `*.key`, or `*credentials*` basename
under the primary or any related ICM root (case-sensitive here — globs
can't express the `.env.example` exception or case-insensitivity, so this
is defense-in-depth on top of, never a substitute for, `PermissionPolicy`'s
own case-insensitive `secret_relative?/1` check, which is the authoritative
enforcement). This posture is conveyed to the adapter **in memory only** —
`Valea.Harnesses.ClaudeCode.launch/2` JSON-encodes `content/1`'s map and
passes it via the SDK's `Options.managedSettings` channel
(`_meta.claudeCode.options.managedSettings` on `session/new` →
`--managed-settings <json>` argv to the underlying CLI subprocess) —
documented for exactly this case: "embedding applications ... that need to
enforce [lockdown settings] on the spawned subprocess without writing
root-owned files." The value is restrictive-only-filtered by the SDK itself
(a permissive key like `permissions.allow` would be silently dropped if it
tried to widen anything, though Valea's own posture never includes one for
that reason); `materialize!/1` writes only `context.md` (the session
bootstrap: primary/related ICM map — Spec D §A deleted the
`@workflow_contract` block this used to also inject for a workflow session)
under `<workspace>/runtime/sessions/<id>/`, never a settings file. This is what
makes Valea's ACP permission callback *reachable* — the posture forces
writes/Bash to fall through to `ask` before the callback is ever consulted,
closing the gap a bare callback with no upstream posture would leave open
(see `docs/notes/acp-launch-contract.md` for the full source/wire-level
proof and the live verification record).

`Valea.Agents.PermissionPolicy.decide/2` is the deciding layer: pure,
precedence **deny → allow → ask**, unclassifiable is always `ask`. It
separates three bases resolved by `Valea.Agents.SessionScope`:
`workspace_root` (protects operational state — the deny-listed
subdirectories and SQLite files above, or any candidate resolving entirely
outside every recognized area), `cwd` (the primary ICM's root — the base
every *relative* candidate path resolves against, never the workspace),
and `read_roots` (absolute: the primary ICM root, every resolved DIRECT
related ICM root, and exact task inputs — recomputed fresh at every
session start by `SessionScope.resolve/1`, so enabling/disabling/mounting
an ICM takes effect on the very next session without a restart; a
disabled/unmounted/unrelated ICM is simply absent from the set, falling
through to `ask` rather than a hard deny for a read, and to a hard deny
only when the candidate resolves outside the whole recognized universe —
workspace root, every read root, and every write grant together). Read-kind
calls are allowed only when every path falls inside some `read_root` (or is
`cwd`'s own `AGENTS.md`/`CLAUDE.md`) — never a blanket ICM-root-only or
workspace-root allow. Write-kind calls are allowed whenever every path
exactly matches the run's declared `write_paths` or falls under a granted
`write_root` — **regardless of `session_kind`.** Those grants are minted
only by Valea's own session-creation callers (never by the agent, and never
widened by anything the agent can say or do), so honoring a populated grant
for any session kind can't broaden what an agent can reach; a session with
no write grant still gets none — every such write asks. Every decision
(allow, deny, and ask alike) is audited (`permission_auto_allowed` /
`permission_auto_denied` / `permission_asked` / `permission_answered`); an
`:allow` always selects the `allow_once` option, never "always allow".
`PermissionPolicy.decide/2` implements this one split contract only — the
earlier workspace-relative variant (`ctx.workspace`/`ctx.extra_roots`, no
`workspace_root`/`cwd` split) was deleted once `SessionServer`, the only
caller, was confirmed to always build the split shape.

All path reasoning goes through `Valea.Paths.resolve_real/2` — symlink-aware
containment with real OS realpath semantics (symlinks resolved before a
following `..` is applied, `..` pops to the *physical* parent, 32-hop
bound), shared with the ICM containment chokepoint. This closes both the
`/var` vs `/private/var` (macOS) case and deliberate symlink-escape attempts
from any recognized root; a path resolving anywhere outside the whole
recognized universe is a hard deny, not merely an `ask`.

### Session creation, permission asks, and audit

There is no more staged-approval queue (Spec D §A deleted `Valea.Workflows`,
`Valea.Workflows.Runner`, and `Valea.Queue`'s proposal kinds/executors
outright — no migration, clean cut, no prod users). What replaced "run a
workflow" is one kind-agnostic **session-with-context primitive**:
`Valea.Api.Agents.create_session` (RPC `create_agent_session`) takes
`mount_key`/`generation` plus two OPTIONAL raw locator-map arguments:

- `context_doc` — an ICM locator (`{kind: "icm", icm_id, path}`) of a
  document to execute/consult. It gets NO extra permission grant — it lives
  inside the primary (or a related) ICM, already covered by
  `SessionScope.resolve/1`'s own read roots. The frontend composes the
  session's opening prompt to reference the document by its cwd-relative
  path ("Read and follow `<path>`…"); there is no server-side prompt
  template beyond that — the document itself is the program the agent
  interprets.
- `input` — an ICM or workspace locator granted as ONE exact read path,
  folded into `read_roots` by `SessionScope.resolve/1` (both the
  managedSettings `Read(<path>)` allow and the ACP `additional_roots`) —
  the same mechanism a workflow run's input grant used to use, now
  available to any session.

Both locators resolve **fail-closed, before the session starts**: `Manager.
check_generation/1` runs first (stale generation → `workspace_changed`),
then each locator resolves against the open workspace and must name a real,
readable file — `context_doc` failing that returns
`:context_doc_unavailable`, `input` returns `:input_unavailable`; either
aborts session creation entirely rather than starting a session that
silently lacks its context. On success, `Valea.Audit.append/2` records
`session_started` with `session_id`/`mount_key`/`context_doc`/`input`, and
`Valea.Agents.start_session/1` starts the `SessionServer` (see "Agent
runtime" above) with both locators threaded into the transcript's
`session/v1` metadata. The session's `kind` field itself collapses to
`"chat"` — kept in the schema for a future kind, but every session created
today is one.

Once the session is running, every side effect it attempts (an Edit/Write
tool call, a Bash command, a network fetch) goes through
`PermissionPolicy.decide/2` exactly as described above — there is no
second, queue-specific execution path. `Valea.Audit` is a single GenServer
serializing append-only writes to `logs/audit.jsonl` (`append/2` casts,
`append_sync/2` calls but still never raises to the caller — audit write
failures are logged loudly server-side but never block the underlying
action). Every entry carries `ts`, `type`, and the workspace `generation`.
Entry types include `session_started`, `permission_auto_allowed`/
`permission_auto_denied`/`permission_asked`/`permission_answered`,
`session_exited`, plus the ICM-mount lifecycle (`icm_mounted`/
`icm_unmounted`/`icm_enabled`/`icm_disabled`) and mail-sync entries (see
Mail below) — not an exhaustive list. Historical entries from the deleted
workflow/queue pipeline (`workflow_run_started`, `queue_item_created`,
`approval_intent`, `item_approved`, …) remain on disk in any workspace old
enough to carry them; `Valea.Api.Audit`'s `list_audit_entries` RPC (the
surface relocated from the deleted `Valea.Api.Queue`) and the frontend's
audit-sentence renderer both treat an unrecognized entry `type` leniently —
a neutral generic sentence, never a crash.

### Control-plane authentication

Every socket connection and `/rpc/*` request on the loopback port now
requires a **per-launch control token**: the desktop shell generates a
random token + a readiness nonce and passes both to the sidecar as env vars;
the sidecar requires the token on socket `connect/3` params and via the
`x-valea-token` header (`ValeaWeb.Plugs.ControlToken`, constant-time compare,
bare 401 on mismatch — no detail leaked). `GET /api/health` echoes the
nonce so the shell can detect a port collision (another process answering
on 4817 without the right nonce is refused — the window never loads against
it, so the token can't leak to a stranger's server). In production the
token is injected into the webview via a Tauri `initialization_script`
(`window.__VALEA_CONTROL_TOKEN`) before any page script runs; in dev the
Vite proxy carries a fixed dev token. The served SPA gets a real CSP
(`ValeaWeb.SpaController`): the header keeps `script-src 'unsafe-inline'`
only because SvelteKit's static-adapter hydration boots from an inline
script, but the actual enforcement is the browser intersecting that header
with the per-build sha256-hashed `<meta>` CSP SvelteKit emits — the
effective policy is hash-gated despite the permissive header. This closes
the `/rpc` origin/CSRF gap carried forward from the foundation review.

### Workspace runtime supervisor and generations

All workspace-bound processes now live under one `Valea.Workspace.Runtime`
supervisor (`:one_for_one`): `Valea.ICM.Watcher`, `Valea.Audit`,
`Valea.Mail.Supervisor` (one `Valea.Mail.Engine` per valid account), and
`Valea.Agents.SessionSupervisor` (a
`DynamicSupervisor` — every live agent session is its child, so it dies with
the workspace). There is no more one-shot queue-recovery `Task` — that
crash-recovery backstop belonged to the deleted queue subsystem (Spec D
§A) and was removed with it. `Valea.Workspace.Manager` stamps a monotonic
**generation** integer on every successful open; every runtime process and
broadcast carries it, and every mutating RPC (`create_agent_session`,
`save_icm_page`, `mount_icm`, …) checks it via `Manager.check_generation/1`
— a stale generation returns `workspace_changed` instead of silently acting
on the wrong workspace. A workspace switch
(`do_close/1` then `do_open/2`) fully terminates the old `Runtime` and every
child **before** the new one starts, so no process of the old workspace can
touch the new one; any failure partway through open rolls back every pid
already started.

Every workspace is born at its final `config/workspace.yaml` `version: 5`
shape (`Valea.Workspace.Scaffold.create/3`) — there is no versioned on-disk
upgrade step to run at open, and no version-migration module in the
codebase. The v1→v4 migration chain that once carried workspaces through the
Mail phase's schema bump and the embedded/by-reference ICM-mounts phases
(`Valea.Workspace.Migration`, plus the workspace-adoption/"adopt-by-move"
onboarding flow it fed) has been deleted along with the model it served
(Phase 11 clean-cut, per the spec's "Clean-cut implementation policy" — no
production users existed, so replacement rather than migration was the
chosen path); a pre-redesign workspace is recreated from the current
onboarding flow rather than upgraded in place, and `Valea.Agents.list_sessions/0`
silently skips any transcript whose line 1 is not the current `session/v1`
metadata record rather than attempting to read it.

## Mail (Spec E — mail as maildir)

A per-account, two-way mail subsystem: Valea mirrors each configured IMAP
account into a plain-file maildir under `sources/mail/<slug>/`, derives
readable markdown views from it, and executes ONLY declared, verified
operations back against the server. The agent's integration surface stays
files: it reads views, writes declared-op YAML into `ops/pending/`, and
proposes draft files — it can never touch the mailbox directly and can
never send (there is no SMTP anywhere; the one outbound path is the USER's
Push-to-Drafts APPEND). Full spec:
`docs/superpowers/specs/2026-07-17-mail-maildir-design.md`.

### `sources/mail/<slug>/` layout

```
sources/mail/<slug>/
  .account                  # identity file (host+username) — engine-owned
  .readopt                  # one-shot re-adopt authorization marker (transient)
  maildir/                  # the mirror: nested plain dirs, .folder identity files,
                            #   <msg_id>,U=<uid>:2,<flags> filenames — engine-owned
  views/messages/<id>.md    # derived markdown views (+ .fingerprints/ sidecars)
  views/attachments/<id>/   # extracted attachments
  ops/pending/              # agent-writable: declared-op YAML files
  ops/done/                 # engine-owned: claimed ops + .result/.state sidecars
  drafts/                   # agent-writable: proposed reply drafts
  spool/                    # engine-owned, deny-all: push payloads + manifests
  quarantine/               # damaged/foreign files moved aside, never deleted
```

`config/mail.yaml` (v4) is multi-account: a map of slug
(`^[a-z0-9][a-z0-9-]{0,31}$`) → `{provider, imap.{host,port,username},
folders.{drafts,sent,archive,trash}, sync.{window_days,interval_minutes,
max_message_bytes,exclude_folders}}`. Provider `gmail` swaps in the
`[Gmail]/...` special-folder names and the X-GM-MSGID move postconditions.
No credential ever lives in this file.

### Identity model

Two levels. An **occurrence** is `(account, folder, uidvalidity, uid)` —
where a message currently sits. A **message** is its `msg_id`
(`<date>-<from-slug>-<hash8>`, hash = sha256 **fingerprint of the raw
RFC822 bytes**) — the same message in two folders is one msg_id with two
occurrences. Message-ID headers are only a search shortcut; the fingerprint
always decides.

### Module map (`backend/lib/valea/mail/`)

- **`Valea.Mail.Supervisor`** / **`Valea.Mail.Engine`** — one Engine per
  VALID configured account, registered via `{:via, Registry,
  {Valea.Mail.Registry, slug}}`; `reload_settings_all/1` rehashes children
  when config changes. Each Engine owns its settings + RAM-only credential
  closure + status + poll timer. Activation verifies `.account` identity
  first (`identity_mismatch` refuses activation; resolve by purge).
  `mailbox_replaced` is sticky until the user re-adopts (one-shot
  `.readopt` marker consumed by the next successful pass). ONE
  background-work slot per Engine: sync passes AND ops batches are strictly
  serialized (`busy?/1`), ops run in monitored Tasks with deferred replies
  — `status/1` always answers instantly.
- **`Valea.Mail.SyncPass`** — push-then-pull. Push: recover + execute
  claimed ops. Pull: read-only Phase-A scan, replacement detection, then
  per-folder (with re-SELECT + divergence guard): UID-watermark discovery,
  windowed backfill (`backfill_complete` gate), flag refresh, deletions
  only after a successful complete `UID SEARCH ALL`, damage
  repair/quarantine. `UIDVALIDITY` reset → `Reconcile.folder_reset`
  (plan-then-apply); account-wide resets → `mailbox_replaced` fail-closed.
- **`Valea.Mail.Maildir`** — filename codec
  (`<msg_id>,U=<uid>:2,<flags>`), segment escaping, injective
  casefold+NFC folder→dir mapping (digest suffixes on collision),
  tmp→fsync→cur delivery.
- **`Valea.Mail.OpsFile`** — parses + validates the declared-op vocabulary
  (`move`, `flag` — closed set, unknown keys rejected), opaque-id
  no-replace claiming into `ops/done/` (link-safe: symlinked/hard-linked
  entries quarantined), per-op `.result.yaml`/`.state.yaml` sidecars.
- **`Valea.Mail.OpsExecutor`** — the ONLY code that mutates the mailbox.
  Durable `mail_pending_ops` ledger + fsynced spool manifests;
  execution-time verification before EVERY mutation (live UIDVALIDITY +
  fingerprint — a recycled UID can never be acted on); the
  COPY→confirm→mark-deleted→targeted-expunge ladder (never a bare EXPUNGE,
  `\Deleted` only via `uid_mark_deleted`); UNCHANGEDSINCE-guarded atomic
  flag replace with recorded baselines; Gmail X-GM-MSGID postconditions;
  confirm-first, non-destructive reconciliation for uncertain outcomes
  (`needs_review` parks, never guesses). Also owns the push path: atomic
  append claim (partial unique index → `duplicate_active`), hash-bound
  snapshot (CAS against the exact bytes the user reviewed), idempotent
  search-first APPEND (a lost response never double-appends).
- **`Valea.Mail.DraftMime`** (resurrected from git history) — draft file →
  plain-text MIME for the push APPEND; header-injection-hardened (composes
  from validated structs, RFC 2047, deterministic
  `<valea.push.<hash>@valea.invalid>` Message-ID).
- **`Valea.Mail.Transport`** / **`Valea.Mail.ImapClient`** — TLS-mandatory
  IMAP; `BODY.PEEK` everywhere; `examine/2` read-only selects; UID-only
  ops; COPYUID/APPENDUID parsing; optional CONDSTORE/QRESYNC; no send
  callback exists on the behaviour.
- **`Valea.Mail.Views`** / **`Valea.Mail.Index`** — derived markdown views
  (frontmatter incl. `account`/`folders`/`flags`, sidecar fingerprints,
  parse-checked) and the rebuildable SQLite index (`Index.rebuild/2`
  self-heals from raw maildir files on every activation).
- **`Valea.Mail.Store`** — Ash domain over hand-migrated
  (`migrate? false`) cache/ledger tables: `mail_sync_state`,
  `mail_uid_map`, `mail_messages`, `mail_pending_ops`. Everything but
  the ledger is rebuildable from files; the ledger is the durable ops
  record.
- **`Valea.Mail.Settings`** / **`Valea.Mail.Account`** /
  **`Valea.Mail.Doctor`** — v4 multi-account config, `.account`/`.readopt`
  identity files, per-account preflight (see Doctor below).
- **`Valea.Api.Mail`** — the account-scoped RPC surface (below).
- **Frontend**: `stores/mail.svelte.ts` (multi-account `MailStore`,
  `resupplyCredentials`, draft push with client-side sha256), components
  under `components/mail/` (`AccountSwitcher`, `FolderList`, `MessageList`,
  `MessageView` with archive/flag ops, `DraftsPanel`, `SetupPanel` with
  typed-confirm purge/re-adopt/discard, `MailDoctorPanel`,
  `SyncStatusLine`), route `routes/mail/+page.svelte`.
- **Desktop**: `desktop/src-tauri/src/keychain.rs` — unchanged Tauri
  commands; entries keyed `<workspace_id>` / `<slug>:imap` (mail) and
  `<workspace_id>` / `<slug>:ics` (calendar feed URLs — Spec F).

### Mounts + policy (agent access)

Each valid account surfaces as a synthetic `kind: :mail` mount
(`mail-<slug>`) — never a Knowledge/editor target, never an ICM-mutation
target. Sessions opt in per account: bare-string `mail-<slug>` entries in
`related_icms`, or `include_mounts` on `create_agent_session`.
`PermissionPolicy` (precedence: denied tool → protected → icm_secret →
mail rules → escaped → ask/allow): anything under `sources/mail` NOT in
scope is **denied, never asked** (casefold+NFC, segment-bounded); within
an in-scope mount, writes only under `ops/pending/` + `drafts/`, `spool/`
unreadable, everything else read-only. The managedSettings mirror repeats
the same rules as defense-in-depth; the launch surface carries no RPC
endpoint or control token (agent RPC isolation is test-asserted).

### Credential path

Unchanged model, per-account keys: RAM-only closure in each Engine, OS
keychain entry `"<workspace_id>" / "<slug>:imap"`, `resupplyCredentials`
iterates configured accounts with `credential == "missing"` after
restarts. Dev fallback: `VALEA_MAIL_PASSWORD_<SLUG>` read once at
activation.

### RPC surface (`Valea.Api.Mail`)

All account-scoped; every mutating action takes `generation`
(`Manager.check_generation/1`). `mail_status` (per-account `accounts` list
incl. state/pending_ops/held_folders/notices/folders + invalid-config
entries), `setup_mail_account`, `remove_mail_account`,
`purge_mail_account_files` + `readopt_mail_account` +
`discard_held_folder` (typed confirmation, backend-compared),
`set_mail_credential`, `mail_sync_now`, `mail_doctor`,
`create_mail_folders`, `list_mail_folders`, `list_mail_messages`,
`get_mail_message` (msg_id grammar + `Paths.resolve_real` containment),
`mail_apply_ops` (the UI's archive/flag actions through the same
executor), `push_draft_to_mailbox` + `list_mail_drafts` + `get_mail_draft`
(the push flow). Channel pushes (`workspace:events`) carry the account
slug: `mail_status`, `mail_sync`, `mail_message`.

### Doctor checks (`Valea.Mail.Doctor.run/1`)

Sequential, gated: `config_present` → `credential_present` →
`maildir_writable` → `tcp_reachable` → one connect fanning out to
`tls_ok` + `login_ok` + `folders` (the account's four CONFIGURED special
folders exist) + `move_capability`. `create_folders/1` creates the missing
configured folders (never `[Gmail]/*` system names). Never raises; every
check carries a copyable remedy; credentials scrubbed from error text.

### Safety invariants

- **TLS mandatory and verified, always** — no insecure escape hatch.
- **Execution-time verification before every mutation** — live UIDVALIDITY
  + raw-bytes fingerprint; no branch skips it.
- **Never a bare `EXPUNGE`; `\Deleted` only inside the executor's ladder,
  only after a confirmed destination copy.** `BODY.PEEK` everywhere.
- **Never expunge as policy** — the agent vocabulary is moves + flags; the
  only deletion-shaped server op is the ladder's targeted expunge of a
  copy-confirmed source.
- **No SMTP.** The transport has no send callback; the agent can only
  write draft FILES; `push_draft_to_mailbox` (user-only, hash-bound,
  idempotent) APPENDs to the account's Drafts folder — the user sends from
  their own mail client.
- **Fail-closed recovery** — identity mismatch refuses activation;
  mailbox replacement blocks until an explicit re-adopt; vanished folders
  hold their local copy pending a user decision (discard is typed-confirm);
  uncertain op outcomes park as `needs_review`, never guessed.

## Calendar (Spec F — ICS feeds in, Valea calendar out)

Read-only mirrors of the user's external calendars via polled ICS
subscription feeds (Google secret address, iCloud, Infomaniak — the one
mechanism every provider ships without OAuth/CalDAV/Graph), plus one
agent-writable local "Valea calendar" served back out as a tokened ICS
feed. File-first: every event the agent can see or create is a plain file
under `sources/calendar/`. Full spec:
`docs/superpowers/specs/2026-07-18-calendar-feeds-design.md`.

### `sources/calendar/` layout

`<slug>/` per subscribed feed (slug grammar as mail; `valea` RESERVED):
`.source` (host + URL-hash identity, the `.account` posture), `feed.ics`
(the last SUCCESSFUL raw snapshot — the single durable commit point),
`views/events/ev-<hash16>.md` (derived per-VEVENT markdown, one per master
plus per-override files; frontmatter carries the real UID + raw
RECURRENCE-ID — hostile UIDs never become filename material). Plus
`valea/events/<name>.md` — agent/user-created events, the ONLY
agent-writable path (markdown frontmatter: title/start/end/all_day/
location/status + body; fail-closed validation, no-follow, all-day ends
RFC-5545-EXCLUSIVE; UID derived from the file name so edits keep identity).

### Sync engine + the guarded derive

`Valea.Calendar.Supervisor` (beside `Valea.Mail.Supervisor`; also the
per-slug lifecycle serializer for setup/set-url/remove/purge/rehash) runs
one `Valea.Calendar.Engine` per valid source. A pass: conditional GET
(`Valea.Calendar.Fetch` — HTTPS-only, same-origin redirect cap 3, SSRF
address rejection before every connect, 20 MB/30 s caps, TLS verified) →
parse (`Valea.Calendar.Ics`, hand-written RFC 5545 with a pinned RRULE
subset; unsupported recurrence/TZID is UNAVAILABLE with a counted notice,
never fabricated; DST resolution deterministic) → the feed-level
acceptance guard → atomic `feed.ics` swap → the SHARED GUARDED DERIVE:
views rebuilt + swapped with a `.rev` marker FIRST, SQLite occurrence
rows + `derived_rev` in one transaction SECOND. The revision string
(snapshot hash : host zone : day-quantized window) is checked on EVERY
pass including 304s and re-derived on any mismatch, so crashes between
swaps, failed derives behind 304s, host-zone changes, and the rolling
window all self-heal; activation re-derives unconditionally (through the
same guard — a damaged on-disk snapshot can never erase a healthy
mirror). Occurrences live only in the index (`calendar_occurrences`,
tagged all-day/timed; rebuildable pure cache). The Valea calendar has no
engine: `Valea.Calendar.Local` validates and lists the event files LIVE
at query time.

### Credential posture

The FEED URL IS A CREDENTIAL (Google's secret address embeds a private
token): OS keychain `"<workspace_id>" / "<slug>:ics"`, RAM-only closure in
the engine, env fallback `VALEA_CAL_URL_<SLUG>`, never in any workspace
file, log, error, or status. Setup order is pinned: `setup_calendar_source`
→ `set_calendar_source_url` (the HTTPS admission gate + `.source` claim) →
keychain write only on acceptance. Restart resupply mirrors mail's.

### The served feed

`GET /calendar/feed.ics?token=<plain>` on the loopback endpoint
(token-exempt from the control token; 32-byte token stored only as sha256,
constant-time compare, 404 on every failure). Serves ONLY the rendered
Valea calendar — external mirrors are never served, so the endpoint cannot
exfiltrate provider data. Rendering composes VEVENTs from validated struct
fields with RFC 5545 escaping/folding (agent text can never smuggle raw
ICS). Reachability, honestly: loopback-only — calendar apps ON THIS
MACHINE can subscribe (Calendar.app "On My Mac"); server-side fetchers
(iCloud/Google/Outlook.com) cannot reach loopback, so no phone propagation
in this phase.

### Mounts + policy

ONE synthetic `calendar` mount (kind `:calendar`) whenever
`config/calendar.yaml` EXISTS (validity is status, not availability — a
fresh template workspace can grant calendar access and an agent can create
the first `valea/events/` file with no UI bootstrap). Sessions opt in via
bare-string `"calendar"` in `related_icms` or `include_mounts`.
`PermissionPolicy` tier (after mail, same semantics): anything under
`sources/calendar` outside an opted-in session is **denied, never asked**;
in scope, writes only under `valea/events/`, reads everywhere. The
managedSettings mirror enumerates per-source deny globs as defense-in-depth.

### RPC + UI

`Valea.Api.Calendar` (13 actions, mail conventions: generation guards,
slug-validated before I/O, typed confirms for purge/delete):
`calendar_status` (+ invalid-config entries + `config_invalid`),
`setup_calendar_source`, `set_calendar_source_url`,
`remove_calendar_source`, `purge_calendar_source_files`,
`calendar_sync_now`, `calendar_doctor`, `list_calendar_events` (half-open
zone-interpreted range, overlap matching, tagged all-day/timed rows, live
valea merge), `create/update/delete_valea_event`, `enable_calendar_feed` +
`rotate_calendar_feed_token` (plain token shown once). Channel pushes:
`calendar_status`, `calendar_synced` (`event_count` — snake, per spec),
`calendar_local_changed`. Frontend: `stores/calendar.svelte.ts`
(push-wired store, `<slug>:ics` resupply), `occurrenceToGridEvents`
adapter + all-day lane + selection popover on the existing grids, the
Valea event editor (inclusive dates at the edges, exclusive on the wire),
`CalendarSetupPanel` with doctor/typed-confirm purge and the served-feed
block. Cockpit `today()` gains a lenient calendar line. Doctor
(`Valea.Calendar.Doctor`): `config_present` → `url_present` → `reachable`
→ `parse_ok` → `freshness`, plus `feed_endpoint` — through the engine's
credential-safe `with_credentials` seam; no URL ever appears in output.

## ICM project workspaces

*(shipped on `feat/workspace-profiles`; spec: [Workspace Profiles, Mounted
ICM Projects & ICM-Scoped Sessions](superpowers/specs/2026-07-13-icm-project-workspaces-design.md).
Supersedes and replaces [ICM Mounts (Plan A)](superpowers/specs/2026-07-12-icm-mounts-design.md)
and [By-Reference ICM Mounts (Plan A2)](superpowers/specs/2026-07-12-icm-by-reference-design.md)
outright — Phase 11's clean-cut deleted every embedded-mount, `MOUNTS.md`,
workspace-version-migration, and adopt-by-move code path those designs
shipped; nothing from them survives at runtime.)*

An ICM (Interpretable Context Methodology project) is a portable, user-owned
folder — `icm.yaml`, `CLAUDE.md`/`AGENTS.md`/`CONTEXT.md`, `Workflows/*.md`,
reference content, optional `prompts/`/`scripts/` — that a workspace mounts
**by reference only**. There is no embedded form: every mounted ICM lives
outside the hidden workspace, at whatever path the user chose, and nothing
is ever copied or moved into the workspace to mount it. **Config truth is
the `icms:` map in `config/workspace.yaml`** — there is no filesystem
discovery pass, no `mounts/<name>/` directory convention, and no generated
`MOUNTS.md` routing file.

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

### `Valea.Mounts` — config-backed ICM registry

`Valea.Mounts` (`backend/lib/valea/mounts.ex`) builds one `mount()` per
`icms:` entry — `name` (the workspace-local **mount key**, the `icms:`
mapping key), `root` (the resolved absolute path), `manifest`
(`Valea.Mounts.Manifest`, `nil` if unloadable), `enabled`, `degraded`
(a reason string, or `nil`). `list/0,1` resolves each entry fresh on every
call: expands `~`, walks symlinks (`Valea.Paths.resolve_real/2`, self-base
trick), boundary-validates the result (rejects a path inside the workspace,
at `$HOME`/`/`, or an ancestor of the workspace), rejects a Claude Code
permission-glob metacharacter (`* ? [ ] { } ( )` — the resolved root is
spliced into a `Read(<root>/**)` allow entry later), confirms a folder
exists, and loads its `icm.yaml` (format 2 — a validated UUID `id`). Any
failure at any step **degrades** the entry (kept in the list, so the UI can
show something is wrong and let the user repair or remove it) rather than
dropping it, and a degraded entry is always excluded from `enabled/0,1`
regardless of its config `enabled` flag. Two cross-entry post-passes then
degrade every entry sharing a resolved root with another entry, and every
entry sharing a manifest `id` with another currently-healthy entry (an
ambiguous clone) — a physical ICM folder or a portable ICM's stable identity
can never be trusted twice in one workspace.

`mount/2` registers an already-existing, already-healthy ICM folder;
`create/3` mints a brand-new one (seeding `backend/priv/icm_template/`, the
only mutation that writes into an ICM's own folder) and mounts it;
`set_enabled/3` flips the `enabled` flag; `unmount/2` removes the config
entry — the folder is never touched. All four write only `config/workspace.yaml`'s
`icms:` map, preserving every other key byte-for-byte via a generic
recursive YAML encoder, and a mount's `path` is stored EXACTLY as given (a
`~`-form path survives) — the resolved absolute path is never persisted,
only audited. Because every mounted ICM is by-reference, mounting,
unmounting, enabling, or disabling one changes a filesystem boundary an
agent session can read, so all four are audited (`icm_mounted`/
`icm_unmounted`/`icm_enabled`/`icm_disabled`) with the mount's best-effort
resolved path.

`mount_for/1,2` (attribution by absolute-root prefix, most-specific-root on
overlap), `mount_by_key/2` (direct `icms:` key lookup), `mount_by_id/2`
(lookup by stable `icm.yaml` id among healthy mounts), and `scoped_roots/2`
(a primary ICM's own mount plus every ICM it DIRECTLY declares related —
the editor-time cross-ICM scan scope search/backlinks/rename-rewrite use)
round out the module. Every attribution function is attribution-only — a
caller doing real filesystem I/O still re-expands and re-contains the path
through `Valea.ICM.contain/2` against the resolved mount's own root.

### Addressing — `(mount_key, ICM-relative path)`, everywhere

`Valea.ICM` (`backend/lib/valea/icm.ex`) is the single containment
chokepoint for every ICM path, addressed by `(mount_key, rel_path)`:
`mount_key` resolves via `Mounts.mount_by_key/2` and must be enabled and
non-degraded; `rel_path` is relative to THAT ICM's own root — never
workspace-relative, never absolute, never prefixed with the mount key or
the ICM's own name. `contain/2` re-expands `rel_path` against the resolved
mount root and checks both lexically (the `..`-collapsed path stays a
string-prefix of the root) and physically (`Valea.Paths.resolve_real/2`,
so a symlink planted inside the ICM can't smuggle editor authority
elsewhere) — the same containment mechanism regardless of where the ICM
physically lives. `tree_for/1` returns ONE ICM's tree; a caller that needs
every enabled ICM's tree fetches `Mounts.enabled/1` and calls `tree_for/1`
once per mount key. `Valea.ICM.References`, `Valea.ICM.Search`,
`Valea.ICM.Backlinks`, and `Valea.ICM.LinkRewrite` all take the same
`mount_key` + ICM-relative shape.

Persisted app records (queue memory-update targets, workflow registry
entries, audit snapshots) do not carry a physical path at all — they carry
a **stable locator**, `Valea.Icm.Locator` (`backend/lib/valea/icm/locator.ex`):

```json
{"kind": "icm", "icm_id": "6f9f0c9e-3ccd-4fa5-a219-113a70618b55", "path": "Pricing/Current Pricing.md"}
{"kind": "workspace", "path": "sources/mail/messages/42.md"}
```

Both shapes are plain string-keyed maps (JSON-safe as-is, no atom-exhaustion
risk decoding one back from storage). `resolve/2` turns a locator back into
a physical path — the one place containment matters — by first looking the
ICM locator's `icm_id` up against the workspace's CURRENT mount table
(`Mounts.mount_by_id/2`: no match → `:icm_not_mounted`; a disabled mount →
`:icm_disabled`; a degraded one → `:icm_degraded`) and only then handing the
resolved root to `Valea.Paths.resolve_real/2` as the containment base — so a
persisted locator keeps resolving correctly across an ICM move or re-mount
under a different key. `Valea.Api.Agents.create_session`'s
`context_doc`/`input` arguments (the session-with-context primitive — see
"Session creation, permission asks, and audit" above) are exactly this
shape, and `resolve/2` is what fail-closes them at session start. `for_path/2`
is the inverse — given an already-known-good physical path, attribute it to
the owning mount (an ICM locator) or, if it isn't inside any mount, to the
workspace (a workspace locator) — used to snapshot a locator for something
persisted later; `Valea.Agents.SessionServer`'s `enrich_item/2` is the one
caller today, attributing a permission ask's touched path before
`RiskTier.classify/1` tiers it (see "Depth-aware RiskTier" under "Dynamic-tree
riders" below for the current classification rule — the `Workflows/*`-prefix
rule this used to apply was deleted with the workflow subsystem, Spec D
§A/§D3).

### Session scope and launch

`Valea.Agents.SessionScope.resolve/1` (`backend/lib/valea/agents/session_scope.ex`)
is the **single launch authority** — the only place mount-key lookup,
direct related-ICM resolution, and read/write-root assembly live. Neither
`Valea.Api.Agents.create_session` nor `Valea.Agents.create_follow_up/2`
re-derives any of these rules; both call `resolve/1` and use the scope it
returns. The pipeline: (1)
`Manager.check_generation/1` fails first on a stale generation
(`workspace_changed`); (2) `Manager.current/0` for the open workspace; (3)
`Mounts.mount_by_key/2` for the primary ICM, requiring enabled and
non-degraded (`:icm_unavailable` otherwise); (4) `Valea.Mounts.Context.resolve/2`
for the primary's DIRECT related ICMs (issues are attached as
`scope.context_issues` for the UI/doctor, not a hard failure — a chat
session may still start with a visible degraded-context warning); (5) `cwd`
is always the primary ICM's root, never the workspace root or a
caller-supplied path; (6) the harness adapter
(`Valea.Harnesses.ClaudeCode.launch/2`) materializes `context.md` and
computes the managed-settings posture, folding its directives
(`managed_settings`, `additional_roots`, `env`, `argv_extra`) into the
returned scope. Read/write grants (`read_paths`, `write_paths`,
`write_roots`) are taken exactly as the caller supplies them — a workflow
run's validated, per-input grants, or `[]` for a plain chat session; this
module never widens them.

Both the process spawn and the ACP `session/new` `cwd` are the primary
ICM's resolved root (`ProcessRuntime.start(%{cd: scope.cwd, ...})`,
`Connection.new(%{cwd: scope.cwd, ...})`) — never the workspace. The
workspace root is retained separately on the scope for transcripts, queue,
audit, source materialization, and the generation check. Because the ICM is
not nested under the hidden workspace (they are siblings somewhere under
the user's home directory, not ancestor/descendant), Claude Code's own
upward `CLAUDE.md` discovery from `cwd` never reaches the workspace at all
— no additional project instructions to suppress, by construction (see
`docs/notes/acp-launch-contract.md`, "Why cwd isolation is sufficient", for
the full reasoning and the live verification that ran against this exact
launch shape).

### Related ICMs — `CONTEXT.md` frontmatter, direct-only

`Valea.Mounts.Context.resolve/2` (`backend/lib/valea/mounts/context.ex`)
reads a primary ICM's own `<root>/CONTEXT.md` frontmatter:

```yaml
---
format: 1
related_icms:
  - id: 31201697-cff8-4d99-9dc5-b140e4178716
    name: "Legal & Administration"
    entrypoint: CONTEXT.md
---
```

A missing file, missing frontmatter, or an absent/non-list `related_icms`
all yield no related ICMs — this is a soft, optional declaration, never a
hard requirement. Each declared `id` resolves against the CURRENT workspace
mount table (`Mounts.mount_by_id/2`, requiring enabled) and its
`entrypoint` (default `CONTEXT.md`) is contained inside that related ICM's
OWN root via `Valea.Paths.resolve_real/2` — an entrypoint that resolves
outside that root is a hard reject (`:entrypoint_escapes`), never granted.
This module is **direct-only and cycle-safe by construction**: it never
reads a related ICM's own `CONTEXT.md`, only the primary's — a related ICM
that declares the primary (or anything else) back is simply never visited,
so a cyclic declaration is inert rather than an infinite loop or an
unbounded read-surface expansion. A resolved related ICM's root becomes an
`additionalDirectories` entry for the harness (read access, and Claude
Code's native tool-access mechanism) without its `CLAUDE.md` auto-loading
as project instructions — `SessionSettings.context/1`'s bootstrap text
names each related ICM's mount key, root, and entrypoint explicitly instead
("read their entrypoint only when your routing calls for it; they do not
load automatically").

### Watcher and doctor

`Valea.ICM.Watcher` (`backend/lib/valea/icm/watcher.ex`) watches the
workspace's own `sources/`, `config/` trees (a FIXED listener, started
once, never restarted) plus every ENABLED, non-degraded ICM's real root (a
DYNAMIC listener, swapped whenever that root set actually changes — there
is no more historical fixed `mounts/` watch, since no ICM lives inside the
workspace anymore). Any change under an enabled ICM root broadcasts
`{:icm_changed}` on `"icm"` — this is what a `today.json` edit rides too
(see "Today = a file the agent maintains" above): no dedicated watcher
wiring, just an ordinary content change under a watched ICM root. A change
to an ICM root's own `icm.yaml`, or to `config/workspace.yaml` itself (the
source of truth for both enabled/disabled state and every ICM's `path:`
declaration), additionally broadcasts `{:mounts_changed}` on `"mounts"` and
triggers a root-set recompute. The former fixed `queue/` watch and its
`{:queue_changed}` broadcast on a `"queue"` topic were removed along with
the `queue/` directory itself (Spec D §A deleted it from the workspace
template). Unlike the deleted Plan-A/A2 watcher, this one performs no
metadata regeneration of its own (there is no `MOUNTS.md` or
`.claude/settings.json` left to regenerate) — it only broadcasts and
recomputes its own watched set.

`Valea.Mounts.Doctor` (`backend/lib/valea/mounts/doctor.ex`) runs the SAME
six checks over every mount `Mounts.list/1` discovers — there is no more
embedded/external duality to branch on: `path_resolves` (does the `icms:`
path expand, symlink-walk, and land inside a boundary-safe, glob-safe,
existing folder?) gates five further checks (all `"unknown"` if it fails):
`manifest_format2` (a valid format-2 `icm.yaml`), `unique_id` (no other
ENABLED mount shares this ICM's manifest id), `related_icms` (every entry
this ICM's own `CONTEXT.md` declares resolves, via `Context.resolve/2`),
`secrets_hygiene` (a WARNING-class check — Valea's workspace deny-list
cannot reach into a folder it doesn't own, so a `secrets/` dir or
`.env`-like file at the mount root is flagged, never blocked), and
`watcher_live` (is this mount's root in the watcher's CURRENT watched set —
`"unknown"`, not `"failed"`, for a disabled mount). Exposed over RPC as
`icm_doctor` (`Valea.Api.Icms`, one mount at a time — the frontend fans it
out across every mounted ICM), rendered by `MountsDoctorPanel.svelte` on
`/knowledge`.

### Sidebar, routes, and onboarding

The main sidebar no longer renders the ICM file tree — that moved entirely
into Knowledge's list pane (`IcmTree.svelte`, unchanged in itself, is now
mounted only there). The sidebar shows mounted ICMs as project groups with
their recent sessions: `frontend/src/lib/components/shell/IcmProjects.svelte`
(presentational) over `icm-projects.ts`'s pure `orderGroups`/`isGroupExpanded`
logic — one row per enabled-or-degraded mount (a purely deactivated mount
lives in Workspace settings, not the sidebar), up to five sessions per
group (live sessions first, then newest ended; `Valea.Api.Agents.list_recent_sessions_by_icm/1`
supplies the grouped payload), a "Show all…" row once a group exceeds five,
and the active ICM's group always expanded. `MountIcmAction.svelte` is the
sidebar's "Mount an ICM" affordance (mount an existing folder, or create a
new one — `inspect_icm` previews a folder before mounting it).
`WorkspaceSwitcher.svelte` switches by internal workspace `id`, never a
filesystem path.

Routes carry the mount key explicitly rather than a global bare path:
`/knowledge/<mountKey>/<rel...>` (the ICM-relative page tree, task 4.3's
re-key — a bare path is no longer globally unique across mounted ICMs, so
the mount rides in the URL alongside it), `/chat?icm=<mount-key>` or
`/chat?session=<session-id>` (the session id is authoritative when
present — its own metadata determines the ICM; `?icm=` is only the
new-session/empty-state selection).

Onboarding never asks the user to create, locate, or open a workspace
folder (see the VISION.md trust copy this implements). **Start fresh** asks
what the ICM/business is called, offers a visible default ICM location
(`~/Documents/Valea/<name>/` with "choose another location"), creates the
portable ICM there, creates the hidden workspace automatically, mounts the
new ICM by reference, and opens its guided first session. **Use an existing
ICM** picks a folder, previews it via `inspect_icm` FIRST — before
anything mounts — then creates the hidden workspace automatically and
mounts the folder in place without copying or moving it. There is still no
move-based fallback — the prior Plan-A2 by-reference-vs-move onboarding
choice no longer exists — but a preview reporting `adoptable: true` (a
plain folder with no `icm.yaml` at all, boundary-safe otherwise — see
"Adopt-a-folder mounting" under "Dynamic-tree riders" below) now offers one
extra consent step in place of the ordinary mount step: "Add a small
identity file (`icm.yaml`) so Valea can recognize this folder", editable
name, then `adopt_icm` mints that one file and mounts by reference —
`frontend/src/lib/components/onboarding/onboarding-path.ts`'s
`adoptExistingIcm`, the sidebar Mount flow's own twin. Every other outcome
of a healthy or invalid/non-adoptable preview follows the same
create-workspace-then-mount sequence `useExistingIcm` always has.

### Session persistence

Session metadata (`session/v1`, line 1 of every `logs/sessions/<id>.jsonl`
transcript) carries a full identity snapshot: `workspace_id`,
`workspace_name`, `icm_mount` (the mount key), `icm_id`, `icm_name`,
`icm_root`, alongside `kind` (always `"chat"` post-Spec-D),
`workflow`/`run_id` (kept in the schema, always `nil` now),
`context_doc`/`input` (the session-with-context primitive's own two
locators — see "Session creation, permission asks, and audit" above),
`harness`, `generation`, `started_at`. A follow-up session inherits the
original session's workspace and primary ICM; if that ICM is no longer
mounted or healthy, the transcript stays viewable but follow-up creation is
disabled with a repair action. There is no reader for a pre-redesign
transcript — `Valea.Agents.list_sessions/0` silently skips any file whose
line 1 is not this exact schema.

## Agent-native ICMs (Spec D)

*(spec: [Agent-native ICMs design](superpowers/specs/2026-07-16-agent-native-icms-design.md).
Supersedes the Methodology Depth (Spec B) design's queue-backed
memory-update pipeline outright — see the banner at the top of this file
for the full deletion list. The two subsections below — risk tiers and the
chat ask-gate dialog — are Spec B survivors, updated in place for the
deletion; everything after them is new Spec D ground: the today.json
cockpit, the 3-layer starter seed, adopt-a-folder mounting, and the
ICM-internal secrets deny tier.)*

### Risk tiers — depth-aware

`Valea.Agents.RiskTier.classify/1` (`backend/lib/valea/agents/risk_tier.ex`)
is the one risk-tier classifier the ask-gate dialog below shares with every
permission-ask enrichment: `"high"` for an ICM locator whose ICM-relative
`path` has a basename in `AGENTS.md`/`CLAUDE.md`/`CONTEXT.md` AT ANY DEPTH
(case-sensitive basenames, any directory — real ICMs route with nested
`CONTEXT.md` files, so the tier can't be root-only), or is `icm.yaml` AT
THE ROOT; `"medium"` for anything else an ICM locator names; `nil` for a
workspace locator (content that does not belong to any ICM at all). The
`Workflows/`-prefix rule this classifier used to also apply was deleted
along with the workflow subsystem (Spec D §A/§D3) — an ICM's instruction
spine is now exactly its `AGENTS.md`/`CLAUDE.md`/`CONTEXT.md` files,
wherever they live in the tree, plus the root identity file. Classification
works directly off the locator's own `path` — already relative to the ICM's
root by construction (`Valea.Icm.Locator.icm/2`, `Locator.for_path/2`) —
never by re-attributing a workspace-relative or absolute physical path back
to a mount via `Valea.Mounts.mount_for/2` (that attribution step broke once
an agent session's `cwd` became the ICM root itself: the agent's own
self-reported paths are ICM-relative from the start, so re-deriving a
workspace-relative form to feed `mount_for/2` could only ever miss). The
tier is display + envelope metadata, never an access decision — it labels
a permission ask for the human deciding on it, but nothing in the
allow/deny/ask policy path reads or gates on it.

### Chat teaching — the ask-gate dialog

The permission-ask surface — unchanged in its allow/deny/ask semantics
(`PermissionPolicy.decide/2`, see "Trust model"/"Permission model" above) —
carries a real review UI on top. `Valea.Agents.SessionServer`'s
`enrich_item/2` (`backend/lib/valea/agents/session_server.ex`) stamps
`risk_tier` onto a `"permission"`-type ACP item whenever its `rawInput`
carries a file path and `RiskTier.classify/1` returns `"high"`/`"medium"` —
folded into the item the client already renders, never consulted by the
policy decision itself. Frontend: `derivePermissionView`
(`frontend/src/lib/components/agent/permission-view.ts`) reads `risk_tier`
and, for an Edit/Write tool call, builds a line diff from the raw
`old_string`/`new_string` (or `content` for a create) via the shared
`lineDiff` engine (`frontend/src/lib/diff/line-diff.ts` — LCS over lines,
capped at 400 rows; an oversized input skips the LCS pass and renders a
bounded delete-then-add instead); `tierCopy('high')` is the fixed high-tier
banner copy, "Changes how your assistant behaves". `PermissionCard.svelte`
renders the diff via the shared `DiffBlock.svelte` and a risk banner
(terracotta `border-warn-*`/`bg-warn-tint`/`text-warn-ink` for `high`, amber
`border-suggest-*`/`bg-suggest-tint`/`text-suggest-ink` for `medium`) above
the allow/reject buttons; a permission item with no path/diff data falls
back to today's plain display. This IS the human-in-the-loop surface for
every agent write now — see "Session creation, permission asks, and audit"
above for why there is no separate staged-approval path anymore.

### Today = a file the agent maintains

The cockpit renders files instead of Valea-generated content. Contract:
`today.json` at an ICM's root (tree-visible; not dot-prefixed), lenient
schema, all fields optional, unknown fields ignored — `updated_at`,
`prepared: [{title, summary, page}]` (`page` an ICM-relative path rendered
as a Knowledge link), `open_loops: [{title, source}]`, `notes`.
`Valea.Cockpit.today/0` (`backend/lib/valea/cockpit.ex`) merges `today.json`
across every enabled ICM (`Valea.Mounts.enabled/0` order, each section
provenance-labeled with the ICM name) with live state Valea itself owns:
mail counts (`review_count`/`inbox_count`/`configured`, degrading to zero
when the Mail Engine isn't up rather than crashing the whole payload) and
the 5 most recent sessions. Leniency contract: an ICM with no `today.json`
at all gets no section (not an error); unreadable/malformed JSON gets a
section with `"ok" => false` (the FE renders a calm "today.json couldn't be
read" note, never an error state); wrong-typed fields degrade to `nil`/`[]`
rather than failing the parse (mirrored on the frontend by
`normalizeCockpitToday` in `frontend/src/lib/today/cockpit.ts`, whose own
numeric fields degrade non-finite raw input to `0` the same way). `today.json`
changes ride the existing `icm_changed` watcher events — no new watcher
wiring. Valea itself never writes this file — the seeded `AGENTS.md`
documents the convention for the agent to maintain it; there is no more
seeded demo content standing in for it.

### 3-layer starter seed

`backend/priv/icm_template/` (Spec D §D1) is the "start fresh"/`create_icm`
seed, now a 3-layer prose pattern instead of a structured-folder
convention: `icm.yaml` (identity); `AGENTS.md` (the map — folder tree,
naming rules, the `today.json` convention, secrets rules — kept under
~100 lines) with `CLAUDE.md` as a relative symlink to it (`Valea.Mounts`'s
`link_claude_md!/1`, falling back to a one-line `@AGENTS.md` import file on
a filesystem/platform without symlink support); `CONTEXT.md` (a prose
router table, `| Task | Go here | You'll also need |`, plus a
`related_icms:` frontmatter block); one example domain folder (`clients/`)
containing its own `CONTEXT.md` and a `docs/` subfolder. There is no more
`Workflows/`, `Templates/`, or `Decisions/` in the seed — an ICM's internal
structure is now entirely up to the user and their agent; Valea supplies
containment and identity, not a taxonomy.

### Adopt-a-folder mounting

`inspect_icm` (`Valea.Api.Icms`) on a manifest-less folder that otherwise
passes every boundary/glob-safety check returns `ok: false` with a
human-readable `reason` AND `adoptable: true` (Task 12, Spec D §D4) —
`Valea.Mounts.Manifest.load/1` returning `{:error, :missing}` is the
`adoptable` signal; a healthy, an invalid, or a boundary-rejected folder
alike all report `adoptable: false`. Onboarding's "Use existing ICM" path
and the sidebar's Mount flow both offer one consent step on an adoptable
result — "Add a small identity file (`icm.yaml`) so Valea can recognize
this folder", with an editable name — which calls `adopt_icm`
(`Valea.Mounts.adopt/3`, `backend/lib/valea/mounts.ex`): mints a minimal
`{format: 2, id: <fresh uuid>, name}` manifest (the ONLY write this flow
ever performs inside the user's folder) and then mounts by reference
exactly like `mount_icm` does. A folder that already carries ANY
`icm.yaml` (valid or not) is refused adoption outright — adopting never
overwrites an existing identity. A mint failure aborts before any mount
config is touched (no partial mount). See "Onboarding" above for the full
onboarding-flow integration.

### ICM-internal secrets deny-by-default

`Valea.Agents.PermissionPolicy.decide/2` denies (not asks — the same
hard-deny tier the workspace's own protected subdirectories get) any
resolved candidate matching, at ANY depth inside the primary or any related
ICM root: a `secrets` directory segment, a `.env`/`.env.*` basename (except
`.env.example`), a `*.pem`/`*.key` basename, or a basename containing
`credentials` — all case-insensitive (`secret_relative?/1`, public
specifically so the managedSettings glob mirror's tests can assert the
same pattern set — see "Permission model" above for that mirror). Checked
against each ICM root by the candidate's ICM-relative segments, so
`mysecrets/`/`secretsfoo/` never false-positive-match a `secrets` SEGMENT.
`ctx.icm_roots` (`[primary_icm.root | related_icm.roots]`) is threaded in
by `SessionServer.init/1` alongside the existing `workspace_root`/`cwd`/
`read_roots`/`write_paths`/`write_roots` fields. There is no per-ICM
override in this spec — Doctor's existing `secrets_hygiene` warning (see
"Watcher and doctor" above) stays the visibility layer for a mount that
carries secret-shaped files at all.

## Knowledge & editor depth (Spec C)

*(pending merge on `worktree-knowledge-depth`; spec:
[2026-07-12-knowledge-depth-design.md](superpowers/specs/2026-07-12-knowledge-depth-design.md))*

Makes Knowledge a genuinely daily-usable surface: a `[[`/`@` link picker,
a backlinks panel, page templates, one-keystroke search, and image
paste/drag — implemented entirely as standard GFM markdown on disk, no
non-standard link/image syntax, no wikilink node type.

### Search — filesystem-is-the-index, FTS5 as the named upgrade seam

`Valea.ICM.Search.search/3` (`backend/lib/valea/icm/search.ex`) is
scan-backed, not index-backed: every ENABLED mount is walked concurrently
per query (`Task.async/1` per mount) under one SHARED 500 ms deadline
(`Task.yield_many/2` blocks at most `timeout` total, not per task, so N
slow mounts still return in roughly one timeout's wall time rather than
compounding); a mount that doesn't answer in time is `Task.shutdown(...,
:brutal_kill)`'d and named in the `skipped` list, never silently dropped.
Query terms are whitespace-split, downcased, AND-matched via
`String.contains?/2` — literal text only, no regex/query syntax, so there
is no injection surface. Title/heading/body hits are weighted (5/3/1 per
occurrence, capped) into a score, sorted, capped at the top 20. The
moduledoc states the seam explicitly: the RPC's return shape
(`%{results:, skipped:}`) is implementation-agnostic on purpose, so FTS5
can replace these scan internals later without a contract break. RPC:
`icm_search` → `:search` (`icmSearch`, args `query`, optional `mount`) and
`icm_paths_exist` → `:paths_exist` (`icmPathsExist`, arg `paths` — resolves
each through `Valea.Api.ICM`'s own local `contained_target/2` helper
(attributes the path to an enabled, non-degraded mount via `find_mount/2`
and confirms the physical resolution stays inside that mount's root), then
a plain `File.regular?/1`) on `Valea.Api.ICM` (`backend/lib/valea/api/icm.ex`).
The general-purpose cross-mount containment check this dangling-link check
used to share with the deleted memory-update proposal pipeline
(`Valea.Workflows.MemoryProposal.check_target/2`) was reimplemented locally
here once that module was deleted (Spec D §A).

### Backlinks — AST-confirmed, never a text match

`Valea.ICM.Backlinks` (`backend/lib/valea/icm/backlinks.ex`): a cheap
filename-substring pre-filter (raw content contains the target's basename,
literal or `URI.encode/1`-percent-encoded) narrows candidates before the
expensive step — a real `MDEx.parse_document/2` AST walk (version-proof:
matches on "has a `:nodes` key", not a specific struct list, so a future
MDEx node type that carries children the same way is walked correctly with
no code change) confirming only actual `MDEx.Link`/`MDEx.Image`
destinations that RESOLVE to the target's absolute path — a prose mention
of the filename or the same text inside a code span is never a Link/Image
node, so it never matches. `http(s)://`/`mailto:`/`#anchor` destinations
are ignored outright. Returns document-order text (`walk/2` prepends
during its reverse-preorder recursion, reversed once at the end), one
entry per source page (first matching link/image wins). The `references`
RPC (`icm_entry_references` → `:references`) returns `{pages: [...]}` —
`Backlinks.backlinks/2` (in-page links) behind the RPC surface. It used to
also return a `workflows` key (`Valea.ICM.References.referencing_workflows/1`,
Layer-2 stage-contract `sources:` entries) before that module was deleted
along with the workflow subsystem (Spec D §A).

### Link conventions and the rename rewrite

On-disk links/images are standard GFM only — `[text](dest)` /
`![alt](dest)`, destination `<…>`-wrapped only when it contains a space —
never a custom wikilink token. Path rule: relative-from-the-linking-page
when source and target are both inside the workspace; an absolute physical
path when either end is in an external (by-reference) mount.

`Valea.ICM.LinkRewrite` (`backend/lib/valea/icm/link_rewrite.ex`) rewrites
every enabled mount's confirmed inbound Link/Image destinations on a
rename — BYTE-SURGICALLY: only the destination bytes (plus `<>` wrapping
via its own `wrap/1` when the new destination needs it) change, using the
same right-to-left byte-offset splice `Valea.ICM.Splice.splice/3`
(`backend/lib/valea/icm/splice.ex`) — the REFERENCING file is never
round-tripped through the markdown↔ProseMirror converter, so the
determinism contract holds. Confirmation runs through
`Backlinks.destinations/3` (the same real AST parse backlinks uses); the
new destination is computed via `Valea.Paths.relative/2` (workspace-
relative pairs) or kept absolute (either end external).
`Valea.ICM.rename/2` returns `updated_pages` (this module's output) — the
workflow-reference sibling this once returned alongside
(`updated_workflows`) was removed with the workflow subsystem (Spec D §A).

Two documented limitations, neither of which ever corrupts a file:

- **Fence-duplicate rewrite.** The splice is textual, not positional: once
  a destination string is confirmed by at least one real Link/Image node
  anywhere in the file, EVERY textual occurrence of that exact string
  (inside `](dest)`/`](<dest>)` syntax) is spliced — including one that
  happens to also sit inside a code fence in the same file. The result is
  a still-plausible, still-readable path string, just not the intended one
  inside that fence.
- **Normalize-mismatch skip.** `Backlinks.destinations/3`'s `:url` is
  MDEx's entity-decoded/backslash-unescaped normalized destination; the
  splice searches RAW on-disk bytes for that normalized string. A
  destination WRITTEN in entity/escaped form (e.g. on-disk
  `[x](Foo&amp;Bar.md)`) never matches its own normalized bytes, so the
  splice silently skips it — the link is left dangling after the rename,
  never corrupted. Valea's own converter always serializes raw characters,
  so this only exposes non-Valea-authored markdown in an external mount.

### Templates

`Templates/` is a plain top-level folder per mount, holding ordinary `.md`
pages. `Valea.ICM.create_page_from_template/3` (`backend/lib/valea/icm.
ex`) substitutes exactly two placeholders textually (`String.replace/3`,
not markdown-aware — runs inside code fences too): `{{date}}` (`Date.
utc_today() |> Date.to_iso8601()`, `YYYY-MM-DD`) is substituted BEFORE
`{{title}}` — deliberately date-first, so a new page literally named
`{{date}}` (i.e. `{{date}}` appears inside the substituted title text)
never gets its title-borne `{{date}}` text caught by an already-completed
date pass. Any other `{{...}}` placeholder is left byte-for-byte verbatim
— not a general template engine, no injection surface. Template and new
page must attribute to the SAME mount (`:cross_mount_template` otherwise).
RPC: `create_icm_page_from_template` → `:create_page_from_template`
(`createIcmPageFromTemplate`, args `parent_path, name, template_path`) on
`Valea.Api.ICM` — the RPC itself never restricted where a template could
live; that restriction lived only in the frontend's discovery layer, and
Spec D §D2 made discovery recursive (any folder named `templates/`,
case-insensitive, at any depth — see "template select" under "Frontend —
image paste/drag..." below). The 3-layer starter seed (Spec D §D1, see
"Dynamic-tree riders" below) ships no `Templates/` folder at all — a mount
that wants templates creates its own `templates/` folder(s) wherever makes
sense for that ICM.

### Images — `Assets/` + `/files` endpoints

`ValeaWeb.FilesController` (`backend/lib/valea_web/controllers/
files_controller.ex`) writes to and serves `Assets/<page-slug>-<hash8>.
<ext>` at the target mount's root, addressed by `(mount_key, ICM-relative
path)` — task 4.4's re-key onto the same vocabulary `Valea.ICM` uses,
never a raw workspace-relative or bare absolute path. `POST /files/upload`
is token-gated (its own `:files_upload` router pipeline mirrors `:rpc`'s
`ValeaWeb.Plugs.ControlToken`), capped at 10 MB (`@max_upload_bytes
10_000_000`, checked via `File.stat/1` on the parsed upload — the
transport-level `Plug.Parsers` `length:` in `endpoint.ex` is set higher,
`12_000_000`, purely as headroom so this business check runs first), and
allowlists BOTH extension and `content_type` (`.png/.jpg/.jpeg/.gif/.webp`
→ their exact MIME type — deliberately no `.svg`, which is scriptable).
Both actions resolve `mount_key` via `Valea.Mounts.mount_by_key/2`
(requiring ENABLED + non-degraded) and contain the ICM-relative path
against that mount's own root via the same symlink-aware
`Valea.Paths.resolve_real/2` containment `Valea.ICM` uses — a symlink
planted inside a mount's `Assets/` folder is defeated the same way. `GET
/files/raw` is deliberately TOKEN-EXEMPT — its own unauthenticated
`/files` scope on the plain `:api` pipeline in `router.ex` — because an
`<img>` tag cannot send custom headers, and the Phoenix endpoint only
ever binds loopback (127.0.0.1): the endpoint exposes only files a local
process could already read. It sets `x-content-type-options: nosniff`
and `content-disposition: inline`, and always derives `content-type` from
the allowlisted file EXTENSION — never from anything client-supplied or
stored — so a mismatched upload can never make the serve path emit an
attacker-chosen content-type.

**The `Assets/` stance.** Writing a pasted image into the external ICM's
own `Assets/` folder is a deliberate, reviewed exception to "Valea-
generated runtime/settings files never land inside a user-owned ICM"
(spec invariant 9) — but not actually in tension with it: the image is
USER CONTENT the human explicitly pasted/dropped into their own note, not
a Valea-generated runtime/settings artifact, so it belongs in the ICM
exactly the way the note's own text does. This is also why `upload/2`
does NOT pass through the agent `Valea.Agents.PermissionPolicy` ask-gate
— that gate mediates writes an AGENT initiates on the human's behalf; an
image paste/drop is a human directly performing the write via an explicit
UI gesture, so the human is already the approver.

### Frontend — image paste/drag, link picker, palette, backlinks UI

- **Image extension** (`@tiptap/extension-image` in `PageEditor.svelte`):
  an image node's `src` always holds the on-disk relative (or
  absolute-external) reference the upload endpoint returned, never a
  `/files/raw?...` URL — that mapping (`resolveImageSrc`, `frontend/src/
  lib/editor/image-upload.ts`) is applied only at DISPLAY time, inside the
  extension's `renderHTML`, so a page's serialized markdown stays portable.
  `isAllowedImage`/`allowedImageFiles` mirror the backend's exact
  extension+content-type allowlist so a doomed upload is never attempted;
  `PageEditor.svelte`'s `handlePaste`/`handleDrop` upload every allowed
  image in a multi-file paste/drop, not just the first, via
  `api.uploadImage` — plain `fetch('/files/upload', ...)`, not an Ash RPC
  call (see `frontend/src/lib/api/client.ts`'s `uploadImage`).
- **`[[`/`@` page-link picker**: `frontend/src/lib/editor/vendor/
  page_link_suggestion.js` (a `@tiptap/suggestion`-based factory,
  vendored, instantiated TWICE — once per trigger char — each with its own
  `PluginKey` so the two don't clobber shared plugin state) plus pure
  `frontend/src/lib/editor/page-link.ts` (`pickerItems`, `linkDestination`,
  `parentOf`). `allowSpaces: true` keeps the suggestion match open across
  spaces so a multi-word title/query can be typed at all. Item selection
  inserts a STANDARD link mark (`marks: [{type: "link", attrs: {href}}]`)
  — never a custom wikilink node; an empty-query "Create" item calls
  `api.createIcmPage` first, then inserts the link to the freshly created
  page (create-on-empty).
- **Cmd+K search palette**: `frontend/src/lib/components/palette/
  SearchPalette.svelte`, mounted once, globally, in `frontend/src/routes/
  +layout.svelte` (a `metaKey || ctrlKey` + `k` window keydown listener);
  `frontend/src/lib/components/palette/palette.ts` is the pure reducer
  (`paletteReduce`) plus `highlightSegments`, which bolds matched terms as
  plain TEXT segments (never `{@html}`) even though the underlying
  title/snippet text comes straight from page content. The empty-query MRU
  list is `frontend/src/lib/stores/recent-pages.ts`
  (`localStorage['valea.recent-pages']`, most-recent-first, capped at 10,
  guarded against a missing/locked-down `localStorage`).
- **Link navigation + dangling links**: `frontend/src/lib/editor/
  link-nav.ts`'s `classifyHref` (page / external / file) drives
  `PageEditor.svelte`'s click handler — a `.md` href navigates in-app, an
  `http(s):` href opens a new tab, anything else no-ops — and
  `collectDocLinkPaths` feeds `api.icmPathsExist` to build the dangling set
  the knowledge route re-checks on page load and after every save. A
  dangling page-link is decorated via a ProseMirror plugin (`PluginKey
  ('link-dangling')`, CSS class `link-dangling`) and clicking it opens a
  create-confirm dialog instead of navigating.
- **Backlinks panel + impact dialogs + template select**: `BacklinksPanel.
  svelte` (rendered in the page rail, `frontend/src/routes/knowledge/
  [...path]/+page.svelte`) and `frontend/src/lib/components/knowledge/
  backlinks-panel.ts` (`groupReferences`, `impactLine`/`deleteImpactLine`
  — singular/plural, compound-subject copy, "updates" framing for rename
  vs. "will lose the link/reference" framing for delete) share one source
  of truth over `icm_entry_references`'s `{pages}` (the workflow-reference
  half of this RPC was deleted with the workflow subsystem — Spec D §A).
  `RenameDialog`/`DeleteDialog` render the same impact line before the
  user confirms. `frontend/src/lib/components/knowledge/
  template-options.ts`'s `templateGroups` (Spec D §D2, Task 14) is
  recursive rather than mount-scoped-to-one-folder: it discovers every
  folder named `templates` (case-insensitive) at ANY depth in the target
  mount's tree and offers one select group per folder found (each group's
  `.md` pages, tree-sorted) — the backend RPC
  (`create_icm_page_from_template`) never restricted template location,
  this discovery layer was the only thing that used to pin templates to a
  single top-level folder. Still same-mount only (the RPC requires
  template and new page to share a mount). Feeds `NewEntryDialog`'s
  "Start from" select.

## Design system pointer

UI follows the "paper & ink, with a green pen for approval" design system: [docs/DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) (canonical source: `docs/design/cockpit-design-system-v1.pdf`). Two-layer token architecture (raw tokens → shadcn-svelte semantic variable mapping); feature code never touches raw Tailwind classes directly. Shell layout is a reusable four-column grid (Sidebar · optional ListPane · Main · optional Rail) implemented as an `AppShell` component family on shadcn-svelte primitives.

### Shell component inventory (`frontend/src/lib/components/shell/`)

- `AppShell.svelte` — the four-column grid shell (Sidebar · optional ListPane · Main · optional Rail); pages compose inside it.
- `AppFrame.svelte` — outer frame/chrome wrapper around `AppShell`.
- `Sidebar.svelte` — left nav column (top-level sections, e.g. Today, Knowledge).
- `SidebarItem.svelte` — single sidebar row/link.
- `Rail.svelte` — optional right-hand rail column.
- `ListPane.svelte` — optional second column for list-over-detail views (e.g. Knowledge's folder/page list).
- `IcmTree.svelte` — the live ICM nav tree for ONE mounted ICM; consumes `icmStore` (`frontend/src/lib/stores/icm.svelte.ts`) and re-renders on `icm_changed`. Rendered only inside Knowledge's `ListPane` — the main sidebar no longer carries a file tree (see [ICM project workspaces](#icm-project-workspaces) above).
- `IcmProjects.svelte` — the main sidebar's ICM project groups + recent sessions (presentational; `icm-projects.ts` owns the ordering/capping/expansion logic).
- `MountIcmAction.svelte` — the sidebar's "Mount an ICM" affordance (mount an existing folder or create a new one).
- `WorkspaceSwitcher.svelte` — the sidebar-footer workspace switcher, addressed by internal workspace `id`.
- `SectionOverline.svelte` — small caps section label used throughout (onboarding cards, sidebar groups).
- `StatusPill.svelte` — small status/badge pill.
- `EmptyState.svelte` — generic empty-state block (stub pages, empty folders).
- `index.ts` — barrel export.

Related, not under `shell/` but part of the same top-level chrome:

- `frontend/src/lib/components/onboarding/` — `Onboarding.svelte` (root two-card + trust bar screen, rendered by `+layout.svelte` when `workspaceStore.state === 'none'`), `CreateWorkspaceDialog.svelte`, `OpenWorkspaceFlow.svelte`, `WhatsInAWorkspace.svelte`, `TrustBar.svelte`.
- `frontend/src/lib/components/today/` — `OpenLoops.svelte` (plain checklist rows over the `today.json`-sourced `open_loops`; the checkbox is visual only, no interactive control yet), the sole surviving component of the pre-Spec-D Today cockpit. Prepared items and the mail summary line are now rendered directly inline in `frontend/src/routes/+page.svelte` itself (the `today.json` rewrite, Spec D §C) rather than through a dedicated per-item card component — see "Today = a file the agent maintains" above.
- `frontend/src/lib/components/ui/` — shadcn-svelte primitives (button, dialog, input, label, badge, separator, skeleton, scroll-area, tooltip).

## Spec index

- [2026-07-09-valea-foundation-design.md](superpowers/specs/2026-07-09-valea-foundation-design.md) — Foundation: monorepo scaffold, workspace creation/selection, app shell, Today cockpit (seeded), ICM tree in nav.
- [2026-07-10-icm-editor-design.md](superpowers/specs/2026-07-10-icm-editor-design.md) — ICM editor: markdown↔ProseMirror converter + determinism contract, version-guarded saves, reference-aware tree CRUD, typed RPC.
- [2026-07-10-agent-slice-design.md](superpowers/specs/2026-07-10-agent-slice-design.md) — Agent slice: ACP agent runtime, trust/permission model, control-plane auth, workspace runtime generations, ICM layer mapping. **Its queue/audit approval-flow sections are superseded** by Spec D's session-with-context primitive + live ask-gate (see the banner at the top of this file and "Session creation, permission asks, and audit" above) — historical record only for that part; the rest still describes the live agent runtime.
- [2026-07-11-mail-design.md](superpowers/specs/2026-07-11-mail-design.md) — Mail: IMAP sync-to-files engine, normalized message file format, OS-keychain credential handoff, connection doctor, `/mail` UI. **Its `queue_item/v2` mailbox-ops section is superseded** by Spec D §E (see "Mail interim" above) — `MailboxOps`/`DraftMime` are deleted; the rest of the sync/read path is unchanged.
- [2026-07-12-icm-mounts-design.md](superpowers/specs/2026-07-12-icm-mounts-design.md) — **Superseded**, historical record only (see its own banner). ICM mounts (Plan A): `mounts/<name>/` replaced the single `icm/` tree, manifest-based discovery, `MOUNTS.md` generated routing, per-mount `read_roots`, v3→v4 migration, mounts-aware Knowledge UI, adopt-by-move onboarding.
- [2026-07-12-icm-by-reference-design.md](superpowers/specs/2026-07-12-icm-by-reference-design.md) — **Superseded**, historical record only (see its own banner). By-reference mounts (Plan A2): external `kind: "path"` mounts referenced in place, root-set containment, managed-settings external `Read` allows, per-mount doctor, declare/undeclare RPCs + audit, by-reference-default onboarding.
- [2026-07-12-methodology-depth-design.md](superpowers/specs/2026-07-12-methodology-depth-design.md) — **Superseded**, historical record only (see the banner at the top of this file). Methodology depth (Spec B): server-derived risk tiers (its `Workflows/`-prefix tier rule is gone, replaced by Spec D §D3's depth-aware rule — the risk-tier classifier and the chat ask-gate dialog itself both survive, updated in place), memory-update proposal pairs + staging write/read grants, the queue's `apply_page_content` executor and content-hash crash recovery, optional rejection reasons, and the decisions digest + Distill Decisions reflection workflow — this queue-backed proposal machinery is deleted outright by Spec D §A.
- [2026-07-12-knowledge-depth-design.md](superpowers/specs/2026-07-12-knowledge-depth-design.md) — Knowledge & editor depth (Spec C): scan-backed search with an FTS5 upgrade seam, AST-confirmed backlinks, byte-surgical rename link-rewrite, page templates, contained image upload/serve endpoints, the `[[`/`@` page-link picker, the Cmd+K search palette + MRU + dangling-link handling, and the backlinks panel + page-aware impact dialogs + template select UI. Its workflow-frontmatter reference union (`Valea.ICM.References`) is deleted by Spec D §A; page-link rename integrity (`Valea.ICM.LinkRewrite`) is unaffected. Template discovery is made recursive by Spec D §D2.
- [2026-07-13-icm-project-workspaces-design.md](superpowers/specs/2026-07-13-icm-project-workspaces-design.md) — **Shipped** (see [ICM project workspaces](#icm-project-workspaces) above): private, hidden, id-based Valea workspace profiles; user-owned ICM projects mounted only by reference; one primary ICM and `cwd` per session; explicit cross-ICM context; project/session navigation; simplified onboarding. Supersedes Plan A/A2 outright — their implementation has been fully removed (Phase 11 clean-cut). Substrate for Spec D below; not reopened by it.
- [2026-07-16-agent-native-icms-design.md](superpowers/specs/2026-07-16-agent-native-icms-design.md) — **Shipped** (Spec D — see the banner at the top of this file and every section it points to). Deletes the workflow subsystem outright; replaces "run" with the session-with-context primitive (`context_doc`/`input`); makes Today a file (`today.json`) the agent maintains; adds adopt-a-folder mounting, a depth-aware `RiskTier`, an ICM-internal secrets deny tier, and the 3-layer prose starter seed; re-scopes Mail's outbound path to manual until a future mail redesign.
- [2026-07-17-mail-maildir-design.md](superpowers/specs/2026-07-17-mail-maildir-design.md) — **Shipped** (Spec E — see [Mail](#mail-spec-e--mail-as-maildir) above): multi-account windowed maildir mirrors, declared-ops two-way sync (moves + flags only, durable ledger, execution-time verification, never expunge as policy), derived views + SQLite index, per-account mail mounts with deny-not-ask, agent drafts + user-only Push-to-Drafts (no SMTP), Gmail provider profile, fail-closed identity/replacement recovery. Supersedes the 2026-07-11 mail spec's sync/read path.
- [2026-07-18-calendar-feeds-design.md](superpowers/specs/2026-07-18-calendar-feeds-design.md) — **Shipped** (Spec F — see [Calendar](#calendar-spec-f--ics-feeds-in-valea-calendar-out) above): ICS subscription-feed mirrors (no CalDAV/OAuth/Graph), the hand-written RFC 5545 parser with honest unsupported-recurrence/timezone handling, the two-store guarded derive protocol, the agent-writable Valea calendar + tokened loopback served feed, one calendar mount with mail's deny-not-ask tier, feed-URL-as-credential keychain posture.
