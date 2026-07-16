# valea

Local-first agentic operating system for solopreneurs — desktop app.

- **Backend:** Elixir / Phoenix / Ash, SQLite — `backend/`
- **Frontend:** SvelteKit (TypeScript) + Bun, Tailwind v4 + shadcn-svelte, static SPA — `frontend/`
- **Desktop:** Tauri v2, backend bundled as a Burrito sidecar binary — `desktop/`

## Prerequisites

- [asdf](https://asdf-vm.com) with elixir + erlang plugins (versions pinned in `.tool-versions`)
- [Bun](https://bun.sh) ≥ 1.3
- [Rust](https://rustup.rs) (for Tauri)
- [just](https://github.com/casey/just)

zig is NOT a prerequisite: `backend/scripts/build-release.sh` auto-provisions the pinned zig (one-time download into `~/.local/zig`) when packaging the desktop sidecar.

## Setup

```bash
asdf install        # toolchain from .tool-versions
just setup          # backend deps + db, frontend deps, desktop deps
```

Create your local backend env file from the committed example (gitignored):

```bash
cp backend/.env.example backend/.env
```

`backend/.env` is loaded by [dotenvy](https://hexdocs.pm/dotenvy) in `config/runtime.exs`; real environment variables override `.env` values. See the comments in `backend/.env.example` for each variable (e.g. the dev `PORT`, default `4200`).

## Development

```bash
just dev            # Phoenix :4200 + Vite :4273 → open http://localhost:4273
just dev-desktop    # Phoenix + Tauri window (Tauri runs the Vite dev server)
just codegen        # regenerate the typed RPC client (frontend/src/lib/api/ash_rpc.ts)
just test           # mix test + svelte-check + frontend tests (fails on a stale RPC client)
```

The backend boots **workspace-less**: there is no database until a workspace is created or opened. A workspace is a hidden, app-owned operational profile (connected accounts, sources, queue, audit log, session transcripts, its own SQLite database `app.sqlite`) — the user never chooses or sees its folder. Everything a user actually authors — ICM pages, workflows, routing — lives in one or more portable ICM folders the workspace mounts **by reference**; those are the folders the user owns and can back up, export, or hand off at any time. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#icm-project-workspaces) for the full model.

## Builds

| Command | Output |
|---|---|
| `just build` | Web release (SPA baked into Phoenix) at `backend/_build/prod/rel/valea` |
| `just package-backend` | Sidecar binary at `desktop/src-tauri/binaries/` |
| `just desktop-bundle` | Desktop app bundle via `tauri build` |

The desktop app spawns the sidecar on the fixed port **4817**, binds loopback only, and shows the window once the backend is reachable. Dev builds skip the sidecar — `just dev-desktop` talks to the backend started by `just` itself.

Note: `cargo check` in `desktop/src-tauri` requires the sidecar binary to exist (tauri-build validates `externalBin`) — run `just package-backend` once after a fresh clone.

## API layer

The frontend talks to the backend through a generated, fully-typed RPC client ([ash_typescript](https://github.com/ash-project/ash_typescript)) transported over Phoenix channels, not hand-written REST calls. Run `just codegen` after changing any Ash action exposed via `typescript_rpc`; `just test` fails if the checked-in client (`frontend/src/lib/api/ash_rpc.ts`) is stale.

## UI components

The frontend uses [shadcn-svelte](https://www.shadcn-svelte.com) (style preset: nova). Add components with:

```bash
cd frontend && bunx shadcn-svelte@latest add <component>
```

## Docs

- [docs/VISION.md](docs/VISION.md) — product vision and principles
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — condensed technical map
- [docs/DESIGN_SYSTEM.md](docs/DESIGN_SYSTEM.md) — "paper & ink" design system
- [docs/superpowers/specs/](docs/superpowers/specs/) — per-feature specs (source of truth for decisions)
