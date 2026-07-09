# Valea Foundation — Design

**Date:** 2026-07-09
**Status:** Approved
**Scope:** Sub-project 1 of ~8 (brief Phase 1: app shell and workspace)

## Context

Valea is a local-first agentic operating system for solopreneurs (see the project
brief, v1.0, 2026-07-09, by wir drei digital). It combines a basic email client,
calendar, chat assistant, task management, and business memory (ICM) into one
desktop app whose AI assistant prepares admin work and waits for human approval.

This spec covers only the **foundation**: monorepo scaffold, workspace
creation/selection with seeded content, the left-navigation app shell, the Today
cockpit with seeded static data, and the ICM folder tree reflected live in the
Knowledge nav. Later brief phases (ICM editor, queue/audit, mail, calendar,
workflow execution, agent harnesses, ACP) each get their own spec → plan →
implementation cycle.

## Decisions that diverge from the brief

The brief (§3) prescribes TypeScript monorepo packages plus a Node sidecar. We
instead reuse the stack and scaffold of the sibling project **legend**
(`/Users/daniel/Development/legend`):

1. **Elixir/Phoenix/Ash backend owns the core** (workflows, queue, ICM indexing,
   audit, harness adapters) instead of Node + TS packages. The brief's TypeScript
   data models become Ash resources / Elixir structs on the backend and TS types
   on the frontend. Canonical data stays file-backed as the brief demands;
   SQLite remains cache/index.
2. **The workspace template ships in `backend/priv/workspace_template/`**, not a
   repo-root `workspace-template/` folder — it must be embedded in the Burrito
   release binary.
3. Everything else in the brief (workspace layout, ICM-at-the-core, approval
   queue, transparency principles, UI structure, design tone) stands.

## Approach

Clone legend's monorepo skeleton and **strip aggressively**: keep only
infrastructure, delete all legend domains and the tiling shell. The ACP codec
and harness seam are re-imported fresh from legend in Phases 7–8 (legend keeps
evolving them meanwhile; carrying dead entangled code now is worse than
re-copying later).

The existing bare Tauri+SvelteKit template in `valea/` is replaced.

## Repo shape

```
valea/
  backend/    Elixir 1.20 / Phoenix 1.8 / Ash 3 / AshSqlite — Valea.* / ValeaWeb.*
  frontend/   SvelteKit static SPA (Svelte 5 runes, no SSR — ever), Bun,
              Tailwind v4 + shadcn-svelte
  desktop/    Tauri v2, backend bundled as a Burrito sidecar binary
  docs/       ARCHITECTURE.md + superpowers/specs/
  Justfile    setup / dev / dev-desktop / test / build / package-backend /
              desktop-bundle
```

**Kept from legend:** boot skeleton (Repo → Migrator → PubSub → Endpoint),
`runtime.exs`/dotenvy config flow (`.env` in dev, real env wins), release +
Burrito build scripts (incl. pinned zig auto-provisioning), Tauri sidecar
lifecycle (`main.rs`: spawn sidecar, poll port, show window, kill on exit; dev
builds skip the sidecar), Justfile recipes, frontend design-token architecture +
shadcn-svelte setup, `api.ts`/`socket.ts` clients, `.tool-versions`, SQLite via AshSqlite with `require_atomic? false` on custom
update actions. Legend's "migrations run on boot in releases" rule does **not**
carry over: because the database lives inside the workspace, migrations run at
workspace open in every environment (see Workspace model).

**Deleted:** all legend domains — agents/sessions, signals/MCP, library,
devices/remote/federation, harnesses, runtimes, sprites, tunnels, storage, the
relay ingress — and the frontend tiling/dock workspace shell.

**Ports** (valea and legend coexist in dev): Phoenix dev **4200**, Vite
**4273**, desktop sidecar fixed **4817**. Backend binds loopback only.

## Workspace model

The brief puts `app.sqlite` **inside the workspace** (the user owns and can hand
off the whole folder). Legend's app-data-DB model doesn't fit, so:

- **App-level config** — `Valea.App.Config` manages a small JSON file in the OS
  app-data dir (`~/Library/Application Support/valea/config.json` on macOS):
  known workspaces (path, name, last opened at) + last-opened workspace path.
  This resolves the bootstrapping problem (the app needs state before any
  workspace exists) without a database.
- **Backend boots workspace-less.** Boot order: Telemetry → App.Config →
  PubSub → Workspace.Manager → Endpoint. The Repo is **not** a static child.
- **`Valea.Workspace.Manager`** (GenServer) owns the open-workspace lifecycle:
  - `create(parent_dir, name)` — scaffold `{parent}/{name}` from the template,
    then open it.
  - `open(path)` — validate the folder is a workspace (marker: expected
    top-level dirs), start the Repo under a supervisor with
    `database: {path}/app.sqlite`, run Ecto migrations, start the ICM watcher,
    update app config (known + last-opened), broadcast `workspace_opened`.
  - `close/0`, `current/0` (path + display name).
  - At boot, auto-opens the last-opened workspace if it still exists.
  - Open failures are loud and specific (unwritable path, not a workspace,
    seed failure); a workspace is never presented as healthy when half-seeded.
- **Workspace template** (`backend/priv/workspace_template/`) contains the full
  brief §4 tree: seed ICM pages (§5: Founder Coaching Package, Email Tone
  Guide, No Medical Advice verbatim; every other page named in the §4 tree gets
  short brief-consistent content),
  the four workflow YAMLs (§6), prompt files, `queue/{pending,approved,rejected,applied}/`,
  `logs/audit.jsonl` (empty), `sources/` including the Priya Nair mock email
  (§18) under `sources/mail/normalized/`, `config/{mail,calendar,harnesses}.yaml`,
  `secrets/.gitkeep`, and the workspace `.gitignore` (ignores `app.sqlite`,
  `secrets/`, `*.log.tmp`, `.agent-runs/`; never ignores `icm/`, `workflows/`,
  `prompts/`, `queue/`, `logs/audit.jsonl`).

