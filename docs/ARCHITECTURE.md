# Valea — Architecture

Condensed map of the standing decisions. Full reasoning per feature lives in
[docs/superpowers/specs/](superpowers/specs/); this file states outcomes, not
rationale, and grows with each feature/spec.

## System shape

Three serving modes, one Phoenix app:

```
dev            backend :4200 (mix phx.server)  +  frontend :4273 (vite dev)
dev-desktop    backend :4200                    +  Tauri window (spawns vite dev itself)
production     desktop sidecar :4817 — Phoenix serves the built SPA as static assets
```

- **Backend:** Elixir / Phoenix / Ash, SQLite (AshSqlite). Binds loopback only.
- **Frontend:** SvelteKit static SPA (Svelte 5 runes, no SSR — ever), Bun, Tailwind v4 + shadcn-svelte.
- **Desktop:** Tauri v2. `main.rs` spawns the backend as a Burrito-packaged sidecar binary on the fixed port 4817, polls until reachable, then shows the window; kills the sidecar on exit. Dev builds skip the sidecar entirely.
- Web (non-desktop) release: `just build` bakes the SPA into `backend/priv/static` and produces a standalone Phoenix release.

## Workspace model

The user owns a workspace folder; everything canonical is a readable file inside it. SQLite is cache/index, not source of truth, and it too lives **inside the workspace** (`{workspace}/app.sqlite`) so the folder is fully self-contained and portable.

- **Backend boots workspace-less.** Boot order: Telemetry → `App.Config` → PubSub → `Workspace.Manager` → Endpoint. The Ecto Repo is *not* a static supervision child — there is no database until a workspace is open.
- **App-level config** (`Valea.App.Config`) is a small JSON file in the OS app-data dir (e.g. `~/Library/Application Support/valea/config.json` on macOS): known workspaces (path, name, last-opened-at) + last-opened path. Solves bootstrapping before any workspace exists, without a database.
- **`Valea.Workspace.Manager`** (GenServer) owns the open-workspace lifecycle: `create/2` scaffolds a new workspace from `backend/priv/workspace_template/` and opens it; `open/1` validates the workspace marker structure, starts the Repo under a supervisor pointed at `{path}/app.sqlite`, runs Ecto migrations, starts the ICM file watcher, updates app config, and broadcasts `workspace_opened`. `close/0` and `current/0` round it out. At boot the last-opened workspace reopens automatically if it still exists.
- Migrations run **at workspace open**, in every environment — not at release boot, since the database doesn't exist until a workspace is open.
- Open/create failures are loud and specific; a workspace is never presented as healthy when half-seeded.

## API layer

- **`ash_typescript`**: Ash actions exposed as typed RPC, with a generated TypeScript client (`frontend/src/lib/api/ash_rpc.ts`, committed) giving end-to-end type safety. No AshJsonApi, no hand-maintained client types.
- **Transport: Phoenix channels** (ash_typescript's channel RPC) over one socket, which also carries the realtime `workspace:events` channel (`icm_changed`, `workspace_opened`/`workspace_closed`). HTTP RPC stays available as fallback transport.
- Plain controllers only where RPC doesn't fit — e.g. `GET /api/health` for sidecar port polling from Tauri.
- Codegen is part of the build: `just codegen` runs `mix ash_typescript.codegen`; `just test` fails if the checked-in client is stale.
- Errors follow ash_typescript's structured error shape; the frontend maps a workspace-not-open error to the onboarding screen.

## Design system pointer

UI follows the "paper & ink, with a green pen for approval" design system: [docs/DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) (canonical source: `docs/design/cockpit-design-system-v1.pdf`). Two-layer token architecture (raw tokens → shadcn-svelte semantic variable mapping); feature code never touches raw Tailwind classes directly. Shell layout is a reusable four-column grid (Sidebar · optional ListPane · Main · optional Rail) implemented as an `AppShell` component family on shadcn-svelte primitives.

## Spec index

- [2026-07-09-valea-foundation-design.md](superpowers/specs/2026-07-09-valea-foundation-design.md) — Foundation: monorepo scaffold, workspace creation/selection, app shell, Today cockpit (seeded), ICM tree in nav.
