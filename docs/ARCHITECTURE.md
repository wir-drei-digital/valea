# Valea — Architecture

Condensed map of the standing decisions. Full reasoning per feature lives in
[docs/superpowers/specs/](superpowers/specs/); this file states outcomes, not
rationale, and grows with each feature/spec.

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
- **`Valea.Workspace.Manager`** (GenServer) owns the open-workspace lifecycle: `create/2` scaffolds a new workspace from `backend/priv/workspace_template/` (via `Valea.Workspace.Scaffold.create/1`) and opens it; `open/1` validates the workspace marker structure, starts `Valea.Repo` under the `DynamicSupervisor` pointed at `{path}/app.sqlite`, runs Ecto migrations, records the workspace in app config, and broadcasts `{:workspace_opened, %{path:, name:}}` on the `"workspace"` PubSub topic. `close/0` (broadcasts `{:workspace_closed}`) and `current/0` (`{:ok, %{path:, name:}} | {:error, :no_workspace}`) round it out. At boot, `handle_continue(:auto_open, _)` reopens `App.Config.read()["last_opened"]` automatically if it still validates as a workspace (falls back to workspace-less if the path no longer validates). After migrations, the Manager also starts `Valea.ICM.Watcher` under the same `DynamicSupervisor`; it watches `{workspace}/icm` and broadcasts a debounced (200ms) `{:icm_changed}` on the `"icm"` PubSub topic whenever anything underneath changes.
- **Rollback is two-tier, and only one tier is implemented today.** Process-level: `open_workspace/2,3` in `Manager` starts the Repo then the watcher one at a time, accumulating started pids; if either step fails, every pid started so far is torn down via `DynamicSupervisor.terminate_child/2` before the error returns — a half-opened workspace never keeps a Repo or watcher running under a name a later open/create could mistake for success. Filesystem-level: `Valea.Workspace.Scaffold.create/1` (`File.mkdir_p` + `File.cp_r` from the template) has **no rollback** — if `File.cp_r` fails partway through copying `backend/priv/workspace_template/`, the partially-written target directory is left on disk as-is; nothing deletes it. In practice this window is small (a local recursive copy of a few dozen small template files) and no acceptance test has hit it, but it's a known gap, not a designed guarantee.
- Migrations run **at workspace open**, in every environment — not at release boot, since the database doesn't exist until a workspace is open.
- Open/create failures are loud and specific; a workspace is never presented as healthy when half-seeded (process-level, per above).

## API layer

- **`ash_typescript`**: Ash actions on the `Valea.Api` domain (`backend/lib/valea/api.ex`, extension `AshTypescript.Rpc`) exposed as typed RPC, with a generated TypeScript client (`frontend/src/lib/api/ash_rpc.ts`, committed) giving end-to-end type safety. No AshJsonApi, no hand-maintained client types. All three resources (`Workspace`, `ICM`, `Cockpit`) are data-layer-less Ash resources — thin adapters over plain Elixir modules (`Valea.Workspace.Manager`, `Valea.ICM`, `Valea.Cockpit`), not Ecto-backed.
- **RPC action list** (`rpc_action(:name, :action)` in `Valea.Api`, generated TS function name in parens):
  - `Valea.Api.Workspace`: `get_workspace` → `:current` (`getWorkspace`) — reports `{open, path, name}`, `open: false` when no workspace; `create_workspace` → `:create_workspace` (`createWorkspace`, args `parent_dir`, `name`); `open_workspace` → `:open_workspace` (`openWorkspace`, arg `path`); `close_workspace` → `:close_workspace` (`closeWorkspace`); `recent_workspaces` → `:recent` (`recentWorkspaces`); `inspect_workspace` → `:inspect_workspace` (`inspectWorkspace`, arg `path` — used by the "what's in this folder" onboarding preview).
  - `Valea.Api.ICM`: `icm_tree` → `:tree` (`icmTree`) — nested folder/page tree of `{workspace}/icm`; `icm_page` → `:page` (`icmPage`, arg `path`).
  - `Valea.Api.Cockpit`: `cockpit_today` → `:today` (`cockpitToday`) — the seeded §17 narrative.
