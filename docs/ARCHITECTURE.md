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
