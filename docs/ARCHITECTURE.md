# Valea — Architecture

Condensed map of the standing decisions. Full reasoning per feature lives in
[docs/superpowers/specs/](superpowers/specs/); this file states outcomes, not
rationale, and grows with each feature/spec.

> **Status note:** This document records Valea's currently implemented
> architecture. The approved next restructuring is defined in [Workspace
> Profiles, Mounted ICM Projects & ICM-Scoped
> Sessions](superpowers/specs/2026-07-13-icm-project-workspaces-design.md):
> private workspace profiles, externally mounted ICMs, one primary ICM per
> session, and project-oriented navigation. Until that work is implemented,
> the sections below remain the as-built reference.

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

The user owns a workspace folder; everything canonical is a readable file inside it. SQLite is cache/index, not source of truth, and it too lives **inside the workspace** (`{workspace}/app.sqlite`) so the folder is fully self-contained and portable.

- **Backend boots workspace-less.** Boot order: Telemetry → PubSub → `Workspace.Supervisor` → Endpoint. `Workspace.Supervisor` (`Supervisor`, `rest_for_one`) holds a `DynamicSupervisor` plus the `Workspace.Manager` GenServer. The Ecto Repo is *not* a static supervision child — it starts under the `DynamicSupervisor` only while a workspace is open, so there is no database until then.
- **App-level config** (`Valea.App.Config`) is a small JSON file in the OS app-data dir (e.g. `~/Library/Application Support/valea/config.json` on macOS): known workspaces (path, name, last-opened-at) + last-opened path. A plain module (not a process) — solves bootstrapping before any workspace exists, without a database.
- **`Valea.Workspace.Manager`** (GenServer) owns the open-workspace lifecycle: `create/2` scaffolds a new workspace from `backend/priv/workspace_template/` (via `Valea.Workspace.Scaffold.create/1`) and opens it; `open/1` validates the workspace marker structure, starts `Valea.Repo` under the `DynamicSupervisor` pointed at `{path}/app.sqlite`, runs Ecto migrations, records the workspace in app config, and broadcasts `{:workspace_opened, %{path:, name:}}` on the `"workspace"` PubSub topic. `close/0` (broadcasts `{:workspace_closed}`) and `current/0` (`{:ok, %{path:, name:}} | {:error, :no_workspace}`) round it out. At boot, `handle_continue(:auto_open, _)` reopens `App.Config.read()["last_opened"]` automatically if it still validates as a workspace (falls back to workspace-less if the path no longer validates). After migrations, the Manager also starts `Valea.ICM.Watcher` under the same `DynamicSupervisor`; it watches `{workspace}/mounts` and `{workspace}/queue` (each with its own 200ms debounce timer), broadcasting `{:icm_changed}` on the `"icm"` topic for any change under `mounts/`, `{:mounts_changed}` on the `"mounts"` topic when the change touches the mount SET itself (see [ICM mounts (Plan A)](#icm-mounts-plan-a) below), and `{:queue_changed}` on the `"queue"` topic for any change under `queue/`.
- **Rollback is two-tier, and only one tier is implemented today.** Process-level: `open_workspace/2,3` in `Manager` starts the Repo then the watcher one at a time, accumulating started pids; if either step fails, every pid started so far is torn down via `DynamicSupervisor.terminate_child/2` before the error returns — a half-opened workspace never keeps a Repo or watcher running under a name a later open/create could mistake for success. Filesystem-level: `Valea.Workspace.Scaffold.create/1` (`File.mkdir_p` + `File.cp_r` from the template) has **no rollback** — if `File.cp_r` fails partway through copying `backend/priv/workspace_template/`, the partially-written target directory is left on disk as-is; nothing deletes it. In practice this window is small (a local recursive copy of a few dozen small template files) and no acceptance test has hit it, but it's a known gap, not a designed guarantee.
- Migrations run **at workspace open**, in every environment — not at release boot, since the database doesn't exist until a workspace is open.
- Open/create failures are loud and specific; a workspace is never presented as healthy when half-seeded (process-level, per above).

## API layer

- **`ash_typescript`**: Ash actions on the `Valea.Api` domain (`backend/lib/valea/api.ex`, extension `AshTypescript.Rpc`) exposed as typed RPC, with a generated TypeScript client (`frontend/src/lib/api/ash_rpc.ts`, committed) giving end-to-end type safety. No AshJsonApi, no hand-maintained client types. All three resources (`Workspace`, `ICM`, `Cockpit`) are data-layer-less Ash resources — thin adapters over plain Elixir modules (`Valea.Workspace.Manager`, `Valea.ICM`, `Valea.Cockpit`), not Ecto-backed.
- **RPC action list** (`rpc_action(:name, :action)` in `Valea.Api`, generated TS function name in parens):
  - `Valea.Api.Workspace`: `get_workspace` → `:current` (`getWorkspace`) — reports `{open, path, name}`, `open: false` when no workspace; `create_workspace` → `:create_workspace` (`createWorkspace`, args `parent_dir`, `name`); `open_workspace` → `:open_workspace` (`openWorkspace`, arg `path`); `close_workspace` → `:close_workspace` (`closeWorkspace`); `recent_workspaces` → `:recent` (`recentWorkspaces`); `inspect_workspace` → `:inspect_workspace` (`inspectWorkspace`, arg `path` — used by the "what's in this folder" onboarding preview).
  - `Valea.Api.ICM`: `icm_tree` → `:tree` (`icmTree`) — a list of per-mount groups `{mount, title, root_rel, tree}`, one group per ENABLED, non-degraded mount (Task A-T11; replaces Phase 1/2's single flat folder/page tree of `{workspace}/icm`); `icm_page` → `:page` (`icmPage`, arg `path`).
  - `Valea.Api.Mounts`: `list_mounts` → `:list_mounts` (`listMounts`) — every discovered mount (enabled/disabled/degraded, embedded ∪ external), typed `name`/`title`/`description`/`relRoot`/`root`/`enabled`/`degraded` (`relRoot` nullable — `nil` for an external mount; `root` always the absolute path); `set_mount_enabled` → `:set_mount_enabled` (`setMountEnabled`, args `name, enabled, generation`); `create_mount` → `:create_mount` (`createMount`, args `name, description, generation`, returns `relRoot`); `declare_mount` → `:declare_mount` (`declareMount`, args `name, ref, generation`) — validates `ref` via `Valea.Mounts.External.validate_ref/2` and writes a `kind: "path"` config entry; `undeclare_mount` → `:undeclare_mount` (`undeclareMount`, args `name, generation`) — config-only removal, never touches the folder; `mounts_doctor` → `:mounts_doctor` (`mountsDoctor`, arg `generation`) — per-mount health checks. See [ICM mounts (Plan A)](#icm-mounts-plan-a) below, including its "By-reference (external) mounts (Plan A2)" subsection.
  - `Valea.Api.Cockpit`: `cockpit_today` → `:today` (`cockpitToday`) — the seeded §17 narrative.
- **Transport: Phoenix channels first, HTTP fallback.** One socket (`ValeaWeb.UserSocket`, path `/socket`) carries two independent channel topics: `ash_typescript_rpc:client` (ash_typescript's channel-RPC transport — every `icmTree()`-style call goes here when the channel is joined) and the single consolidated **`workspace:events`** channel, joined once from `frontend/src/routes/+layout.svelte` via `wireIcmEvents()` (`frontend/src/lib/stores/icm.svelte.ts`) and pushing two event names: `workspace` (`{open, name?, path?}`, on open/close) and `icm_changed` (`{}`, on any change under `{workspace}/icm`, debounced 200ms by `Valea.ICM.Watcher`). There is no per-feature channel sprawl — `workspace:events` is the one realtime channel, and non-realtime RPC prefers `ash_typescript_rpc:client` but transparently falls back to plain `POST /rpc/run` (`ValeaWeb.RpcController.run/2`) when the socket/channel isn't joined (see `frontend/src/lib/api/client.ts`).
- Plain controllers only where RPC doesn't fit — e.g. `GET /api/health` (`ValeaWeb.HealthController`, returns `{"status":"ok"}`) for sidecar port polling from Tauri.
- Codegen is part of the build: `just codegen` runs `mix ash_typescript.codegen`; `just test` fails if the checked-in client is stale.
- Errors follow ash_typescript's structured error shape; the frontend maps a workspace-not-open error to the onboarding screen.
- **Unconstrained `:map` RPC actions stay snake_case on the wire.** `Workspace`, `ICM`, and `Cockpit` actions are all typed `:map` or `{:array, :map}` (no Ash embedded/typed schema) because they wrap plain Elixir data, not Ecto structs. ash_typescript's camelCase output formatter only reformats keys it can see in a typed schema — an unconstrained `:map` return is opaque to it, so the generated TS type is `Record<string, any>` and the actual keys arrive exactly as the backend wrote them: snake_case. Concrete example: `Valea.Cockpit.today/0` (`backend/lib/valea/cockpit.ex`) returns `"prepared_items" => [%{"used_sources" => [...], "primary_action" => ..., ...}]`; the wire payload from `cockpit_today` genuinely contains `used_sources`, `primary_action`, `date_label`, `open_loops`, `while_you_were_away` — not their camelCase equivalents. The same applies to `icm_tree`'s `page_count`. Frontend code that consumes these actions normalizes explicitly rather than trusting the generated type: see `normalizeCockpitToday`/`pick()` in `frontend/src/lib/today/cockpit.ts` (checks the snake_case key first, camelCase second, and maps to a typed camelCase `CockpitToday`/`PreparedItem { usedSources, primaryAction, ... }` shape) and `normalizeIcmNode` in `frontend/src/lib/stores/icm.svelte.ts` (same pattern for `page_count`/`pageCount`). Any new `:map`-typed RPC action needs the same explicit normalization at the call site — do not trust the generated `Record<string, any>` type to already be camelCase.

## ICM editor (Phase 2)

- **Markdown ↔ ProseMirror converter** (`backend/lib/valea/markdown/prose_mirror.ex`, `.../profile.ex`): vendored from `magus/lib/magus/markdown/prose_mirror.ex` (header comment records the origin + Valea's divergences — positional `profile` arg, `to_markdown/2` returns `{:ok, md}`, blockquote serializer drops the trailing space on blank quote lines). MDEx-based, pure/IO-free. `Valea.Markdown.Profile` is the Valea profile: every callback (`post_process/1`, `node_to_markdown/1`, `inline_node_to_markdown/1`) is the identity/default — no custom node lifting, standard CommonMark + GFM only (the paper's "plain text as interface" principle; no callouts/wikilinks/tags/`magus://` links/image blocks). **Determinism contract** (`backend/test/valea/markdown/determinism_test.exs`): every seed ICM page under `backend/priv/workspace_template/mounts/starter/**/*.md` (17 pages today, excluding the mount's own `AGENTS.md`/`CLAUDE.md` and `prompts/*.md`; the test guards `>= 12` against a silent wildcard miss) round-trips `markdown → PM JSON → markdown` byte-identically, and a second pass is a fixed point — enforced by test, not just convention; the editor never sees markdown, only tiptap's ProseMirror JSON, converted at the backend boundary.
- **`Valea.ICM` write operations** (`backend/lib/valea/icm.ex`): `save_page(rel_path, pm_map, base_hash)` — SHA-256-hex hash guard (`sha256_hex/1` of the current file bytes must equal `base_hash` or the call returns `{:error, :page_changed}`, magus-style optimistic concurrency adapted to files, no lock files, no mtime), then `ProseMirror.to_markdown/1` and an atomic write; `create_page/2` / `create_folder/2` (shared `normalize_name/1` — NFC-normalize, trim, reject empty/`/`/`\`/leading `.`, `.md` auto-appended for pages; parent-must-be-a-directory guard); `rename/2` and `delete/1` work for both pages and folders (folder rename collects every nested `.md` first, then rewrites references for each). All writes share one `atomic_write/2` helper (tmp file + `File.rename!` in the same directory) and pass through the existing containment chokepoint (`contain/2`). `page/1` (existing read) now also returns `hash` (SHA-256 hex of the bytes at read time) and `prosemirror` (converted JSON) — a conversion failure is loud (`{:error, {:conversion_failed, msg}}`), never a silently-degraded page.
- **`Valea.ICM.References`** (`backend/lib/valea/icm/references.ex`): plain-string scan, scoped to a single mount, of that mount's own `Workflows/*.md` pages for a literal ICM-relative needle (mount-relative — e.g. `Offers/X.md`, never prefixed with the mount's own name — no YAML parsing needed; the paths are load-bearing `sources:` entries in Layer-2 stage contracts per the ICM paper). `referencing_workflows/1` and `rewrite/2` both take a workspace-relative `mounts/<name>/<inner>` path, resolve the owning mount via `Valea.Mounts.mount_for/1`, and scan/rewrite only THAT mount's own `Workflows/*.md` — a same-named page in a different mount is never matched (mount isolation is by directory, not by the needle string). `referencing_workflows/1` returns `[%{file:, name:}]` (`name:` via `~r/^name:\s*(.+)$/m`, falls back to the filename); `rewrite/2` string-replaces the old needle with the new one in every referencing file, atomically, and reports which files it touched — `Valea.ICM.rename/2` calls this after a successful move and returns `updated_workflows` (the human-readable names) to the caller; if a rewrite fails partway, the error is reported truthfully as `{:rewrite_failed, file, reason}` rather than claimed as success (no rename rollback — a known, documented gap, same posture as the workspace-scaffold rollback gap above). `delete/1` deliberately does NOT touch workflows; `icm_entry_references/1` lets the UI warn before a destructive delete.
- **RPC — first constrained/typed returns**: `save_icm_page`, `create_icm_page`, `create_icm_folder`, `rename_icm_entry`, `delete_icm_entry`, `icm_entry_references` (all on `Valea.Api.ICM`) are the first RPC actions in the app to declare `constraints fields: [...]` on their `:map` return, so ash_typescript emits real typed TS interfaces instead of `Record<string, any>` — e.g. generated `SaveIcmPageFields = UnifiedFieldSelection<{hash: string, savedAt: string, ...}>[]`, not the Phase-1 `Record<string, any>` shape described above. This begins retiring that caveat for new surface without retro-typing `icm_tree`/`icm_page`/`cockpit_today` (out of scope). `Valea.Api.ICM.error_for/1` centralizes error mapping for every action on the resource: `:no_workspace` → `"workspace_not_open"`, other atoms → `to_string/1`, anything else (tuple reasons like `{:conversion_failed, msg}` or `{:rewrite_failed, file, reason}`) → `inspect/1` (never `to_string/1` on a tuple — it raises). Root-level creates use `argument :parent_path, :string, constraints: [allow_empty?: true]` so `create_icm_page("", "Name")` is valid. The existing `:page` action stays unconstrained (Phase-1, not retro-typed) but its map now carries the two new fields (`hash`, `prosemirror`) alongside the old ones.
- **Editor component family** (`frontend/src/lib/components/editor/`): `PageEditor.svelte` — tiptap 2.27.x on Svelte 5 (magus lifecycle pattern: editor built in `$effect` + `untrack`, destroyed in cleanup + `onDestroy`, exported `getJSON/setContent/focus/isEmpty`). Extensions: StarterKit, Placeholder, Link, Typography, TaskList/TaskItem, Table family, plus three framework-agnostic extensions vendored from `tiptap_phoenix` into `frontend/src/lib/editor/vendor/` (`slash_command.js`, `bubble_menu.js`, `drag_handle.js` — each with an origin header, `pushEvent`/LiveView plumbing stripped) and its `tiptap.css` (every `--ttp-*` variable re-mapped onto Paper & ink tokens, no DaisyUI vars live). `PageMeta.svelte` renders the save-status + context-cost meta line; `ConflictBanner.svelte` renders the amber suggestion-card conflict UI. `frontend/src/lib/stores/page-editor.svelte.ts` (`PageEditorStore`, one instance per open page, no singleton) is the save-loop state machine: states `clean | dirty | saving | conflict`; `noteChange` arms a 1000ms debounce, redirties (rather than losing an edit) if a change lands while a save is already in flight; `flush()` awaits an immediate save (called on route-leave and before the raw-view toggle); `externalChange(hash)` — driven by the route re-checking `icm_page`'s hash whenever the watcher's `icm_changed` fires — silently reloads while `clean`, or raises `conflict` while `dirty`/`saving`, with own-echo detection (a save's own resulting hash is not mistaken for a foreign conflict); `resolveReload()` discards local edits for disk truth, `resolveKeepMine()` refetches the hash and resaves the local JSON on top (last-write-wins recovery). `frontend/src/lib/api/client.ts` is still the sole `ash_rpc` importer, wrapping the six new generated calls (`saveIcmPage`, `createIcmPage`, `createIcmFolder`, `renameIcmEntry`, `deleteIcmEntry`, `icmEntryReferences`) in the same `{ok,data}|{ok:false,error}` envelope as Phase 1. Tree CRUD UI (`frontend/src/lib/components/knowledge/`: `NewEntryDialog`, `RenameDialog`, `DeleteDialog`, `EntryMenu`) shows the reference impact before a rename/delete confirms (`icmEntryReferences`) and never does optimistic tree surgery — the existing watcher → `icm_changed` pipeline is what refreshes the nav tree and list pane after every write.

## Agent slice (Phase 3)

The full AI-prepares-human-approves loop: real ACP agent sessions running in
the workspace, a chat UI, workflow execution on the seeded mock email, a
hardened approval queue, and an audit log. No external integrations (mail/
calendar are Phase 4/5); zero custom tools or MCP servers — the workspace
file tree is the agent's entire API (VISION.md principle 5).

### Trust model

The Claude adapter and the Claude Code runtime are **trusted infrastructure**
running as the user with the user's own credentials — Valea does not claim
OS-level sandboxing this phase (recorded hardening option for later). What it
provides is defense-in-depth for an honest-but-fallible agent, in layers: (1)
a managed `.claude/settings.json` routes risky operations to Valea's ACP
permission callback instead of silent auto-approval; (2) `PermissionPolicy`
decides allow/deny/ask with hard-deny precedence and audits every decision;
(3) the server owns all run identity and execution — the agent only
*proposes*, writing one JSON payload to an exact path it's told; everything
else (validation, the queue envelope, the draft file) is backend-authored;
(4) `logs/audit.jsonl` + per-session transcript files make every action
reconstructable.

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
`session/v1` metadata record (id, `acp_session_id`, kind, workflow, harness,
generation, `started_at`); the file is canonical, so a backend crash loses
nothing and a restart replays sessions read-only straight from disk
(`Valea.Agents.attach_or_replay/1`: live Registry hit, else fold the file).
Broadcasts go out on PubSub topic `agent_session:<id>`, generation-stamped.
Prompts are one-turn-at-a-time; a user's own prompt is echoed into the
timeline only once actually sent (the adapter doesn't echo it back on a
fresh session).

The harness seam is `Valea.Harness` (a 2-callback behaviour: `definition/0`
+ `acp_command/1`) with `Valea.Harnesses.ClaudeCode` as the only
implementation. The executable is resolved from **trusted app config**
(`Valea.App.Config`), never from a workspace file — the template's
`harnesses.yaml` was removed by design, so an opened folder can never make
Valea execute an arbitrary binary. `Valea.Agents.Env` passes the subprocess
a minimal allowlisted environment (`HOME`, `PATH`, `USER`, `LANG`/`LC_*`,
`TMPDIR`, `SHELL`, Claude/Anthropic auth vars when present) — never the
backend's own environment, so secrets like `SECRET_KEY_BASE` cannot leak
into the agent process. `Valea.Agents.Doctor` probes Node 22+, the adapter
binary (`--version`), and auth (`claude-agent-acp --cli auth status`),
returning ok/failed/unknown per check with a copyable remedy — probes run
through the same erlexec group-kill so a hung adapter can't leave orphans
during a doctor check.

### Permission model

`Valea.Agents.ClaudeSettings` writes and owns `.claude/settings.json`
(regenerated at every session start and on migration, `.gitignore`d):
`deny` covers `secrets/**`, `logs/**`, `.claude/**`, `.git/**`, the SQLite
files (`app.sqlite*`), plus `WebFetch`/`WebSearch` (no network at the
harness layer either); `ask` covers `Write`, `Edit`, `Bash`; `allow` covers
`Read`. This is what makes Valea's ACP permission callback *reachable* —
Claude Code auto-approves reads and its own allowed rules before the
callback ever fires, so writes/Bash are forced to `ask`.

`Valea.Agents.PermissionPolicy.decide/2` is the deciding layer: pure,
precedence **deny → allow → ask**, unclassifiable is always `ask`. Deny is
hard: any resolved path under a protected dir (`secrets`, `logs`, `.claude`,
`.git`) or matching the `app.sqlite*` prefix, or any path that resolves
*outside* the workspace at all. Read-kind calls are allowed only when every
path falls inside the declared reference roots (`sources`, the root
`AGENTS.md`/`CLAUDE.md` files, and each ENABLED mount's own `mounts/<name>`
root — recomputed fresh at every session start via
`Valea.Agents.SessionServer`'s `read_roots/1`,
`["sources" | Enum.map(Mounts.enabled(ws), & &1.rel_root)]`, so
enabling/disabling a mount takes effect on the very next session without a
restart; a disabled/absent mount is simply not in the list, falling through
to `ask` rather than a hard deny — see [ICM mounts (Plan
A)](#icm-mounts-plan-a) below) — never a blanket workspace-root allow. Write-kind calls are
allowed only for workflow-kind sessions, and only when every path exactly
matches the run's declared write paths (the one staging file its run
named) — **chat sessions have no automatic write root; every chat write
asks.** Every decision (allow, deny, and ask alike) is audited
(`permission_auto_allowed` / `permission_auto_denied` / `permission_asked` /
`permission_answered`); an `:allow` always selects the `allow_once` option,
never "always allow".

All path reasoning goes through `Valea.Paths.resolve_real/2` — symlink-aware
containment with real OS realpath semantics (symlinks resolved before a
following `..` is applied, `..` pops to the *physical* parent, 32-hop
bound), shared with the ICM containment chokepoint. This closes both the
`/var` vs `/private/var` (macOS) case and deliberate symlink-escape attempts
inside the workspace; a path resolving anywhere outside the workspace root
is a hard deny, not merely an `ask`.

### Queue / approval / audit flow

The agent writes only a `proposal/v1` payload (`schema`, `kind`, `title`,
`summary`, `sources`, `proposed_action` — MVP vocabulary
`create_email_draft` only — `reasoning`) to the exact staging path its run
names: `Valea.Workflows.Runner.run/2` generates a server-owned `run_id`
(`yyyymmddThhmmssZ-xxxxxx`), the staging dir `queue/staging/<run_id>/`, and
sha256 hashes of the workflow page and input file **before the agent ever
runs** — the session's opening prompt names the workflow contract, the
input, and `queue/staging/<run_id>/proposal.json` as the only path it may
write. On turn end `Runner.finalize/2` looks only at that exact path: valid
→ the canonical envelope `queue_item/v1` (`schema`, `run_id`, `session_id`,
`workflow`, `workflow_hash`, `input`, `input_hash`, `risk_level`,
`approval`, `created_at`, `payload`) is written atomically to
`queue/pending/<run_id>.json` and staging is cleaned; missing → "finished
without producing anything for review"; invalid → a visible-but-unreadable
state (staging left in place for inspection, raw file one toggle away). No
timestamp-window correlation — the run id is the only link.

`Valea.Queue` treats the containing directory as the state machine:
`pending → processing → approved` (approve) or `pending → rejected`
(reject), both guarded by a **revision hash** (sha256 of the exact file
bytes) so a stale approve on a changed item returns `queue_item_changed`
rather than acting on the wrong content. `approve/2`'s exact order: (1)
re-hash and compare the revision; (2) atomically claim
`pending/<id>.json → processing/<id>.json` (already moved →
`queue_item_gone`); (3) append the `approval_intent` audit record
**synchronously** (`Valea.Audit.append_sync/2`) so a crash mid-execution
always leaves a readable trail *before* anything is executed; (4) execute
idempotently — the draft path is deterministic
(`sources/mail/drafts/<run_id>.md`; an existing draft is treated as already
executed, never rewritten); (5) audit `action_executed`; (6) rename
`processing/ → approved/`; (7) audit `item_approved`. Crash recovery
(`Valea.Queue.recover/1`, run as a one-shot `Task` when the workspace
`Runtime` supervisor starts) resolves anything left in `processing/`: draft
exists → complete it into `approved/`; draft absent → hand back to
`pending/` — audited either way (`approval_recovered`).

`Valea.Audit` is a single GenServer serializing append-only writes to
`logs/audit.jsonl` (`append/2` casts, `append_sync/2` calls but still never
raises to the caller — audit write failures are logged loudly server-side
but never block the underlying file-move action, which remains the source
of truth). Every entry carries `ts`, `type`, and the workspace `generation`.
Entry types across the slice: `workflow_run_started`/`workflow_run_finished`
(outcome `no_proposal`/`invalid_proposal`/`proposal_created`/
`start_failed`), `queue_item_created`, `permission_auto_allowed`/
`permission_auto_denied`/`permission_asked`/`permission_answered`,
`approval_intent`, `item_approved`/`item_rejected`, `action_executed`,
`approval_recovered`, `session_exited`.

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

### Workspace runtime supervisor, generations, migration

All workspace-bound processes now live under one `Valea.Workspace.Runtime`
supervisor (`:one_for_one`): the ICM/queue watcher, `Valea.Audit`, a one-shot
queue-recovery `Task`, and `Valea.Agents.SessionSupervisor` (a
`DynamicSupervisor` — every live agent session is its child, so it dies with
the workspace). `Valea.Workspace.Manager` stamps a monotonic **generation**
integer on every successful open; every runtime process and broadcast
carries it, and every mutating RPC (`approve_item`, `create_session`,
`run_workflow`, `save_icm_page`, …) checks it via
`Manager.check_generation/1` — a stale generation returns `workspace_changed`
instead of silently acting on the wrong workspace. A workspace switch
(`do_close/1` then `do_open/2`) fully terminates the old `Runtime` and every
child **before** the new one starts, so no process of the old workspace can
touch the new one; any failure partway through open rolls back every pid
already started.

The workspace gains a version marker (`config/workspace.yaml`, `version: 2`;
missing file/key = version 1, forcing migration). `Valea.Workspace.Migration`
is additive-only and idempotent: creates `AGENTS.md`/`CLAUDE.md` from the
template if missing (never overwrites), converts legacy root
`workflows/*.yaml` into `icm/Workflows/<name>.md` pages (skips existing
targets; the generated body is round-tripped through the markdown↔ProseMirror
converter so a later untouched re-save stays byte-identical), creates
`queue/staging/` and `queue/processing/`, appends `.claude/` to
`.gitignore`, and (re)writes the managed `.claude/settings.json` on *every*
open, not just on a version bump. `Valea.Workspace.Scaffold`'s marker-dir
list drops the root `workflows/` requirement and writes `ClaudeSettings` at
create time, so managed settings exist from the moment a workspace is
scaffolded.

The version marker has since advanced twice more,
`Valea.Workspace.Migration.migrate/1` chaining `ensure_v2 → ensure_v3 →
ensure_v4` and writing the marker last at every step (a crash mid-migration
always leaves the workspace one version behind, so the whole step re-runs
cleanly next open): v2→v3 (Mail phase — seeds `sources/mail/messages/`,
migrates `config/mail.yaml` and the triage workflow page) and v3→v4 (ICM
mounts — the legacy `icm/` tree becomes a real mount at `mounts/<slug>/`;
see [ICM mounts (Plan A)](#icm-mounts-plan-a) below for the v4 step in
full).

## Mail (Phase 4)

A sync-to-files engine that connects Valea to the user's real IMAP mailbox,
lands the messages they hand over (by moving them into `AI/Review` in their
own mail client) as plain files under `sources/mail/`, and closes the
approval loop back into the mailbox — replacing Phase 3's seeded mock input
while keeping the agent's integration surface exactly what it already was:
files. No IMAP IDLE, no OAuth, no multi-account (spec non-goals); no SMTP
send anywhere (see Safety invariants below).

### Module map (`backend/lib/valea/mail/`)

- **`Valea.Mail.Engine`** — one GenServer per workspace (started under
  `Valea.Workspace.Runtime`), owns `Settings` + the RAM-only credential +
  sync status + poll timer. Inert (`active: false`, no file reads) until the
  `{:workspace_opened, info, generation}` broadcast for its own generation;
  a pass runs in a monitored `Task` (single-flight via `state.sync_task`),
  triggered only by the poll timer or `sync_now/0`. `auth_failed` pauses
  polling until `set_credential/1` supplies a new secret. Also single-flights
  post-approval mailbox ops *per `run_id`* (`state.ops_tasks`).
- **`Valea.Mail.SyncPass`** — one pass: connect, sync the Review folder
  (per-UID outcome tracking so a failed message retries, an oversized one
  doesn't re-fetch), sync INBOX headers (awareness index only), logout.
  `UIDVALIDITY` change wipes that folder's watermark + outcomes and forces a
  clean re-fetch; landed files/index rows survive (Message-ID dedupe
  re-attaches them).
- **`Valea.Mail.Transport`** (behaviour) / **`Valea.Mail.ImapClient`** (real
  `:ssl` implementation) — UIDs only, `BODY.PEEK[...]` (never sets `\Seen`),
  connect-per-pass (no persistent connections, no IDLE). `uid_move/3` is the
  safe-move ladder: `UID MOVE` → `UID COPY` + `STORE +FLAGS (\Deleted)` +
  targeted `UID EXPUNGE <uid>` (RFC 4315 UIDPLUS) → `{:unsupported, _}`; a
  bare `EXPUNGE` never appears anywhere in the module.
- **`Valea.Mail.Normalizer`** / **`Valea.Mail.Message`** — raw RFC822 →
  normalized struct (`message_id`, `from`, `subject`, `date`, threading
  fields `in_reply_to`/`references`/`reply_to`, `body_text`, `attachments`);
  raw bytes are discarded after normalization.
- **`Valea.Mail.MessageFile`** — the normalized-message-file format:
  `msg_id/2` (deterministic `<date>-<from-slug>-<hash8>`; on a genuine hash
  collision `SyncPass.msg_id_for_path/3` extends the hash to 16/64 hex),
  `render/2`, `parse/1`, `flip_status/2`
  (byte-preserving, never re-serializes the rest of the file), injection-
  hardened frontmatter (`yaml_string/1`: UTF-8 scrub, C0/DEL → space, `\`/`"`
  escaped — a mail header can never break the frontmatter block).
- **`Valea.Mail.DraftMime`** — composes the RFC822 bytes for an approved
  reply: `To`/`In-Reply-To`/`References` come from the *source* message's
  frontmatter (a reply threads onto what it answers), `Subject`/body from
  the approved draft. Deterministic `Message-ID:
  <valea.draft.<run_id>@valea.invalid>` (RFC 6761 `.invalid`) — the
  idempotence guard `MailboxOps` searches on before ever appending.
- **`Valea.Mail.MailboxOps`** — executes the two post-approval ops
  (`draft_append`, `archive_source`) for a decided queue item; see the
  lifecycle below. Never blocks an approval: a connect failure marks
  actionable ops `"failed"` and returns, the human's decision stays
  untouched. Independent ops — one failing never stops the other.
- **`Valea.Mail.Settings`** — `config/mail.yaml` v3 ⇄ `%Settings{}`
  (`account`, `imap.{host,port,username}`, `folders.{review,processed,drafts}`,
  `sync.{interval_minutes,max_message_bytes,inbox_index_limit}`, the fixed
  `safety:` block). No credential ever lives in this file. `load/1`
  distinguishes `:not_configured` (missing file, blank/placeholder host) from
  `{:invalid, reason}` (structurally broken).
- **`Valea.Mail.Doctor`** — the connection preflight; see Doctor checks
  below. `create_folders/1` is the doctor panel's "Create AI folders" action
  (creates missing `AI/Review`/`AI/Processed` only — never touches Drafts).
- **`Valea.Mail.Index`** — rebuilds the `mail_messages` cache from
  `sources/mail/messages/*.md` (an unparseable file is skipped/logged, never
  fatal); runs on every Engine activation.
- **`Valea.Mail.Store`** (`Ash.Domain`, no `AshTypescript` extension —
  internal-only) over four minimal `AshSqlite.DataLayer` resources
  (`Store.SyncState`, `Store.UidOutcome`, `Store.MessageIndex`,
  `Store.InboxHeader`; tables `mail_sync_state`/`mail_uid_outcomes`/
  `mail_messages`/`mail_inbox_headers`). All four are pure cache — every
  table is rebuildable from `sources/mail/` (+ an IMAP resync), so they are
  **hand-migrated** (`backend/priv/repo/migrations/20260711000001_create_mail_tables.exs`)
  rather than codegen'd: each resource's `sqlite do` block sets
  `migrate? false`, which excludes it from `AshSqlite.MigrationGenerator`'s
  snapshot diff — the same diff `AshPhoenix.Plug.CheckCodegenStatus` reruns
  on every dev request. Without that flag dev boot 500s with
  `Ash.Error.Framework.PendingCodegen` on the first request (no committed
  resource snapshots exist for these four resources by design), and running
  codegen would emit a second, redundant migration racing the hand-written
  one against an already-migrated table.
- **`Valea.Api.Mail`** — the RPC surface; see RPC + channel events below.
- **Frontend**: `frontend/src/lib/stores/mail.svelte.ts` (`MailStore`,
  `resupplyCredential`, `normalizeMailStatus`), components under
  `frontend/src/lib/components/mail/` (`SetupPanel`, `MailDoctorPanel`,
  `MessageList`, `MessageView`, `InboxSection`, `SyncStatusLine`), route
  `frontend/src/routes/mail/+page.svelte`.
- **Desktop**: `desktop/src-tauri/src/keychain.rs` — three Tauri commands
  (`mail_secret_set/get/delete`) over the OS keychain (`keyring` crate),
  gated by `desktop/src-tauri/capabilities/mail-keychain.json`.

### `sources/mail/` layout

```
sources/mail/
  messages/<msg_id>.md      # landed Review-folder messages (canonical; Store is cache)
  attachments/<msg_id>/     # landed attachment files, deduped filenames
  drafts/<run_id>.md        # human-approved reply draft, pre-append
  inbox.md                  # regenerated every pass — INBOX awareness table, do not edit
```

`config/mail.yaml` (v3) lives outside `sources/`, alongside the other
workspace config; the credential never lives in either.

### `queue_item/v2` + mailbox_ops lifecycle

Phase 3's queue (`Valea.Queue`) gained a schema bump on the decide path. On
`approve/2`/`reject/2`, the already-claimed `processing/` file is atomically
rewritten from `queue_item/v1` to `queue_item/v2` — adding a `mailbox_ops`
map — before the final rename into `approved/`/`rejected/`:

- `approve/2` on an `email_draft` payload stamps `{"draft_append" =>
  %{"status" => status}, "archive_source" => %{"status" => status}}`;
  `reject/2` stamps only `{"archive_source" => %{"status" => status}}`.
- That seeded `status` (shared by all named ops) is `"skipped"` when the
  source message's leading frontmatter says `source: seed` (or is
  absent/unreadable) — Phase 3's mock data leaves nothing to append/move —
  otherwise `"pending"`.
- Landing `approved/`/`rejected/` broadcasts `{:mailbox_ops_pending, run_id}`
  on the `"mail_ops"` PubSub topic; `Valea.Mail.Engine` picks it up and runs
  `MailboxOps.execute/1` in an unlinked, per-`run_id` single-flight task.
  Activation also re-sweeps any item still `"pending"` (a missed broadcast);
  `"failed"` ops wait for the user's explicit retry
  (`Engine.retry_ops/1` → `retry_mailbox_ops` RPC), never auto-retried.
- Each op resolves independently to `"done"` (append/move succeeded, or the
  draft was already present — the idempotence guard), `"unsupported"` (no
  MOVE/UIDPLUS — the *local* file still flips to `processed`, since the human
  review already happened regardless of server capability), or `"failed"`
  (retryable). `Queue.update_mailbox_op/3` records the outcome and
  broadcasts `{:mailbox_ops_updated, run_id}`.
- `Valea.Queue.recover/1` (crash recovery) includes the v2 upgrade: a
  recovered approval never lands without its `mailbox_ops` map.

### Credential path

The credential is **never written to disk, never logged, never part of the
workspace** — held only as a zero-arity closure in `Engine` process state
(so `:sys.get_state/1`/a crash dump never renders it).

```
OS keychain (desktop only)          RPC (control plane)              Engine
"digital.wirdrei.valea" service  →  set_mail_credential(secret,   →  set_credential/1
account "<workspace_id>:<username>"  generation)                     (RAM closure only)
```

- **Setup**: `setup_mail_account` RPC writes `config/mail.yaml` (no
  credential) and calls `Engine.reload_settings/0`. The frontend then writes
  the secret to the OS keychain via `mail_secret_set` (Tauri command,
  desktop only) — never through the RPC surface.
- **Resupply** (every mail-store init / workspace open): the frontend's
  `resupplyCredential` reads `mail_secret_get(workspace_id, username)` —
  keyed on `status.username` (the IMAP login), **not** `status.account` (the
  display label) — and, if present, calls `setMailCredential`. Self-
  terminating: a successful resupply flips the Engine's `credential` field
  to `"present"`, so it only runs while actually needed.
- **Browser-mode / dev fallback**: no keychain in a plain browser tab (no
  Tauri), so `Engine` reads `VALEA_MAIL_PASSWORD` once at activation, only
  if no credential has already been supplied via RPC.
- `set_mail_credential`'s `secret` argument is `sensitive? true`; nothing on
  the request path logs action inputs regardless (no `Plug.Logger`).

### RPC + channel events

`Valea.Api.Mail` (`rpc_action(:name, :action)`, generated TS name in
parens): `mail_status` → `:mail_status` (`mailStatus`); `setup_mail_account`
(`setupMailAccount`, args `account, host, port, username, generation`);
`set_mail_credential` (`setMailCredential`, args `secret, generation`);
`mail_sync_now` (`mailSyncNow`, arg `generation`); `mail_doctor`
(`mailDoctor`, arg `generation`); `create_mail_folders`
(`createMailFolders`, arg `generation`); `list_mail_messages`
(`listMailMessages`); `get_mail_message` (`getMailMessage`, arg `msg_id`);
`mail_inbox` (`mailInbox`); `retry_mailbox_ops` (`retryMailboxOps`, args
`run_id, generation`). Every mutating action takes `generation` and guards
via `Manager.check_generation/1`; every read-only one still resolves
`Manager.current/0` first (surfaces `"workspace_not_open"` instead of a
`Repo`/`:noproc` crash).

`ValeaWeb.WorkspaceEventsChannel` (topic `workspace:events`) subscribes to
two more PubSub topics this phase, `"mail"` and `"mail_ops"`, and pushes:
`mail_status` (the full status map, string-keyed), `mail_sync`
(`{phase: "started"|"finished", newMessages}`), `mail_message` (`{path}` —
one landed/updated message), `mailbox_ops` (`{runId}` — an op's outcome
changed). `{:mailbox_ops_pending, _}` is deliberately not pushed — it is the
Engine's own internal trigger, nothing for the UI to react to until
`mailbox_ops` (the terminal signal) follows.

### Doctor checks (`Valea.Mail.Doctor.run/1`)

Sequential, each gated on the one before it (a failure marks everything
downstream `"unknown"`, not attempted): `config_present` → `credential_present`
→ `tcp_reachable` → one `transport.connect/3` call fanning out to `tls_ok` +
`login_ok` + `folders` (missing `AI/Review`/`AI/Processed`/Drafts) +
`move_capability` (MOVE vs. UIDPLUS vs. neither) → `workflow_contract`
(gated on `config_present` alone — a local file check: discovers the seeded
New Inquiry Triage workflow via `Valea.Workflows.triage_path/1` (Task
A-T13 — the first enabled mount, by the registry's own sort order, with a
`Workflows/New Inquiry Triage.md`; no more hardcoded
`icm/Workflows/New Inquiry Triage.md` path) and warns if it still
references the legacy JSON input instead of `sources/mail/messages/*.md`).
Never raises; every check
carries a copyable remedy string. The credential is resolved once at the
`connect/3` boundary and scrubbed out of any error text that would
otherwise embed it.

### Safety invariants

- **TLS is mandatory and verified, always.** `ImapClient.connect/3` always
  passes `verify: :verify_peer` + hostname verification + SNI; the only
  caller-overridable piece is which trust root is used
  (`opts[:tls_opts]`, e.g. `cacertfile:` — tests only, never production
  code). There is no insecure escape hatch (no `VALEA_MAIL_TLS_INSECURE`
  or equivalent) anywhere in the client.
- **Safe-move ladder, never a bare `EXPUNGE`.** See `ImapClient.uid_move/3`
  above — a bare `EXPUNGE` would purge every `\Deleted` message in the
  mailbox, including ones the user's own client marked; it never appears in
  the codebase outside the one targeted `UID EXPUNGE <uid>` call.
  `BODY.PEEK[...]` is used for every fetch, so reading a message here never
  flips `\Seen`.
- **Never-send.** `config/mail.yaml`'s `safety:` block is a fixed,
  non-configurable invariant (`send_directly: false`,
  `create_drafts_only: true`) and `Valea.Mail.Transport` has no send/SMTP
  callback at all — the only mailbox-writing operations anywhere in the
  phase are `append` (Drafts folder only, via `DraftMime`) and `uid_move`
  (Review → Processed). An approved reply always lands as a draft for the
  human to review and send themselves.

## ICM mounts (Plan A)

*(shipped on `feat/icm-mounts`, pending merge; roadmap Phase 7 — "all mounts". By-reference/external mounts — originally deferred to a follow-on plan — landed on this same branch as Plan A2; see "By-reference (external) mounts (Plan A2)" at the end of this section.)*

The single hardcoded `icm/` tree Phases 1–4 relied on is now `mounts/<name>/`
— one or more self-contained ICM modules per workspace, each independently
enabled/disabled. Workspace version 4 (`config/workspace.yaml`); a fresh
scaffold ships one seeded mount, `mounts/starter/`.

**Layer mapping, restated for mounts:** the workspace *shell* — root
`AGENTS.md`/`CLAUDE.md`, `queue/`, `sources/`, `logs/` — still carries Layers
0/1 (root instructions + routing) and Layer 4 (working artifacts); Layer 1
routing no longer names a single `icm/` tree, it names `@MOUNTS.md` (below),
which fans out into every enabled mount. Each mount under `mounts/<name>/`
is now its OWN self-contained Layers 2/3: `Workflows/*.md` is that mount's
Layer 2 (stage contracts whose `sources:` frontmatter is ICM-relative to
THAT mount's own root — never prefixed with the mount's name), and
everything else under the mount root is its Layer 3 (stable reference,
read-only to the agent). A mount also carries its own `AGENTS.md`/
`CLAUDE.md` (`CLAUDE.md` is `@AGENTS.md`, same convention as the workspace
root) — a mount-scoped Layer 0/1 describing only that module's own content
(see `mounts/starter/AGENTS.md`'s "The map" section, or the skeleton
`Valea.Mounts.create/3` mints for a brand-new mount).

| Paper layer | Valea location | Notes |
| --- | --- | --- |
| Layer 0/1 (root instructions + routing) | workspace root `AGENTS.md`/`CLAUDE.md` | Routes via `@MOUNTS.md`, not directly into a single `icm/` tree |
| Layer 0/1, per mount | `mounts/<name>/AGENTS.md`/`CLAUDE.md` | Mount-scoped self-description; minted by `Scaffold`/`Mounts.create/3`/`Migration` |
| Layer 2 (stage contracts), per mount | `mounts/<name>/Workflows/*.md` | `Valea.Workflows.list/0,1` unions across every ENABLED mount, each entry carrying a `mount` provenance field |
| Layer 3 (stable reference), per mount | `mounts/<name>/` (everything else) | Read-only to the agent; only the pages a job's Inputs name are meant to be read |
| Layer 4 (working artifacts) | `queue/`, `sources/` | Unchanged — workspace-shell level, not per-mount |
| — (not an ICM layer) | `logs/` | Unchanged |

### Discovery & relationship state

Two independent sources of truth compose in `Valea.Mounts`
(`backend/lib/valea/mounts.ex`):

- **Filesystem = identity.** `mounts/<name>/icm.yaml`'s mere presence marks
  a directory as a mount; the directory basename IS the mount's `name`.
  `Valea.Mounts.Manifest` (`backend/lib/valea/mounts/manifest.ex`) is the
  `icm.yaml` ⇄ `%Manifest{format, id, name, description}` codec — `format`
  defaults to `1`, unknown keys are ignored (a stray hand-edited key never
  bricks loading a mount), and `id` is provenance, not identity (minted once,
  travels with a copy/rename, never enforced unique). `Manifest.load/1`
  returns `{:error, :missing}` (no `icm.yaml`) or `{:error, {:invalid,
  reason}}` (not a YAML mapping, or `name` absent/blank/non-string); either
  way the mount is **degraded** — still discovered and listed (so the UI can
  show something is wrong), but always excluded from `Mounts.enabled/0,1`
  regardless of its config `enabled` flag. A directory basename carrying a C0
  control character or DEL is ALSO always degraded, independent of its
  `icm.yaml` — `Valea.Mounts.MountsMd` interpolates `rel_root` RAW into a
  live `@`-import line, so a corrupted basename must never reach that
  renderer un-quarantined.
- **`config/workspace.yaml`'s `mounts:` section = relationship state only.**
  A purely relational, mutable overlay (`mounts.<name>.enabled`, absent =
  enabled by default) that never touches the mount's own files.
  `Mounts.set_enabled/2` writes it atomically, preserving `version`, `id`,
  and every other key on every mount entry — including hand-added keys and
  the `kind`/`ref` fields (by-reference mounts, Plan A2 — see the
  By-reference section below) — so nothing but the `enabled` flag it's
  asked to change is ever touched.
- `Mounts.list/0,1` (glob `mounts/*`, sorted by name) and `Mounts.enabled/0,1`
  (filtered to `enabled: true, degraded: nil` — the effective composition
  set every consumer below composes over) are the two entry points.
  `Mounts.mount_for/1,2` resolves the mount a workspace-relative path NAMES
  by its leading `mounts/<name>` segment — **attribution only, not
  authorization**: every caller (`Valea.ICM`, `Valea.Workflows`,
  `Valea.ICM.References`) re-expands and re-contains the path against that
  mount's own root afterward, so a `..` can never escape — including one
  that tries to cross from one mount into another.
- `Mounts.create/3` scaffolds a brand-new, empty mount at
  `mounts/<Scaffold.slugify(name)>` — a fresh uuid manifest plus a minimal
  self-describing `AGENTS.md`/`CLAUDE.md` skeleton. It does not touch
  `config/workspace.yaml` (freshly created = enabled by the absent-means-true
  default) or regenerate `MOUNTS.md` itself — callers (the `create_mount` RPC)
  do both.

### `MOUNTS.md` generated routing

`Valea.Mounts.MountsMd.regenerate/1` (`backend/lib/valea/mounts/mounts_md.ex`)
reads the full mount set fresh every call and overwrites
`<workspace>/MOUNTS.md` atomically — never hand-edited. Three sections
mirror `Mounts`' own enabled/disabled/degraded split: **enabled** mounts get
a `### <name>` block (description, `path:`, and a live
`@mounts/<name>/AGENTS.md` import line — the same `@`-prefixed convention
the workspace root `AGENTS.md` already uses); **deactivated** mounts are
listed by name with no `@`-ref (so a disabled mount's instructions are never
pulled in); **degraded** mounts are listed with their reason, no `@`-ref,
rendered from `name`/`rel_root` alone (`manifest` may be `nil`). Every
metadata value (a mount's `name`/`description` — mount-supplied,
hand-editable text) is sanitized before rendering: runs of C0 control
characters collapse to a single space (a value can never span/forge a new
line), and the description — the one value that BEGINS a rendered line —
additionally backslash-escapes a leading `#`/`@` so it can't masquerade as a
heading or import directive. Every discovery-affecting caller regenerates
it: `Scaffold.create/2`, `Migration`'s v3→v4 step, the `set_mount_enabled`/
`create_mount` RPCs, and (indirectly, via those RPCs and the Watcher below)
every enable/disable/create.

**Routing chain a bare Claude Code session follows**, root to leaf: root
`CLAUDE.md` (`@AGENTS.md`) → root `AGENTS.md` (rules; its own "Mounts"
section is `@MOUNTS.md`) → `MOUNTS.md` (generated; one `@mounts/<name>/
AGENTS.md` line per enabled mount) → each mount's own `AGENTS.md` (its map
of Clients/Offers/Workflows/etc., mount-relative). No Valea-specific tooling
is required to follow it — plain `@`-import resolution, Claude Code's native
mechanism.

### Per-mount `read_roots`

`Valea.Agents.SessionServer.read_roots/1` computes, fresh at every session
start (never cached): `["sources" | Enum.map(Mounts.enabled(workspace), &
&1.rel_root)]` — feeding `Valea.Agents.PermissionPolicy.decide/2`'s
`ctx[:read_roots]` (default fallback `["sources"]` only when a caller starts
a session without computing one, e.g. a bare test call). Because it's
recomputed every session start rather than cached, enabling/disabling a
mount takes effect on the very next session without a restart. Membership
(`all_in_read_roots?/3`) matches by leading PATH COMPONENTS
(`Path.split/1`), not a lexical string prefix — `mounts/a` never wrongly
matches `mounts/ab/...`. The root `AGENTS.md`/`CLAUDE.md` files are allowed
separately (`@root_files`), outside `read_roots` proper.

### Watcher: `icm_changed` / `mounts_changed` / `queue_changed`

`Valea.ICM.Watcher` now watches two roots — `mounts/` and `queue/` — each
with its own 200ms debounce timer, so a burst in one never delays or
coalesces with the other. Any change under `mounts/` broadcasts
`{:icm_changed}` on `"icm"` (unchanged contract: consumers refetch the
grouped tree). A change to the MOUNT SET ITSELF — a top-level
`mounts/<name>` directory added/removed, or a `mounts/<name>/icm.yaml`
touch — additionally broadcasts `{:mounts_changed}` on `"mounts"`, sharing
the mounts tree's debounce window (every event is classified as it arrives,
so a manifest touch inside a content burst still gets both events, together,
exactly once). `queue/` changes broadcast `{:queue_changed}` on `"queue"`,
independently debounced. The `set_mount_enabled`/`create_mount` RPCs
(`Valea.Api.Mounts`) broadcast the IDENTICAL `{:mounts_changed}` message
themselves after writing `config/workspace.yaml` — necessary because
toggling a mount's enabled flag touches a file OUTSIDE the `mounts/` tree
the Watcher observes, so without that explicit broadcast an enable/disable
would never reach a live socket.

### Workflows registry union + References

`Valea.Workflows.list/0,1` (`backend/lib/valea/workflows.ex`) unions
`Workflows/*.md` across `Mounts.enabled/0` — one glob per mount, sorted by
the union's `path`. Each entry's `path` is workspace-relative
(`mounts/<name>/Workflows/<file>.md`) and carries a `mount` field (the
owning mount's manifest display name) for UI provenance; two mounts may each
have a same-named `Workflows/<file>.md` without shadowing. `get/1` resolves
the owning mount regardless of its enabled state (editor-style access — a
disabled mount's contract still parses by explicit path); gating what a RUN
may actually execute is `Valea.Workflows.Runner`'s concern.
`Valea.Workflows.triage_path/0,1` (Task A-T13) replaces the old hardcoded
`icm/Workflows/New Inquiry Triage.md` lookup: the FIRST enabled mount, in
`list/0,1`'s own sort order, with a `Workflows/New Inquiry Triage.md` —
consumed by `Valea.Cockpit`'s seeded narrative and `Valea.Mail.Doctor`'s
`workflow_contract` check, neither of which hardcodes a mount name anymore.

### RPC surface

`Valea.Api.Mounts` (`backend/lib/valea/api/mounts.ex`): `list_mounts` →
every discovered mount, typed `name`/`title`/`description`/`relRoot`/`root`/
`enabled`/`degraded`; `set_mount_enabled` (args `name, enabled, generation`)
→ writes config, regenerates `MOUNTS.md`, broadcasts `mounts_changed`;
`create_mount` (args `name, description, generation`) → mints a new mount,
regenerates `MOUNTS.md`, broadcasts `mounts_changed`, returns `relRoot`. Plan A2 added `declare_mount`, `undeclare_mount`, and `mounts_doctor` (see the By-reference section below). See
the RPC action list in [API layer](#api-layer) above for the generated
TypeScript names, and `icm_tree`'s changed (grouped) return shape.

**Frontend**: `frontend/src/lib/stores/mounts.svelte.ts` (`MountsStore`) —
the mount catalog (`list_mounts`), `setEnabled`/`create` wrappers, and
`handleMountsChanged` (wired via `wireMountsEvents` onto the shared
`workspace:events` join) which refetches BOTH itself and `icmStore`'s
grouped tree together, since a mount being enabled/disabled/created changes
both `list_mounts` and `icm_tree`'s grouping. Knowledge UI grouping logic
(single-mount collapse, deactivated group, degraded chips, workflow
provenance chips) lives in
`frontend/src/lib/components/knowledge/mount-sections.ts`.

### Template v4 + Scaffold + migration v4

A fresh scaffold (`Valea.Workspace.Scaffold.create/2`) mints the template's
seeded `mounts/starter/` mount a real uuid + the workspace's own display
name, renames its directory to `Scaffold.slugify(name)` (NFD-fold,
lowercase, non-alphanumeric runs collapse to `-`, trim, "mount" fallback for
a degenerate name), regenerates `MOUNTS.md` from the real minted mount, and
writes `config/workspace.yaml` as `version: 4` plus a fresh persistent
workspace uuid — so a freshly scaffolded workspace never ships a top-level
`icm/` or `prompts/` tree, only `mounts/<slug>/`.

Migration v3→v4 (`Valea.Workspace.Migration.ensure_v4/2`,
`backend/lib/valea/workspace/migration.ex`): the legacy top-level `icm/`
tree, if still present, is renamed BYTE-PRESERVING into `mounts/<slug>/`
(`Scaffold.slugify(basename(workspace))`; a name collision tries `-2`, `-3`,
... suffixes); a crash-safe re-run after the rename recognizes the SAME
already-migrated directory by its `Workflows/` subdir rather than minting a
second, empty one. Root `prompts/`, if present and the mount doesn't already
have its own, moves in unchanged. The migrated mount gets a fresh
`icm.yaml`/`AGENTS.md`/`CLAUDE.md` only where absent (never clobbers a
user-populated mount). The root `AGENTS.md` is swapped for the current
`@MOUNTS.md`-routing template ONLY if it's still byte-identical to the
pristine pre-mounts v3 seed (sha256-pinned) — a user-modified root
`AGENTS.md` is left untouched, with an audited `migration_note` that it
still routes via `icm/` rather than `@MOUNTS.md`. `MOUNTS.md` is regenerated
as the final content step; `config/workspace.yaml`'s `version: 4` marker is
written LAST, so a crash mid-migration leaves the workspace at v3 and the
whole step re-runs cleanly on the next open.

### By-reference (external) mounts (Plan A2)

*(shipped on `feat/icm-mounts`, pending merge; spec:
[2026-07-12-icm-by-reference-design.md](superpowers/specs/2026-07-12-icm-by-reference-design.md))*

An ICM can now be MOUNTED IN PLACE — referenced from wherever it already
lives on disk — instead of moved into `mounts/<name>/`. A fresh workspace
still ships one embedded `mounts/starter/` mount; a by-reference mount is
purely additive, a second (or third, ...) mount alongside it.

**Config model.** `Valea.Mounts.External` (`backend/lib/valea/mounts/external.ex`)
reads `config/workspace.yaml`'s `mounts:` section for `kind: "path"` entries
carrying a `ref:` — the external folder, absolute or `~`-based (a relative
ref is rejected/degraded outright: it would anchor to the nondeterministic
process CWD in a release). `ref` is stored EXACTLY as given (`~`-form
survives in the config — resolved fresh, never cached, at every read) so
the declaration stays portable across machines where `~` resolves
differently. `declared/1` resolves each ref the SAME way `root` becomes an
agent read root: `Path.expand/1` then `Valea.Paths.resolve_real/2`'s
self-base trick (`resolve_real(p, p)`) to fully walk symlinks — the
resolved value IS the security-relevant one. Five guardrails, checked in a
fixed order (`:home_or_root` before `:inside_workspace`/
`:ancestor_of_workspace` — `$HOME` is very often itself an ancestor of the
workspace, so checking ancestry first would mask the more specific,
more-likely fat-finger): not absolute, points at `$HOME`/`/`, inside the
workspace, an ancestor of the workspace, or contains a Claude Code
permission-glob metacharacter (`* ? [ ] { } ( )` — parens included, since
`)` is the rule delimiter in Claude Code's permission syntax and would
truncate a `Read(<root>/**)` allow entry silently). These same checks run
on BOTH paths: `validate_ref/2` (the `declare_mount` RPC's pre-write gate —
a failing candidate is rejected outright, no config write) and `declared/1`
itself (the read path — a hand-edited config can put ANY ref on disk, so a
guardrail-failing entry DEGRADES rather than being dropped: config
preserved, excluded from any effective set, recoverable if the folder
reappears or the ref is fixed).

**Merge semantics.** `Valea.Mounts.list/1` is embedded ∪ external
(`External.declared/1`), sorted by name. A name declared as both an
embedded directory and an external entry degrades BOTH entries
("name used by both an embedded and an external mount") rather than
letting one silently shadow the other. `mount_for/2`'s absolute-path
attribution matches only ENABLED, non-degraded external roots, and with
nested declared roots the most-specific (longest) root wins. External
mounts are excluded from `enabled/1` exactly like a degraded embedded
mount — the same `degraded != nil` convention, no separate vocabulary.

**Root-set containment.** `Valea.Agents.PermissionPolicy` generalizes from
a single workspace root to a ROOT SET: the workspace root ∪
`ctx[:extra_roots]` — the absolute, already-resolved roots of every
enabled external mount, computed fresh at every session start
(`SessionServer.extra_roots/1`, mirroring the existing `read_roots/1`
pattern, never cached). A path is readable iff it lands inside the
workspace root or any `extra_roots` member. The workspace deny-list
(`secrets/`, `logs/`, `.claude/`, `.git/`, the SQLite files) applies to the
WORKSPACE TREE ONLY — an external mount has no Valea-managed deny-list (a
`secrets/` folder sitting at an external mount's root is a doctor WARNING,
`secrets_hygiene` below, not a hard deny). Write containment is UNCHANGED:
`extra_roots` grants reads only, never write auto-allow. A symlink that
NOMINALLY claims a currently-enabled root but whose true resolved location
lands in NO enabled root is denied fail-closed, same as the deny-list — the
candidate's own address lied about where it points. An absolute path that
never nominally claimed any enabled root at all (not the workspace, not an
`extra_roots` member) is simply unrecognized and ASK-gates like any other
unclassifiable candidate — it does not hard-deny; that blanket
"anything outside the workspace is denied" behavior predates external
mounts and no longer holds.

**Managed settings allows.** `Valea.Agents.ClaudeSettings.content/1` adds
one absolute `Read(<resolved-root>/**)` allow entry per enabled external
mount, alongside the existing workspace-scoped `Read(./**)` — Claude Code
accepts an absolute glob alongside the relative form, and without this
entry every read under an external mount would fall through to `ask` even
though `PermissionPolicy`'s `extra_roots` already trusts it. Computed
FRESH from `Mounts.enabled/1` on every `write!/1` call (session start, the
`declare_mount`/`undeclare_mount`/`set_mount_enabled`/`create_mount` RPCs,
and the watcher's own discovery-flush regeneration below) — never cached,
so a disabled external mount's allow entry disappears the next time
settings regenerate.

**Physical paths, no alias layer.** External mount content is addressed by
its resolved ABSOLUTE path everywhere it's agent- or RPC-visible — there is
no workspace-relative alias for it. `Valea.ICM.tree/0`'s per-mount
`root_rel` is the mount's absolute root for an external mount (a
`mounts/<name>` workspace-relative string for embedded); every node `path`
beneath it is built the same way, `prefix_tree/2` joining a `mounts/<name>`
prefix or an absolute root identically. Editor ops (`save_page`,
`create_page`, `create_folder`, `rename`, `delete`) resolve the owning
mount via `Mounts.mount_for/1` (attribution only) and then re-contain the
path against THAT mount's own root via the unchanged `contain/2` chokepoint
— the same mechanism for both mount kinds, so a `..` can never escape. The
mount root itself is protected from delete/rename with no special-case
code: `mount_relative(root, root)` collapses to `""` (the same sentinel
that already means "the mount's own root"), and `contain(root, "")`
rejects it because `root` does not start with `root <> "/"`. `Valea.ICM.References`
mirrors the same mount-relative logic for its own scan/rewrite. `Valea.Workflows.list/1`
unions `Workflows/*.md` across every enabled mount, embedded or external —
an external entry's `path` is the raw absolute glob result, never
prefixed; `Valea.Workflows.Runner`'s workflow-read containment root is the
mount's own absolute `root` for an external mount, the workspace root for
embedded.

**Doctor.** `Valea.Mounts.Doctor.run/1` (`backend/lib/valea/mounts/doctor.ex`)
runs a VARIABLE-subject check list — one entry per discovered mount,
`"<check>:<mount name>"` ids to stay unique. An embedded mount gets one
check, `manifest_ok`. An external mount gets four in a single gate:
`ref_resolves` (does the ref resolve to a real folder and pass every
guardrail above?) gates `manifest_ok`, `secrets_hygiene`, and
`watcher_live` — all three report `"unknown"` when `ref_resolves` fails,
rather than probing a root that may not exist. `secrets_hygiene` is a
WARNING-class check (Valea's deny-list doesn't reach into a folder it
doesn't own) — it still reports `"failed"` (this codebase's status
vocabulary has no separate "warning" literal), the warning framing lives
in the wording; it lists directory ENTRY NAMES at the mount root only
(`File.ls/1`), never opens a file. `watcher_live` asks
`Valea.ICM.Watcher.watched_roots/0` whether the mount's root is in the
CURRENT watched set — `"unknown"` (not `"failed"`) for a disabled mount,
since the watcher never watches a disabled external root by design.
Exposed over RPC as `mounts_doctor` (`Valea.Api.Mounts`), rendered by
`MountsDoctorPanel.svelte` on `/knowledge`.

**Watcher.** `Valea.ICM.Watcher` splits its `FileSystem` subscription in
two: a FIXED listener over `mounts/`, `queue/`, `config/` — started once in
`init/1`, never restarted, giving the workspace's own trees a zero-loss
window across every recompute — and a DYNAMIC listener over the currently
enabled external roots, stopped and restarted (bounded 5s stop, unlinked
first so a hung port can't block the GenServer) whenever that root set
actually differs. `config/workspace.yaml` is now watched too — it's the
source of truth for both enabled/disabled state and external-mount
declarations, so a hand-edit to it is discovery-relevant (only the file
itself; `config/mail.yaml`/`config/calendar.yaml` produce no event). On its
OWN discovery flush the watcher regenerates `MOUNTS.md` and
`.claude/settings.json` BEFORE broadcasting `{:mounts_changed}` — closing
the gap where a hand-edited config or a manually dropped-in `icm.yaml`
previously left those derived files stale until the next RPC mutation
happened to touch them.

**RPCs + audit.** `Valea.Api.Mounts` gains `declare_mount` (validates via
`External.validate_ref/2` first — a failing candidate is rejected outright
with no config write at all), `undeclare_mount` (config-only; NEVER
touches the folder, embedded or external), and `mounts_doctor`. Declaring,
undeclaring, enabling, or disabling an EXTERNAL mount is a workspace
BOUNDARY change (a filesystem location outside the workspace an agent
session can now read) and is audited (`mount_declared`/`mount_undeclared`/
`mount_enabled`/`mount_disabled`, `Valea.Mounts`) with the mount's `name`
and best-effort RESOLVED absolute path; toggling an EMBEDDED mount stays
unaudited (it never changes a read boundary — it always lived inside the
workspace).

**`MOUNTS.md`.** An external mount's enabled block shows its real location
(`mounted from: <resolved-abs>`) instead of a workspace-relative `path:`
line, and its `@`-ref line points at the full absolute path
(`@<resolved-abs>/AGENTS.md`) rather than `@mounts/<name>/AGENTS.md` — a
bare, non-Valea Claude Code session has no workspace root to resolve a
relative reference against. A degraded external mount renders under
"Needs attention" with its resolved (possibly nonexistent) path, or the
placeholder `(no path declared)` when the ref was never absolute/`~`-based
to begin with.

**Frontend.** By-reference is the DEFAULT adopt action in onboarding: when
"open an existing workspace" is pointed at a folder that already looks
like an ICM, "Use it where it is" (`onboarding-path.ts`'s
`adoptByReference` — scaffolds a normal new workspace with its own starter
mount, then declares the picked folder as a second, referenced mount) is
the primary button; "Move it into the workspace" (Plan A's original
move-adopt flow) stays available as the explicit secondary choice.
Knowledge's "Mount a folder from elsewhere…" (`MountFromElsewhereDialog.svelte`)
is the same declare flow post-onboarding — nothing is copied or moved, the
folder is read exactly where it already lives. "Unmount"
(`UnmountDialog.svelte`) is config-only — the folder stays exactly where it
is on disk. `MountsDoctorPanel.svelte` renders the doctor checks above on
`/knowledge`. A declare-stage failure during onboarding is a genuine UX gap
without extra handling: `workspaceStore.create` flips workspace state to
`'open'` — swapping the Onboarding screen out — BEFORE `declare_mount`
resolves, so a failure landing after that flip has no live onboarding card
left to render on. `mountsStore.pendingAdoptError` persists that failure
across the transition; the onboarding flow explicitly navigates to
`/knowledge` on a declare-stage failure so the Knowledge page's dismissible
banner is actually reachable (post-onboarding success still lands on
Today, unchanged).

## Methodology depth (Spec B)

*(pending merge on `feat/methodology-depth`; spec:
[2026-07-12-methodology-depth-design.md](superpowers/specs/2026-07-12-methodology-depth-design.md))*

Closes the teaching loop from the vision's daily-loop step 5: knowledge
flows into ICM through three doors, split by whether a human is present.
**Chat** keeps direct edits — the agent writes a mount page with its native
tools; the ask-gate dialog (below) reviews the diff in the moment, no queue
involvement. **Workflow runs** and **reflection** (no user present) require
the queue: the agent stages a memory-update PROPOSAL PAIR instead of
editing, for the human to review later. All three surfaces share one
server-derived risk tier and one apply executor.

### Risk tiers

`Valea.Agents.RiskTier.classify/2` (`backend/lib/valea/agents/risk_tier.ex`)
is the one risk-tier classifier every surface below shares: `"high"` for a
mount-relative path that is `AGENTS.md`, `CLAUDE.md`, `icm.yaml`, or starts
with `Workflows/` (the mount's own instruction spine and stage contracts —
an approved edit changes future agent behavior); `"medium"` for anything
else inside a mount; `nil` for a path that does not attribute to any mount
(via `Valea.Mounts.mount_for/2`) — the workspace shell, or nowhere. Display
and envelope metadata only, never an access decision.

### Chat teaching — the ask-gate dialog

The existing permission-ask surface, unchanged in its allow/deny/ask
semantics, gained a real review. `Valea.Agents.SessionServer`'s
`enrich_item/2` (`backend/lib/valea/agents/session_server.ex`) stamps
`risk_tier` onto a `"permission"`-type ACP item whenever its `rawInput`
carries a file path and `RiskTier.classify/2` returns `"high"`/`"medium"` —
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
back to today's plain display.

### Workflow proposals — proposal pairs + staging grants

A memory-update proposal is a sibling pair written into the run's
already-granted staging dir: `queue/staging/<run_id>/proposals/<name>.md`
(full new page content) + `<name>.json` (a `memory_update/v1` manifest:
`schema`, `target_path`, `base_sha256` — 64-hex or `null` for "create" —
`reason`, `sources`). `Valea.Workflows.MemoryProposal`
(`backend/lib/valea/workflows/memory_proposal.ex`) owns loading/validating
pairs (`load_pairs/1` — globs `proposals/*`, pairs `.json`↔`.md` by
basename, reports a `.json` with no sibling `.md` as `{:error, :missing_content}`
and a `.md` with no claiming `.json` as `{:error, :orphaned_content}`, caps
content at 1,000,000 bytes) and the server-owned containment check
(`check_target/2` — the target must attribute to an ENABLED, non-degraded
mount via `Valea.Mounts.mount_for/2`, and its physical resolution via
`Valea.Paths.resolve_real/2` must stay inside that mount's own root; the
manifest's own claims are never trusted). `Valea.Workflows.
Runner`'s `start_run/5` (`backend/lib/valea/workflows/runner.ex`) grants the
write through `Valea.Agents.PermissionPolicy`'s directory-scoped
`write_roots` (`policy_ctx.write_roots: [Path.join(staging_dir,
"proposals")]`) — deliberately NOT the staging dir itself, so the trusted
`run.json` sidecar stays unwritable by the agent; `PermissionPolicy.
decide/2`'s write-kind branch allows a path under `write_paths` (the exact
`proposal.json` file) OR `write_roots` (anything under the granted
directory, segment-boundary contained via `all_in_write_roots?/3`) for a
`session_kind == "workflow"` session. The same call also extends the
session's `read_roots` with the run's own staging dir
(`SessionServer.default_read_roots/1`, extended, never re-derived) — a run
may always read back what it may write.

### Finalize — one queue item per pair, server-owned trust fields

`Valea.Workflows.Runner.finalize/2` additionally globs `proposals/*.json`
(via `MemoryProposal.load_pairs/1`); each valid pair becomes its own
pending item with id `<run_id>-m1`, `-m2`, … (1-based over the full sorted
pair list, so ids stay stable across re-finalizes even when some pairs are
invalid). Every memory item's `risk_level` and target containment are
computed HERE, from the target path alone, via `RiskTier.classify/2` +
`MemoryProposal.check_target/2` — never taken from the agent's manifest. An
invalid pair is audited `memory_proposal_invalid` (`run_id`, `file`,
`reason`); the run's staging dir is kept whenever anything was invalid —
the whole directory stays in place for inspection when any pair failed — or
fully removed when all pairs were valid, never partially cleaned.
Idempotence: before writing any pending item (primary or memory),
`item_exists?/2` checks all four queue directories (`pending/processing/
approved/rejected`) and skips silently if the id already exists — this is
what lets `Valea.Workflows.Runner.recover_staging/1` (crash-recovery
backstop, run at `Valea.Workspace.Runtime` startup, before any session can
be created) re-run `finalize/2` on every leftover staging dir without
resurrecting already-decided items.

### Apply executor

`Valea.Queue.approve/2` (`backend/lib/valea/queue.ex`) dispatches on
`payload.kind`: a `"memory_update"` item executes `execute_memory/3` →
`apply_page_content/2` instead of the email-draft path. It re-runs
`MemoryProposal.check_target/2` against the CURRENT mount state (not the
finalize-time result), then guards the write with a base-hash check
(`check_base/2` — `nil` means "must not already exist"; otherwise the
current bytes must sha256 to `base_sha256`). Any guard failure — or a write
fault rescued in `write_page/2` (`File.Error`/`File.RenameError`) — means
NOTHING was written: the claimed item is renamed straight back to
`pending/`, `apply_conflict` is audited with the reason, and
`{:error, :apply_conflict}` is returned. On success the page is written with
an atomic tmp+rename (`write_page/2`, `mkdir -p` of parents, contained
inside the mount only), then the SAME `queue_item/v2` upgrade-then-rename
into `approved/` the email path uses — stamping `decided_at`, with no
`mailbox_ops` (that map is added only when `payload.kind == "email_draft"`,
`maybe_put_mailbox_ops/4`). `approve/2` returns `{:ok, %{draft_path: nil,
applied_path: target_path}}` for a memory item, `{:ok, %{draft_path: ...,
applied_path: nil}}` for an email item; `Valea.Api.Queue.approve_item`
surfaces both fields typed, and the frontend's `MemoryUpdateReview.svelte`
renders the `apply_conflict` error code as its own `conflict` FSM state
(distinct from `changed`/`gone`), offering "reject it or re-run the
workflow."

### Crash recovery

`Valea.Queue.recover/1`'s `classify_recovery/2` decides a `processing/`
item's fate by KIND: a `memory_update` item is decided by CONTENT, not
draft existence — the envelope's `content_markdown` is hashed against the
target's CURRENT on-disk bytes (`memory_target_abs/2`); a match means the
apply already landed, so `finish_recovered_memory/3` stamps the `v2`
upgrade and completes the rename to `approved/` (audited `item_approved`,
`recovered: true`, no mailbox broadcast); anything else (target missing, or
present with different bytes) hands the item back to `pending/`
(`repend!/3`, audited `approval_recovered`) for the human to re-decide.
Every other kind falls through to the original draft-existence recovery,
unchanged. `mailbox_ops` stays email-only throughout: `maybe_put_mailbox_ops/4`
is gated on `payload.kind == "email_draft"` (adding the map only for email
drafts), while `valid_mailbox_ops?/1` simply checks that `mailbox_ops`, if
present, is a map with no kind requirement — so a memory item's decided
envelope never carries the key (nil passes the generic map check).

### Rejection reasons

`Valea.Queue.reject/3` takes an optional one-line free-text `reason`
(default `nil`, so every existing 2-arity call site is unaffected).
`normalize_reason/1` trims, caps at 500 chars, and blank-collapses to `nil`
(same as omitting it). A non-nil reason is stamped into the decided
envelope as `"decision" => %{"reason" => reason}` (`maybe_put_decision/2`,
part of the same `v1→v2` upgrade that stamps `decided_at` — both decision
verbs, every kind) and included in the `item_rejected` audit entry.
`Valea.Api.Queue.reject_item`'s `reason` argument is `allow_nil?: true,
default: nil`; the frontend's `DraftReview.svelte` and `MemoryUpdateReview.
svelte` both render a skippable single-line reason input alongside their
reject button, and the decided-item view (`frontend/src/routes/queue/
[run_id]/+page.svelte`, fed by `normalizeDecidedItem` in
`frontend/src/lib/components/queue/queue-ops.ts`) shows the reason on a
rejected item.

### Reflection — the Distill Decisions workflow

`Valea.Workflows.Distill.digest/1` (`backend/lib/valea/workflows/
distill.ex`) compiles the reflection workflow's input server-side: every
decided envelope (`queue/approved/*.json` + `queue/rejected/*.json`) with a
`decided_at` inside a fixed 30-day window (an envelope without the stamp —
pre-Spec-B — is EXCLUDED, not treated as always-in-window) is rendered into
one markdown digest (kind, title, workflow, decision, date, rejection
reason per item). `Valea.Workflows.Runner.run_generated/3` is the
generated-input sibling of `run/2`: it writes the compiled digest into the
run's OWN staging dir before the session starts (never `proposals/`, since
it's server-owned input, not agent output) and reuses the exact same
staging read grant described above — the read boundary never widens to
`queue/` itself, the digest is self-contained. `distill_decisions`
(`Valea.Api.Agents`) resolves the seeded contract via `Valea.Workflows.
distill_path/0` (first enabled mount, in `list/0`'s own sort order, whose
`Workflows/` glob yields a `Distill Decisions.md` basename —
`workflow_not_found` if none), builds the digest (`no_recent_decisions` if
the window is empty), and calls `run_generated/3`. `Valea.Cockpit.today/0`
surfaces the same lookup as a live `"distill_workflow_path"` field so the
UI can hide the action entirely when no mount seeds the contract. The
starter mount ships `Workflows/Distill Decisions.md` (manual trigger,
`risk_level: medium`, approval required, outputs restricted to
`apply_page_content`) and a `Decisions/2026.md` seed page; the
memory-update contract (manifest shape, `base_sha256` rules, the 1 MB
content cap) lives in the root `AGENTS.md`'s "The memory-update contract"
section. Frontend: `distillButtonState`/`distillErrorMessage`
(`frontend/src/lib/today/distill.ts`) drive the "Distill recent decisions"
action on both `frontend/src/routes/+page.svelte` (Today) and
`frontend/src/routes/workflows/+page.svelte`, hidden entirely when
`distillWorkflowPath` is `null`.

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
`icm_paths_exist` → `:paths_exist` (`icmPathsExist`, arg `paths` —
resolves each through the same mount-containment check
(`Valea.Workflows.MemoryProposal.check_target/2`) the memory-update write
path uses, then a plain `File.regular?/1`) on `Valea.Api.ICM`
(`backend/lib/valea/api/icm.ex`).

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
RPC (`icm_entry_references` → `:references`) now returns BOTH kinds in one
call — `{workflows: [...], pages: [...]}` — unifying `Valea.ICM.
References.referencing_workflows/1` (Layer-2 stage-contract `sources:`
entries) with `Backlinks.backlinks/2` (in-page links) behind one RPC
surface.

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
(`backend/lib/valea/icm/splice.ex`, extracted from `References` so both
modules share it) that `Valea.ICM.References` already uses — the
REFERENCING file is never round-tripped through the markdown↔ProseMirror
converter, so the determinism contract holds. Confirmation runs through
`Backlinks.destinations/3` (the same real AST parse backlinks uses); the
new destination is computed via `Valea.Paths.relative/2` (workspace-
relative pairs) or kept absolute (either end external).
`Valea.ICM.rename/2` returns `updated_pages` (this module's output)
alongside the pre-existing `updated_workflows`.

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
`Valea.Api.ICM`. Starter content: `mounts/starter/Templates/{Client,
Decision,Follow-up Email,Discovery Call Reply}.md` — `Decision.md` pairs
with Spec B's `Decisions/` convention.

### Images — `Assets/` + `/files` endpoints

`ValeaWeb.FilesController` (`backend/lib/valea_web/controllers/
files_controller.ex`) writes to and serves `Assets/<page-slug>-<hash8>.
<ext>` at the target mount's root. `POST /files/upload` is token-gated
(its own `:files_upload` router pipeline mirrors `:rpc`'s `ValeaWeb.Plugs.
ControlToken`), capped at 10 MB (`@max_upload_bytes 10_000_000`, checked
via `File.stat/1` on the parsed upload — the transport-level `Plug.
Parsers` `length:` in `endpoint.ex` is set higher, `12_000_000`, purely as
headroom so this business check runs first), and allowlists BOTH extension
and `content_type` (`.png/.jpg/.jpeg/.gif/.webp` → their exact MIME type —
deliberately no `.svg`, which is scriptable). Both actions attribute the
requested path to an ENABLED, non-degraded mount and contain it via
`Valea.Workflows.MemoryProposal.check_target/2` (the same symlink-aware
`Valea.Paths.resolve_real/2` containment the memory-update write path
uses) — a symlink planted inside a mount's `Assets/` folder is defeated the
same way. `GET /files/raw` is deliberately TOKEN-EXEMPT — its own
unauthenticated `/files` scope on the plain `:api` pipeline in `router.
ex` — because an `<img>` tag cannot send custom headers, and the
Phoenix endpoint only ever binds loopback (127.0.0.1): the endpoint
exposes only files a local process could already read. It sets
`x-content-type-options: nosniff` and `content-disposition: inline`, and
always derives `content-type` from the allowlisted file EXTENSION —
never from anything client-supplied or stored — so a mismatched upload can
never make the serve path emit an attacker-chosen content-type.

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
  of truth over `icm_entry_references`'s `{workflows, pages}`;
  `RenameDialog`/`DeleteDialog` render the same impact line before the
  user confirms. `frontend/src/lib/components/knowledge/
  template-options.ts`'s `templateOptions` (mount-scoped — only offers
  templates from the mount that owns the target parent folder) feeds
  `NewEntryDialog`'s "Start from" select.

## Design system pointer

UI follows the "paper & ink, with a green pen for approval" design system: [docs/DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) (canonical source: `docs/design/cockpit-design-system-v1.pdf`). Two-layer token architecture (raw tokens → shadcn-svelte semantic variable mapping); feature code never touches raw Tailwind classes directly. Shell layout is a reusable four-column grid (Sidebar · optional ListPane · Main · optional Rail) implemented as an `AppShell` component family on shadcn-svelte primitives.

### Shell component inventory (`frontend/src/lib/components/shell/`)

- `AppShell.svelte` — the four-column grid shell (Sidebar · optional ListPane · Main · optional Rail); pages compose inside it.
- `AppFrame.svelte` — outer frame/chrome wrapper around `AppShell`.
- `Sidebar.svelte` — left nav column (top-level sections, e.g. Today, Knowledge).
- `SidebarItem.svelte` — single sidebar row/link.
- `Rail.svelte` — optional right-hand rail column.
- `ListPane.svelte` — optional second column for list-over-detail views (e.g. Knowledge's folder/page list).
- `IcmTree.svelte` — the live ICM nav tree; consumes `icmStore` (`frontend/src/lib/stores/icm.svelte.ts`) and re-renders on `icm_changed`.
- `SectionOverline.svelte` — small caps section label used throughout (onboarding cards, sidebar groups).
- `StatusPill.svelte` — small status/badge pill.
- `EmptyState.svelte` — generic empty-state block (stub pages, empty folders).
- `index.ts` — barrel export.

Related, not under `shell/` but part of the same top-level chrome:

- `frontend/src/lib/components/onboarding/` — `Onboarding.svelte` (root two-card + trust bar screen, rendered by `+layout.svelte` when `workspaceStore.state === 'none'`), `CreateWorkspaceDialog.svelte`, `OpenWorkspaceFlow.svelte`, `WhatsInAWorkspace.svelte`, `TrustBar.svelte`.
- `frontend/src/lib/components/today/` — `ScheduleList.svelte`, `PreparedItemCard.svelte` (renders the "Why this?" source dialog over `usedSources`), `SourceChips.svelte`, `OpenLoops.svelte`, `AwayList.svelte` — the §17 Today cockpit.
- `frontend/src/lib/components/ui/` — shadcn-svelte primitives (button, dialog, input, label, badge, separator, skeleton, scroll-area, tooltip).

## Spec index

- [2026-07-09-valea-foundation-design.md](superpowers/specs/2026-07-09-valea-foundation-design.md) — Foundation: monorepo scaffold, workspace creation/selection, app shell, Today cockpit (seeded), ICM tree in nav.
- [2026-07-10-icm-editor-design.md](superpowers/specs/2026-07-10-icm-editor-design.md) — ICM editor: markdown↔ProseMirror converter + determinism contract, version-guarded saves, reference-aware tree CRUD, typed RPC.
- [2026-07-10-agent-slice-design.md](superpowers/specs/2026-07-10-agent-slice-design.md) — Agent slice: ACP agent runtime, trust/permission model, queue/audit approval flow, control-plane auth, workspace runtime generations, ICM layer mapping.
- [2026-07-11-mail-design.md](superpowers/specs/2026-07-11-mail-design.md) — Mail: IMAP sync-to-files engine, normalized message file format, `queue_item/v2` mailbox ops, OS-keychain credential handoff, connection doctor, `/mail` UI.
- [2026-07-12-icm-mounts-design.md](superpowers/specs/2026-07-12-icm-mounts-design.md) — ICM mounts (Plan A): `mounts/<name>/` replaces the single `icm/` tree, manifest-based discovery, `MOUNTS.md` generated routing, per-mount `read_roots`, v3→v4 migration, mounts-aware Knowledge UI, adopt-by-move onboarding.
- [2026-07-12-icm-by-reference-design.md](superpowers/specs/2026-07-12-icm-by-reference-design.md) — By-reference mounts (Plan A2): external `kind: "path"` mounts referenced in place, root-set containment, managed-settings external `Read` allows, per-mount doctor, declare/undeclare RPCs + audit, by-reference-default onboarding.
- [2026-07-12-methodology-depth-design.md](superpowers/specs/2026-07-12-methodology-depth-design.md) — Methodology depth (Spec B): server-derived risk tiers, memory-update proposal pairs + staging write/read grants, the queue's `apply_page_content` executor and content-hash crash recovery, optional rejection reasons, the decisions digest + Distill Decisions reflection workflow, and the diff/risk-tier ask-gate and memory-update review UI.
- [2026-07-12-knowledge-depth-design.md](superpowers/specs/2026-07-12-knowledge-depth-design.md) — Knowledge & editor depth (Spec C): scan-backed search with an FTS5 upgrade seam, AST-confirmed backlinks, byte-surgical rename link-rewrite, page templates, contained image upload/serve endpoints, the `[[`/`@` page-link picker, the Cmd+K search palette + MRU + dangling-link handling, and the backlinks panel + page-aware impact dialogs + template select UI.
- [2026-07-13-icm-project-workspaces-design.md](superpowers/specs/2026-07-13-icm-project-workspaces-design.md) — Approved target redesign: private Valea workspace profiles, user-owned ICM projects mounted only by reference, one primary ICM and `cwd` per session, explicit cross-ICM context, project/session navigation, and simplified onboarding.