- **Transport: Phoenix channels first, HTTP fallback.** One socket (`ValeaWeb.UserSocket`, path `/socket`) carries two independent channel topics: `ash_typescript_rpc:client` (ash_typescript's channel-RPC transport — every `icmTree()`-style call goes here when the channel is joined) and the single consolidated **`workspace:events`** channel, joined once from `frontend/src/routes/+layout.svelte` via `wireIcmEvents()` (`frontend/src/lib/stores/icm.svelte.ts`) and pushing two event names: `workspace` (`{open, name?, path?}`, on open/close) and `icm_changed` (`{}`, on any change under `{workspace}/icm`, debounced 200ms by `Valea.ICM.Watcher`). There is no per-feature channel sprawl — `workspace:events` is the one realtime channel, and non-realtime RPC prefers `ash_typescript_rpc:client` but transparently falls back to plain `POST /rpc/run` (`ValeaWeb.RpcController.run/2`) when the socket/channel isn't joined (see `frontend/src/lib/api/client.ts`).
- Plain controllers only where RPC doesn't fit — e.g. `GET /api/health` (`ValeaWeb.HealthController`, returns `{"status":"ok"}`) for sidecar port polling from Tauri.
- Codegen is part of the build: `just codegen` runs `mix ash_typescript.codegen`; `just test` fails if the checked-in client is stale.
- Errors follow ash_typescript's structured error shape; the frontend maps a workspace-not-open error to the onboarding screen.
- **Unconstrained `:map` RPC actions stay snake_case on the wire.** `Workspace`, `ICM`, and `Cockpit` actions are all typed `:map` or `{:array, :map}` (no Ash embedded/typed schema) because they wrap plain Elixir data, not Ecto structs. ash_typescript's camelCase output formatter only reformats keys it can see in a typed schema — an unconstrained `:map` return is opaque to it, so the generated TS type is `Record<string, any>` and the actual keys arrive exactly as the backend wrote them: snake_case. Concrete example: `Valea.Cockpit.today/0` (`backend/lib/valea/cockpit.ex`) returns `"prepared_items" => [%{"used_sources" => [...], "primary_action" => ..., ...}]`; the wire payload from `cockpit_today` genuinely contains `used_sources`, `primary_action`, `date_label`, `open_loops`, `while_you_were_away` — not their camelCase equivalents. The same applies to `icm_tree`'s `page_count`. Frontend code that consumes these actions normalizes explicitly rather than trusting the generated type: see `normalizeCockpitToday`/`pick()` in `frontend/src/lib/today/cockpit.ts` (checks the snake_case key first, camelCase second, and maps to a typed camelCase `CockpitToday`/`PreparedItem { usedSources, primaryAction, ... }` shape) and `normalizeIcmNode` in `frontend/src/lib/stores/icm.svelte.ts` (same pattern for `page_count`/`pageCount`). Any new `:map`-typed RPC action needs the same explicit normalization at the call site — do not trust the generated `Record<string, any>` type to already be camelCase.

## ICM editor (Phase 2)

- **Markdown ↔ ProseMirror converter** (`backend/lib/valea/markdown/prose_mirror.ex`, `.../profile.ex`): vendored from `magus/lib/magus/markdown/prose_mirror.ex` (header comment records the origin + Valea's divergences — positional `profile` arg, `to_markdown/2` returns `{:ok, md}`, blockquote serializer drops the trailing space on blank quote lines). MDEx-based, pure/IO-free. `Valea.Markdown.Profile` is the Valea profile: every callback (`post_process/1`, `node_to_markdown/1`, `inline_node_to_markdown/1`) is the identity/default — no custom node lifting, standard CommonMark + GFM only (the paper's "plain text as interface" principle; no callouts/wikilinks/tags/`magus://` links/image blocks). **Determinism contract** (`backend/test/valea/markdown/determinism_test.exs`): every seed page under `backend/priv/workspace_template/icm/**/*.md` (13 pages) round-trips `markdown → PM JSON → markdown` byte-identically, and a second pass is a fixed point — enforced by test, not just convention; the editor never sees markdown, only tiptap's ProseMirror JSON, converted at the backend boundary.
- **`Valea.ICM` write operations** (`backend/lib/valea/icm.ex`): `save_page(rel_path, pm_map, base_hash)` — SHA-256-hex hash guard (`sha256_hex/1` of the current file bytes must equal `base_hash` or the call returns `{:error, :page_changed}`, magus-style optimistic concurrency adapted to files, no lock files, no mtime), then `ProseMirror.to_markdown/1` and an atomic write; `create_page/2` / `create_folder/2` (shared `normalize_name/1` — NFC-normalize, trim, reject empty/`/`/`\`/leading `.`, `.md` auto-appended for pages; parent-must-be-a-directory guard); `rename/2` and `delete/1` work for both pages and folders (folder rename collects every nested `.md` first, then rewrites references for each). All writes share one `atomic_write/2` helper (tmp file + `File.rename!` in the same directory) and pass through the existing containment chokepoint (`contain/2`). `page/1` (existing read) now also returns `hash` (SHA-256 hex of the bytes at read time) and `prosemirror` (converted JSON) — a conversion failure is loud (`{:error, {:conversion_failed, msg}}`), never a silently-degraded page.
- **`Valea.ICM.References`** (`backend/lib/valea/icm/references.ex`): plain-string scan of `{workspace}/workflows/*.yaml` for the literal `icm/<rel_path>` needle (no YAML parsing needed — the paths are load-bearing `sources:` entries in Layer-2 stage contracts per the ICM paper). `referencing_workflows/1` returns `[%{file:, name:}]` (`name:` via `~r/^name:\s*(.+)$/m`, falls back to the filename); `rewrite/2` string-replaces the old needle with the new one in every referencing file, atomically, and reports which files it touched — `Valea.ICM.rename/2` calls this after a successful move and returns `updated_workflows` (the human-readable names) to the caller; if a rewrite fails partway, the error is reported truthfully as `{:rewrite_failed, file, reason}` rather than claimed as success (no rename rollback — a known, documented gap, same posture as the workspace-scaffold rollback gap above). `delete/1` deliberately does NOT touch workflows; `icm_entry_references/1` lets the UI warn before a destructive delete.
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
path falls inside the declared reference roots (`icm`, `sources`, `prompts`,
or the root `AGENTS.md`/`CLAUDE.md` files — a list, so ICM mounts can extend
it later) — never a blanket workspace-root allow. Write-kind calls are
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

### ICM layer mapping (documented adaptation)

| Paper layer | Valea location | Notes |
| --- | --- | --- |
| Layer 0 root instructions + Layer 1 routing | `AGENTS.md` (+ `CLAUDE.md` containing only `@AGENTS.md`, Claude Code's native import) | Combined into one file at this workspace size; enumerates ICM roots so mounts can extend it later |
| Layer 2 stage contracts | `icm/Workflows/*.md` | Hosted inside the reference tree — a deliberate Valea adaptation (one tree, one editor, one nav), not a separate `workflows/` folder |
| Layer 3 stable reference | `icm/` (everything else — Clients, Offers, Policies, Pricing, Templates, Tone & Voice, Decisions) | Read-only to the agent; only the pages a job's Inputs name are meant to be read, never the whole tree |
| Layer 4 working artifacts | `queue/` (staging/pending/processing/approved/rejected), `sources/` | Agent write access is confined to the exact staging path a run names; everything downstream is server-authored |
| — (not an ICM layer) | `logs/` (`sessions/*.jsonl`, `audit.jsonl`) | Operational record — transcripts and the audit trail, not agent-facing memory |

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
(gated on `config_present` alone — a local file check: does
`icm/Workflows/New Inquiry Triage.md` still reference the legacy JSON
input instead of `sources/mail/messages/*.md`). Never raises; every check
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