## Backend domains (Phase 1)

- **`Valea.ICM`** — tree listing and page read rooted at `{workspace}/icm`.
  Single containment chokepoint: lexical `Path.expand` check validated after
  expansion (legend's Library pattern). Generates `icm://` URIs
  (e.g. `icm://Offers/Founder Coaching Package.md`). The filesystem is the
  source of truth; no DB index in this phase.
- **ICM watcher** — `file_system`-based watcher on `{workspace}/icm`,
  debounced, broadcasting `{:icm_changed}` via PubSub; crashes restart under
  the supervisor.
- **`Valea.Cockpit`** — returns the seeded brief §17 narrative (greeting,
  summary, schedule, prepared items, open loops, while-you-were-away) from a
  hardcoded backend module. Live data replaces it in Phases 3–5; the wiring
  (endpoint → frontend rendering) is real from day one.

### API surface

Plain Phoenix controllers with the uniform `{"error": msg}` envelope:

- `GET  /api/health`
- `GET  /api/workspace` — current workspace or 404-style "no workspace open"
- `POST /api/workspace/create` `{parent_dir, name}`
- `POST /api/workspace/open` `{path}`
- `GET  /api/workspace/recent`
- `GET  /api/icm/tree`
- `GET  /api/icm/page?path=...` — raw markdown + metadata (viewer UI is Phase 2)
- `GET  /api/cockpit/today`

One channel: `workspace:events` — pushes `icm_changed` (frontend refetches the
tree) and `workspace_opened`/`workspace_closed`. Ash stays configured
(deps, repo, JSON:API router wiring ready) but Phase 1 ships zero Ash
resources; the first arrive with the queue (Phase 3).

## Frontend

- **Shell** (brief §11): left sidebar — workspace identity block; Main: Today,
  Mail, Calendar, Chat, Tasks; Assistant: Workflows, Knowledge, Files; System:
  Sources, Audit log; footer: `● All local · synced HH:MM` status line +
  `>_ Open the hood` (placeholder until Phase 3+). The **Knowledge section is
  generated dynamically from the ICM tree** — a folder added on disk appears in
  nav via the watcher/channel refetch.
- **Routes**: `/` → Today cockpit; `/knowledge/[...path]` → page stub showing
  title/path/raw content preview (full viewer/editor is Phase 2); Mail,
  Calendar, Chat, Tasks, Workflows, Files, Sources, Audit log are calm
  empty-state stubs ("coming soon" in Valea's voice, no dead controls).
- **Welcome screen** when no workspace is open: create workspace (Tauri folder
  dialog for parent dir + name), open existing, recent list.
- **Today cockpit**: renders `/api/cockpit/today` — greeting/summary/trust
  statement, schedule list, prepared-item cards (title, summary, used-sources
  chips, primary/secondary action buttons — actions disabled/no-op this phase),
  open loops, while-you-were-away. The prepared-item card is built as the
  reusable component the brief specifies (§11), fed by seed data.
- **Theming**: legend's two-layer token architecture (raw tokens → shadcn
  semantic variable mapping; primitives compose tokens, feature code never uses
  raw classes) with a **new warm light palette** — calm, trustworthy, warm,
  low-hype (brief §20). Risk-level visual system (neutral / amber / red-orange)
  defined as tokens now, used by cards. Dark mode deferred.
- Clients: legend's `api.ts` fetch wrapper + `socket.ts` phoenix client,
  retargeted at the valea endpoints.

## Error handling

- Backend API errors use the `{"error": msg}` envelope; workspace-not-open is a
  distinct error code the frontend maps to the welcome screen.
- Workspace create refuses to scaffold into a non-empty target; open refuses a
  folder without the workspace marker structure; both surface the specific
  reason.
- ICM reads outside the workspace root are rejected at the containment
  chokepoint.
- Watcher or channel loss degrades to manual refresh (nav refetch on rejoin) —
  never a broken UI.

## Testing

- **Backend (ExUnit):** workspace scaffold into tmp dirs (structure + seed
  content assertions), open/validate/close lifecycle, app config read/write,
  ICM tree + containment (escape attempts rejected), controller tests for the
  API surface including no-workspace behavior.
- **Frontend:** vitest for the ICM-tree → nav-model builder and the API client;
  `svelte-check` for types.
- **`just test`** runs both. Desktop packaging verified once via
  `just package-backend` + `just desktop-bundle` smoke run.

## Acceptance (brief Phase 1 "done when")

1. User launches the app with no prior state → welcome screen.
2. Creates a workspace → full seeded tree on disk (ICM pages, workflows,
   prompts, queue dirs, mock email, configs, `.gitignore`).
3. Knowledge nav shows the seeded ICM folders/pages.
4. Today shows the §17 narrative ("Good morning, Mara…", schedule, three
   prepared cards, open loops).
5. Adding a folder under `icm/` on disk updates the Knowledge nav without a
   restart.
6. Relaunching the app reopens the same workspace automatically.

## Out of scope (later sub-projects)

ICM viewer/editor (Phase 2); approval queue + audit log (Phase 3); mail client
(Phase 4); calendar (Phase 5); workflow registry/execution + context bundles +
mock harness runs (Phase 6); AgentHarness abstraction + manual-handoff Claude
Code mode (Phase 7); real Claude Code CLI/ACP integration (Phase 8). The brief's
data models (SourceRef, ApprovalItem, ProposedAction, AuditEvent, AgentHarness
interface) are recorded in the brief and designed in their owning phases.
