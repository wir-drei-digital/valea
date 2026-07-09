# Valea Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Valea monorepo (backend/frontend/desktop cloned from legend and stripped), with workspace creation/opening, the seeded workspace template, the ash_typescript RPC API over Phoenix channels, the Paper & ink design system, the AppShell, the onboarding screen, the seeded Today cockpit, and the live ICM tree in the Knowledge nav.

**Architecture:** Elixir/Phoenix/Ash backend (sidecar-first, loopback-only) with a workspace-less boot: `Valea.Workspace.Manager` opens a workspace on demand, starting the Repo against `{workspace}/app.sqlite`. All API operations are Ash generic actions on data-layer-less resources exposed via ash_typescript RPC (channel transport primary, HTTP fallback). Frontend is a SvelteKit static SPA (Svelte 5 runes, no SSR) with shadcn-svelte components themed by the Paper & ink token layer.

**Tech Stack:** Elixir 1.20/OTP 27, Phoenix 1.8, Ash 3, AshSqlite, ash_typescript ~> 0.17, file_system, Burrito; SvelteKit 2 + Svelte 5, Bun, Tailwind v4, shadcn-svelte, vitest; Tauri v2.

**Reference documents (read before your task):**
- Spec: `docs/superpowers/specs/2026-07-09-valea-foundation-design.md`
- Design system: `docs/DESIGN_SYSTEM.md` (canonical PDF: `docs/design/cockpit-design-system-v1.pdf`)
- Vision: `docs/VISION.md`
- Legend source (clone donor, read-only): `/Users/daniel/Development/legend`

## Global Constraints

- Namespaces: `Valea.*` / `ValeaWeb.*`; OTP app `:valea`. Never `Legend` anywhere.
- Ports: Phoenix dev **4200**, Vite dev **4273**, desktop sidecar **4817**. Backend binds loopback only.
- No SSR, ever (`adapter-static`, `fallback: 'index.html'`).
- `app.sqlite` lives INSIDE the workspace; the backend boots workspace-less. No static Repo child.
- Canonical data is file-backed; SQLite is cache/index only.
- ash_typescript pinned `~> 0.17`; generated client committed at `frontend/src/lib/api/ash_rpc.ts`; `just test` fails if stale.
- Design tokens: exact hex values from `docs/DESIGN_SYSTEM.md` §2. Fonts bundled locally (fontsource) — never a runtime CDN fetch.
- Nav section label is **Knowledge** (not "Memory").
- UI copy: plain language, no exclamation marks, no emoji, no hype (design system §1/§3 voice rules).
- SQLite via AshSqlite: custom update actions need `require_atomic? false` (none expected in Phase 1).
- The legend repo is READ-ONLY donor material. Never modify anything under `/Users/daniel/Development/legend`.
- Commit after every task (steps include the commit).

---

### Task 1: Backend scaffold — clone, strip, rename

**Files:**
- Create: `backend/` (from legend donor + transformed files below)
- Test: existing Phoenix smoke — `backend/test/valea_web/health_test.exs`

**Interfaces:**
- Produces: compiling `:valea` OTP app; `ValeaWeb.Endpoint` on 4200 (dev); `GET /api/health` → `{"status":"ok"}`; `Valea.Repo` module (NOT started at boot); `Phoenix.PubSub` named `Valea.PubSub`.

- [ ] **Step 1: Copy the donor skeleton**

```bash
cd /Users/daniel/Development/valea
mkdir -p backend
# selective copy — NOT the whole tree
cp /Users/daniel/Development/legend/backend/.formatter.exs backend/
cp /Users/daniel/Development/legend/backend/.gitignore backend/
cp -R /Users/daniel/Development/legend/backend/config backend/config
cp -R /Users/daniel/Development/legend/backend/scripts backend/scripts
mkdir -p backend/lib/valea backend/lib/valea_web/{channels,controllers} \
  backend/priv/repo/migrations backend/priv/static \
  backend/test/support backend/test/valea_web
cp /Users/daniel/Development/legend/backend/lib/legend/repo.ex backend/lib/valea/repo.ex
cp /Users/daniel/Development/legend/backend/lib/legend/release.ex backend/lib/valea/release.ex
cp /Users/daniel/Development/legend/backend/lib/legend_web/endpoint.ex backend/lib/valea_web/endpoint.ex
cp /Users/daniel/Development/legend/backend/lib/legend_web/telemetry.ex backend/lib/valea_web/telemetry.ex
cp /Users/daniel/Development/legend/backend/lib/legend_web/router.ex backend/lib/valea_web/router.ex
cp /Users/daniel/Development/legend/backend/test/test_helper.exs backend/test/ 2>/dev/null || echo 'ExUnit.start()' > backend/test/test_helper.exs
cp /Users/daniel/Development/legend/.tool-versions .tool-versions
cp /Users/daniel/Development/legend/backend/.env.example backend/.env.example 2>/dev/null || true
```

- [ ] **Step 2: Write `backend/mix.exs`** (complete file — do not copy legend's)

```elixir
defmodule Valea.MixProject do
  use Mix.Project

  def project do
    [
      app: :valea,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  defp releases do
    [
      valea: [include_executables_for: [:unix]],
      valea_desktop: [
        include_executables_for: [:unix],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [targets: [macos_arm: [os: :darwin, cpu: :aarch64]]]
      ]
    ]
  end

  def application do
    [
      mod: {Valea.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:ash_sqlite, "~> 0.2"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_typescript, "~> 0.17"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"},
      {:dotenvy, "~> 1.0"},
      {:corsica, "~> 2.1"},
      {:file_system, "~> 1.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.0", runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      lint: ["compile", "credo"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
```

Note: no `ecto.setup` aliases — the DB lives inside a workspace and is migrated
at workspace open (Task 7), so there is no boot-time/db-creation alias.

- [ ] **Step 3: Write `backend/lib/valea/application.ex`** (complete file)

```elixir
defmodule Valea.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ValeaWeb.Telemetry,
      {Phoenix.PubSub, name: Valea.PubSub},
      # Workspace supervisor added in Task 7 (Repo starts under it when a
      # workspace opens — the app boots workspace-less by design).
      ValeaWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Valea.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ValeaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

- [ ] **Step 4: Rename modules and app atoms in every copied file**

In `backend/` (copied files only): replace `Legend` → `Valea`, `LegendWeb` → `ValeaWeb`, `:legend` → `:valea`, `legend` → `valea` (case-sensitive, review each hit — don't blind-sed comments that mention legend-specific features; delete such comments instead).

```bash
cd /Users/daniel/Development/valea/backend
grep -rl 'Legend\|legend' lib config test scripts | xargs sed -i '' \
  -e 's/LegendWeb/ValeaWeb/g' -e 's/Legend/Valea/g' -e 's/legend/valea/g'
grep -rn 'egend' lib config test scripts && echo "LEFTOVERS — fix manually" || echo clean
```

- [ ] **Step 5: Strip legend-specific config and web layer**

Work through each file; the target state is:

- `config/config.exs`: keep endpoint/pubsub/jason/esbuild-free basics; set `config :valea, ash_domains: []` (filled in Task 11); DELETE: `:harnesses`, `:runtimes`, `:tunnels`, `:library_storage` registries, sprites, relay, `ash_json_api` config. Add near the top:
  ```elixir
  config :valea, ecto_repos: [Valea.Repo]
  ```
- `config/dev.exs`: port `4100` → `4200`; DELETE relay ingress endpoint config; keep code reloader. Remove any `Legend.Repo`/database config (the repo has no static database).
- `config/test.exs`: remove repo/database config (tests open tmp workspaces); keep endpoint `server: false`.
- `config/prod.exs`: keep minimal.
- `config/runtime.exs`: rewrite to the minimal dotenvy flow (complete file):
  ```elixir
  import Config
  import Dotenvy

  env_dir = System.get_env("RELEASE_ROOT") || Path.expand(".")
  source!([Path.join(env_dir, ".env"), System.get_env()])

  if System.get_env("PHX_SERVER") do
    config :valea, ValeaWeb.Endpoint, server: true
  end

  if config_env() == :dev do
    config :valea, ValeaWeb.Endpoint, http: [port: env!("PORT", :integer, 4200)]
  end

  if config_env() == :prod do
    port = env!("PORT", :integer, 4817)

    config :valea, ValeaWeb.Endpoint,
      url: [host: "localhost", port: port, scheme: "http"],
      http: [ip: {127, 0, 0, 1}, port: port],
      check_origin: [
        "//localhost",
        "tauri://localhost",
        "http://tauri.localhost",
        "https://tauri.localhost"
      ],
      secret_key_base: env!("SECRET_KEY_BASE", :string)
  end
  ```
- `lib/valea_web/endpoint.ex`: keep sockets/static/parsers plugs; DELETE device-auth/tunnel/relay references. Socket mount stays `socket "/socket", ValeaWeb.UserSocket` (UserSocket arrives in Task 12 — comment the line out until then, with `# enabled in Task 12`).
- `lib/valea_web/router.ex`: replace wholesale (complete file):
  ```elixir
  defmodule ValeaWeb.Router do
    use Phoenix.Router, helpers: false

    pipeline :api do
      plug :accepts, ["json"]
    end

    scope "/api", ValeaWeb do
      pipe_through :api
      get "/health", HealthController, :show
    end

    # ash_typescript RPC routes added in Task 11.

    # SPA catch-all (static build baked into priv/static in `just build`).
    scope "/", ValeaWeb do
      get "/*path", SpaController, :index
    end
  end
  ```
- Create `lib/valea_web/controllers/health_controller.ex`:
  ```elixir
  defmodule ValeaWeb.HealthController do
    use Phoenix.Controller, formats: [:json]

    def show(conn, _params), do: json(conn, %{status: "ok"})
  end
  ```
- Create `lib/valea_web/controllers/spa_controller.ex` (copy legend's SPA catch-all controller if one exists — check `lib/legend_web/controllers/` — otherwise):
  ```elixir
  defmodule ValeaWeb.SpaController do
    use Phoenix.Controller, formats: [:html]

    def index(conn, _params) do
      index = Path.join(Application.app_dir(:valea, "priv/static"), "index.html")

      if File.exists?(index) do
        conn |> put_resp_content_type("text/html") |> send_file(200, index)
      else
        send_resp(conn, 404, "frontend build not present")
      end
    end
  end
  ```
- Create `lib/valea_web.ex` by copying legend's `lib/legend_web.ex` and pruning to the used roles (`:router`, `:controller`, `:channel`, `:verified_routes` if referenced). Rename per Step 4 rules.
- `backend/scripts/build-release.sh`: rename release names `legend`→`valea`, `legend_desktop`→`valea_desktop`.
- Create `backend/.env.example` (complete file):
  ```
  # Phoenix dev port (default 4200)
  # PORT=4200
  ```

- [ ] **Step 6: Write the smoke test** — `backend/test/valea_web/health_test.exs`

```elixir
defmodule ValeaWeb.HealthTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest

  @endpoint ValeaWeb.Endpoint

  test "GET /api/health" do
    conn = get(build_conn(), "/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
```

Also create `backend/test/test_helper.exs` containing exactly:

```elixir
ExUnit.start()
```

- [ ] **Step 7: Compile and run tests**

```bash
cd /Users/daniel/Development/valea/backend
mix deps.get && mix compile --warnings-as-errors
mix test
```
Expected: compile clean; 1 test passes. Fix leftover `Legend` references or missing modules until green.

- [ ] **Step 8: Boot check**

```bash
cd /Users/daniel/Development/valea/backend
mix phx.server &
sleep 5 && curl -s http://localhost:4200/api/health
kill %1
```
Expected: `{"status":"ok"}`.

- [ ] **Step 9: Commit**

```bash
cd /Users/daniel/Development/valea
git add -A && git commit -m "feat(backend): valea backend scaffold from legend (stripped, renamed, port 4200)"
```

---

### Task 2: Frontend scaffold — clone configs, minimal SPA

**Files:**
- Create: `frontend/` (package.json, vite.config.ts, svelte.config.js, tsconfig.json, components.json, src/app.html, src/app.d.ts, src/routes/+layout.ts, src/routes/+layout.svelte, src/routes/layout.css, src/routes/+page.svelte)
- Delete: the old bare template at repo root (`src/`, `src-tauri/`, `static/`, root `package.json`, `svelte.config.js`, `vite.config.js`, `tsconfig.json`, `bun.lock`, `node_modules/`, root `README.md` — replaced by Task 4's README)

**Interfaces:**
- Produces: `bun run dev` serves SPA on :4273 proxying `/api`, `/rpc`, `/socket` → :4200; `bun run check` (svelte-check) and `bun run test` (vitest) pass.

- [ ] **Step 1: Delete the bare template**

```bash
cd /Users/daniel/Development/valea
rm -rf src src-tauri static package.json svelte.config.js vite.config.js tsconfig.json bun.lock node_modules README.md
```

- [ ] **Step 2: Copy legend frontend config files**

```bash
mkdir -p frontend/src/routes frontend/src/lib
cd /Users/daniel/Development/legend/frontend
cp svelte.config.js tsconfig.json components.json /Users/daniel/Development/valea/frontend/
cp src/app.d.ts src/app.html /Users/daniel/Development/valea/frontend/src/
cp vite.config.ts /Users/daniel/Development/valea/frontend/ 2>/dev/null || true
cp src/lib/utils.ts /Users/daniel/Development/valea/frontend/src/lib/
```
Then edit `frontend/vite.config.ts` (write it fully if legend's is missing):

```typescript
import { sveltekit } from '@sveltejs/kit/vite';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [tailwindcss(), sveltekit()],
  server: {
    port: 4273,
    strictPort: true,
    proxy: {
      '/api': 'http://localhost:4200',
      '/rpc': 'http://localhost:4200',
      '/socket': { target: 'ws://localhost:4200', ws: true }
    }
  },
  test: { include: ['src/**/*.test.ts'] }
});
```

- [ ] **Step 3: Write `frontend/package.json`** (complete file; versions float on install)

```json
{
  "name": "frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite dev",
    "build": "vite build",
    "preview": "vite preview",
    "prepare": "svelte-kit sync || echo ''",
    "check": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "@sveltejs/adapter-static": "^3.0.10",
    "@sveltejs/kit": "^2.63.0",
    "@sveltejs/vite-plugin-svelte": "^7.1.2",
    "@tailwindcss/vite": "^4.3.0",
    "@types/node": "^25.9.2",
    "@types/phoenix": "^1.6.7",
    "bits-ui": "^2.16.3",
    "clsx": "^2.1.1",
    "shadcn-svelte": "^1.3.0",
    "svelte": "^5.56.1",
    "svelte-check": "^4.6.0",
    "tailwind-merge": "^3.5.0",
    "tailwind-variants": "^3.2.2",
    "tailwindcss": "^4.3.0",
    "tw-animate-css": "^1.4.0",
    "typescript": "^6.0.3",
    "vite": "^8.0.16",
    "vitest": "^4.1.9"
  },
  "dependencies": {
    "@fontsource-variable/instrument-sans": "^5.0.0",
    "@fontsource-variable/newsreader": "^5.0.0",
    "@fontsource/ibm-plex-mono": "^5.0.0",
    "@tauri-apps/api": "^2.0.0",
    "@tauri-apps/plugin-dialog": "^2.7.1",
    "phoenix": "^1.8.7"
  }
}
```

- [ ] **Step 4: Minimal layout + page**

`frontend/src/routes/+layout.ts`:
```typescript
export const ssr = false;
export const prerender = false;
```

`frontend/src/routes/layout.css` (placeholder until Task 13):
```css
@import 'tailwindcss';
```

`frontend/src/routes/+layout.svelte`:
```svelte
<script lang="ts">
  import './layout.css';
  let { children } = $props();
</script>

{@render children()}
```

`frontend/src/routes/+page.svelte`:
```svelte
<h1>valea</h1>
```

- [ ] **Step 5: Install, check, sanity test**

```bash
cd /Users/daniel/Development/valea/frontend
bun install
bun run check
bun run test || true   # 0 test files is acceptable at this task
bun run build          # verifies adapter-static + fallback works
```
Expected: `check` passes with 0 errors; `build` emits `build/index.html`. If `svelte.config.js` copied from legend references anything missing, prune it (it should only set `adapter-static` with `fallback: 'index.html'` and the `$lib` alias defaults).

- [ ] **Step 6: Commit**

```bash
cd /Users/daniel/Development/valea
git add -A && git commit -m "feat(frontend): sveltekit static SPA scaffold (vite 4273, proxy to 4200)"
```

---

### Task 3: Desktop scaffold — Tauri shell

**Files:**
- Create: `desktop/` — copy from `/Users/daniel/Development/legend/desktop`, then transform.

**Interfaces:**
- Produces: `desktop/` Tauri v2 project targeting sidecar `valea-server` on port **4817**; `bun tauri dev` opens a window against the Vite dev server (dev skips the sidecar, matching legend).

- [ ] **Step 1: Copy and rename**

```bash
cp -R /Users/daniel/Development/legend/desktop /Users/daniel/Development/valea/desktop
cd /Users/daniel/Development/valea/desktop
rm -rf node_modules src-tauri/target src-tauri/binaries
grep -rl 'legend\|Legend' --exclude-dir=node_modules --exclude-dir=target . | xargs sed -i '' \
  -e 's/Legend/Valea/g' -e 's/legend/valea/g'
```

- [ ] **Step 2: Port + identity pass**

- `src-tauri/tauri.conf.json`: `productName: "Valea"`, `identifier: "digital.wirdrei.valea"`, window title "Valea", `externalBin` entry `binaries/valea-server`, devUrl `http://localhost:4273`.
- `src-tauri/src/main.rs`: port constant `4807` → `4817`; sidecar name `valea-server`; app-data dir naming follows the rename. Read the whole file after the sed pass — the sidecar spawn/poll/kill logic stays as legend wrote it (spawn with env: PORT=4817, DATABASE-free — **delete any `DATABASE_PATH` env the legend main.rs passes**; Valea's DB lives in the workspace, and `SECRET_KEY_BASE` persistence stays).
- `desktop/package.json`: name `valea-desktop`.

- [ ] **Step 3: Verify what's verifiable without a sidecar binary**

```bash
cd /Users/daniel/Development/valea/desktop && bun install
cd src-tauri && cargo fmt --check || cargo fmt
```
Note: `cargo check` requires the sidecar binary to exist (tauri-build validates `externalBin`) — that's Task 19. Do not fight it here; create a placeholder so config parses only if tauri-build demands it at `cargo fmt` stage (it shouldn't).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Development/valea
git add -A && git commit -m "feat(desktop): tauri shell for valea (sidecar valea-server, port 4817)"
```

---

### Task 4: Justfile, root README, ARCHITECTURE skeleton

**Files:**
- Create: `Justfile`, `README.md`, `docs/ARCHITECTURE.md`, `.gitignore` (root)

**Interfaces:**
- Produces: `just setup`, `just dev`, `just dev-desktop`, `just test`, `just build`, `just package-backend`, `just desktop-bundle`, `just codegen` recipes used by all later tasks.

- [ ] **Step 1: Write `Justfile`** (complete file)

```make
# valea — dev & build orchestration

default:
    @just --list

# Install all dependencies
setup:
    cd backend && mix setup
    cd frontend && bun install
    cd desktop && bun install

# Backend + frontend dev servers → http://localhost:4273
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd frontend && bun run dev) &
    wait

# Backend + Tauri dev shell (Tauri starts the frontend dev server itself)
dev-desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd desktop && bun tauri dev) &
    wait

# Regenerate the typed RPC client (frontend/src/lib/api/ash_rpc.ts)
codegen:
    cd backend && mix ash_typescript.codegen

# Build the SPA, bake it into Phoenix, assemble the web release
build:
    cd frontend && bun run build
    rm -rf backend/priv/static/_app backend/priv/static/index.html
    cp -R frontend/build/. backend/priv/static/
    backend/scripts/build-release.sh valea

# Package the backend as the desktop sidecar binary
package-backend:
    #!/usr/bin/env bash
    set -euo pipefail
    cd frontend && bun run build
    cd ..
    rm -rf backend/priv/static/_app backend/priv/static/index.html
    cp -R frontend/build/. backend/priv/static/
    backend/scripts/build-release.sh valea_desktop
    triple=$(rustc -vV | sed -n 's/host: //p')
    mkdir -p desktop/src-tauri/binaries
    cp backend/burrito_out/valea_desktop_macos_arm "desktop/src-tauri/binaries/valea-server-${triple}"

# Full desktop bundle
desktop-bundle: package-backend
    cd desktop && bun tauri build

# Run all checks (fails if the generated RPC client is stale)
test:
    cd backend && mix test
    cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/ash_rpc.ts || (echo "STALE GENERATED CLIENT — commit the regenerated ash_rpc.ts" && exit 1)
    cd frontend && bun run check
    cd frontend && bun run test
```

Note: until Task 11 exists, the codegen line in `test` will fail — for Tasks
1–10 run the individual commands (`mix test`, `bun run check`) instead; wire
`just test` into your loop from Task 11 onward.

- [ ] **Step 2: Write root `.gitignore`** (complete file)

```
node_modules/
build/
dist/
_build/
deps/
burrito_out/
*.db
*.db-*
.env
target/
desktop/src-tauri/binaries/
.DS_Store
```

- [ ] **Step 3: Write `README.md`** — mirror legend's README structure (prereqs asdf/bun/rust/just; setup; dev; builds table) with valea names/ports. State: backend on 4200, Vite on 4273, desktop sidecar 4817, DB inside the workspace.

- [ ] **Step 4: Write `docs/ARCHITECTURE.md`** — skeleton with sections: System shape (three serving modes diagram, valea ports), Workspace model (app-level config, workspace-less boot, Manager owns Repo lifecycle), API layer (ash_typescript RPC over channels), Design system pointer, Spec index (link the foundation spec). 30–60 lines; it grows with each feature.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: justfile, README, architecture skeleton, root gitignore"
```

---

### Task 5: Valea.App.Config — app-level config JSON

**Files:**
- Create: `backend/lib/valea/app/config.ex`
- Test: `backend/test/valea/app/config_test.exs`

**Interfaces:**
- Produces:
  - `Valea.App.Config.dir/0` → app config dir (env `VALEA_APP_DIR` override, else `:filename.basedir(:user_data, "valea")`)
  - `Valea.App.Config.read/0` → `%{"known_workspaces" => [%{"path" => p, "name" => n, "last_opened_at" => iso8601}], "last_opened" => path | nil}`
  - `Valea.App.Config.record_opened/2` `(path, name)` → upserts into known list + sets `last_opened`, writes file
  - `Valea.App.Config.clear_last_opened/0`
  - `Valea.App.Config.recent/0` → known workspaces sorted by `last_opened_at` desc, pruned of paths that no longer exist on disk

- [ ] **Step 1: Write the failing tests** — `backend/test/valea/app/config_test.exs`

```elixir
defmodule Valea.App.ConfigTest do
  use ExUnit.Case, async: false

  alias Valea.App.Config

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    on_exit(fn -> System.delete_env("VALEA_APP_DIR") end)
    %{dir: dir}
  end

  test "read returns empty defaults when no file exists" do
    assert Config.read() == %{"known_workspaces" => [], "last_opened" => nil}
  end

  test "record_opened persists and read round-trips", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(ws, "Test Workspace")

    assert %{"last_opened" => ^ws, "known_workspaces" => [entry]} = Config.read()
    assert entry["name"] == "Test Workspace"
    assert entry["path"] == ws
  end

  test "record_opened upserts by path (no duplicates)", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(ws, "A")
    Config.record_opened(ws, "A renamed")
    assert %{"known_workspaces" => [entry]} = Config.read()
    assert entry["name"] == "A renamed"
  end

  test "recent prunes workspaces missing on disk", %{dir: dir} do
    gone = Path.join(dir, "gone")
    File.mkdir_p!(gone)
    Config.record_opened(gone, "Gone")
    File.rm_rf!(gone)
    assert Config.recent() == []
  end

  test "clear_last_opened keeps known list", %{dir: dir} do
    ws = Path.join(dir, "ws1")
    File.mkdir_p!(ws)
    Config.record_opened(ws, "A")
    Config.clear_last_opened()
    assert %{"last_opened" => nil, "known_workspaces" => [_]} = Config.read()
  end

  test "read tolerates corrupt json (returns defaults, does not raise)", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), "{nope")
    assert Config.read() == %{"known_workspaces" => [], "last_opened" => nil}
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/valea/app/config_test.exs`
Expected: FAIL — module `Valea.App.Config` not defined.

- [ ] **Step 3: Implement** — `backend/lib/valea/app/config.ex`

```elixir
defmodule Valea.App.Config do
  @moduledoc """
  App-level (NOT workspace-level) configuration: which workspaces exist and
  which was opened last. A tiny JSON file in the OS user-data dir — this is
  the only state that lives outside a workspace, by design (the app must know
  where workspaces are before any workspace is open).
  """

  @file_name "config.json"
  @defaults %{"known_workspaces" => [], "last_opened" => nil}

  def dir do
    case System.get_env("VALEA_APP_DIR") do
      nil -> :filename.basedir(:user_data, "valea")
      override -> override
    end
  end

  def read do
    with {:ok, raw} <- File.read(Path.join(dir(), @file_name)),
         {:ok, %{} = data} <- Jason.decode(raw) do
      Map.merge(@defaults, Map.take(data, Map.keys(@defaults)))
    else
      _ -> @defaults
    end
  end

  def record_opened(path, name) do
    config = read()
    entry = %{
      "path" => path,
      "name" => name,
      "last_opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    known =
      [entry | Enum.reject(config["known_workspaces"], &(&1["path"] == path))]

    write(%{config | "known_workspaces" => known, "last_opened" => path})
  end

  def clear_last_opened do
    write(%{read() | "last_opened" => nil})
  end

  def recent do
    read()["known_workspaces"]
    |> Enum.filter(&File.dir?(&1["path"]))
    |> Enum.sort_by(& &1["last_opened_at"], :desc)
  end

  defp write(config) do
    File.mkdir_p!(dir())
    path = Path.join(dir(), @file_name)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(config, pretty: true))
    File.rename!(tmp, path)
    :ok
  end
end
```

- [ ] **Step 4: Run tests** — `cd backend && mix test test/valea/app/config_test.exs` — Expected: 6 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(backend): app-level config (known workspaces, last opened)"
```

---

### Task 6: Workspace template + Scaffold

**Files:**
- Create: `backend/priv/workspace_template/**` (full seed tree)
- Create: `backend/lib/valea/workspace/scaffold.ex`
- Test: `backend/test/valea/workspace/scaffold_test.exs`

**Interfaces:**
- Produces:
  - `Valea.Workspace.Scaffold.create(path)` → `:ok | {:error, :target_not_empty | :unwritable}` — copies the template to `path`
  - `Valea.Workspace.Scaffold.valid?(path)` → boolean — workspace marker check (dirs `icm/`, `workflows/`, `queue/`, `logs/` exist)
  - `Valea.Workspace.Scaffold.inspect_summary(path)` → `%{valid: bool, icm_pages: n, workflows: n, queue_pending: n, has_audit_log: bool}` (onboarding "show what's inside")

- [ ] **Step 1: Create the template tree.** Under `backend/priv/workspace_template/` create exactly:

```
icm/Offers/Founder Coaching Package.md      ← brief §5 verbatim (below)
icm/Offers/Discovery Call.md
icm/Pricing/Current Pricing.md
icm/Clients/Lea Brunner.md
icm/Clients/Markus Weber.md
icm/Clients/Julia Steiner.md
icm/Tone & Voice/Email Tone Guide.md        ← brief §5 verbatim (below)
icm/Tone & Voice/Good Reply Examples.md
icm/Policies/No Medical Advice.md           ← brief §5 verbatim (below)
icm/Policies/Payment Terms.md
icm/Policies/Cancellation Policy.md
icm/Templates/Discovery Call Reply.md
icm/Templates/Follow-up Email.md
icm/Decisions/.gitkeep
workflows/new_inquiry_triage.yaml           ← brief §6 verbatim (below)
workflows/session_prep_brief.yaml
workflows/post_session_followup.yaml
workflows/weekly_admin_review.yaml
prompts/inquiry_classifier.md
prompts/reply_writer.md
prompts/session_brief_writer.md
prompts/daily_briefing.md
queue/pending/.gitkeep
queue/approved/.gitkeep
queue/rejected/.gitkeep
queue/applied/.gitkeep
logs/audit.jsonl                            ← empty file
sources/mail/normalized/priya-nair-inquiry.json  ← brief §18 verbatim (below)
sources/mail/drafts/.gitkeep
sources/mail/attachments/.gitkeep
sources/calendar/events/.gitkeep
sources/files/.gitkeep
config/mail.yaml                            ← brief §9 config verbatim
config/calendar.yaml                        ← brief §10 config verbatim
secrets/.gitkeep
gitignore                                   ← renamed to .gitignore on copy (a
                                              literal .gitignore inside priv/
                                              risks tooling ignoring template
                                              files)
```

Verbatim seed contents (from the project brief — copy exactly):

`icm/Offers/Founder Coaching Package.md`:
```markdown
# Founder Coaching Package

A coaching offer for founders and independent professionals who want support with
leadership, prioritization, decision-making, and sustainable work rhythms.

## Best fit
- founders under operational pressure
- solopreneurs with too many open loops
- professionals navigating leadership transitions
- clients looking for reflection and accountability

## Not a fit
- emergency psychological support
- medical or psychiatric advice
- legal or financial advice
- crisis intervention

## Preferred next step
Invite good-fit leads to a discovery call.
Avoid leading with price unless explicitly asked.
```

`icm/Tone & Voice/Email Tone Guide.md`:
```markdown
# Email Tone Guide

Use a tone that is: warm, calm, clear, not pushy, low-hype, respectful of autonomy.

Prefer:
- "If useful, we can start with…"
- "A discovery call would help us see whether this is a fit."
- "No pressure either way."

Avoid:
- aggressive sales language
- overpromising outcomes
- diagnosing psychological or medical conditions
```

`icm/Policies/No Medical Advice.md`:
```markdown
# No Medical Advice

The coaching business does not provide medical, psychiatric, or emergency
psychological support.

In replies, stay within coaching language:
leadership, prioritization, work rhythms, reflection, decision-making, accountability.
```

`workflows/new_inquiry_triage.yaml`:
```yaml
id: new_inquiry_triage
name: New Inquiry Triage
description: Classifies a new email inquiry and drafts a reply for review.
enabled: true
trigger:
  type: manual
  source: email.selected
sources:
  - id: current_email
    type: email
    required: true
  - id: founder_coaching_offer
    type: icm
    path: icm/Offers/Founder Coaching Package.md
  - id: tone_guide
    type: icm
    path: icm/Tone & Voice/Email Tone Guide.md
  - id: no_medical_advice
    type: icm
    path: icm/Policies/No Medical Advice.md
  - id: pricing
    type: icm
    path: icm/Pricing/Current Pricing.md
steps:
  - id: summarize
    instruction: Summarize the incoming inquiry.
  - id: classify
    instruction: >
      Classify whether this is a good-fit coaching inquiry,
      unclear, not fit, or spam.
  - id: draft_reply
    instruction: >
      Draft a warm reply using the tone guide and relevant offer context.
  - id: create_approval_item
    instruction: Create a pending approval item. Do not send.
outputs:
  - type: approval_item
    schema: queue_item
approval:
  required: true
  reason: Email replies must be reviewed before sending.
  actions:
    - create_email_draft
    - send_email
risk_level: medium
audit:
  log_sources: true
  log_inputs: true
  log_outputs: true
  log_agent: true
```

`sources/mail/normalized/priya-nair-inquiry.json`:
```json
{
  "id": "email_priya_nair_inquiry",
  "source": "mock_email",
  "from": { "name": "Priya Nair", "email": "priya@example.com" },
  "to": [{ "name": "Mara Lindt", "email": "mara@example.com" }],
  "subject": "Question about leadership coaching",
  "date": "2026-07-09T06:58:00Z",
  "body_text": "Hi Mara, I found your work through a colleague. I run a small team and have been struggling with prioritization and leadership decisions. Do you offer coaching for this kind of situation? Best, Priya",
  "source_ref": "email://mock/priya-nair-inquiry"
}
```

`gitignore` (template — becomes the workspace's `.gitignore`):
```
app.sqlite
app.sqlite-*
secrets/
*.log.tmp
.agent-runs/
```

`config/mail.yaml` and `config/calendar.yaml`: copy the YAML from brief §9/§10
exactly (account `mara@example.com`, IMAP/SMTP env-var names, folder mapping,
`safety: send_directly: false / create_drafts_only: true`; CalDAV url +
`ics_fallback` + `event_types`).

The three remaining workflow YAMLs (`session_prep_brief`, `post_session_followup`,
`weekly_admin_review`) follow the exact structure of `new_inquiry_triage.yaml`
with: their own `id`/`name`/`description`; triggers `manual` with sources
`calendar.selected` (session prep), `calendar.completed` (follow-up), `schedule.weekly`
(admin review); ICM sources that make sense per workflow (session prep: the
matching client page + templates; follow-up: client page + tone guide; weekly
review: pricing + policies); `risk_level: low` for session_prep_brief, `medium`
for the other two; approval required for the two that draft emails, not for
the prep brief (outputs `prep_brief`).

The non-verbatim ICM pages get short brief-consistent content, e.g.
`icm/Pricing/Current Pricing.md`:
```markdown
# Current Pricing

- Founder Coaching Package: CHF 2,400 for 6 sessions (75 min, every two weeks)
- Discovery call: free, 30 minutes
- Workshop (half-day): CHF 1,900 flat

Avoid leading with price unless explicitly asked.
```
Client pages: name, one-line situation, "Open commitments" list (Lea: pricing
conversation homework, two open commitments from session 2 — matches the
cockpit narrative). Prompts: one paragraph describing the prompt's job.

- [ ] **Step 2: Write the failing tests** — `backend/test/valea/workspace/scaffold_test.exs`

```elixir
defmodule Valea.Workspace.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Valea.Workspace.Scaffold

  defp tmp_target do
    Path.join(System.tmp_dir!(), "valea-ws-#{System.unique_integer([:positive])}")
  end

  test "create scaffolds the full template tree" do
    target = tmp_target()
    assert :ok = Scaffold.create(target)

    for dir <- ~w(icm workflows prompts queue/pending queue/approved queue/rejected queue/applied logs sources/mail/normalized config secrets) do
      assert File.dir?(Path.join(target, dir)), "missing #{dir}"
    end

    assert File.exists?(Path.join(target, "icm/Offers/Founder Coaching Package.md"))
    assert File.exists?(Path.join(target, "workflows/new_inquiry_triage.yaml"))
    assert File.exists?(Path.join(target, "sources/mail/normalized/priya-nair-inquiry.json"))
    assert File.exists?(Path.join(target, "logs/audit.jsonl"))
    assert File.exists?(Path.join(target, ".gitignore"))
    refute File.exists?(Path.join(target, "gitignore"))
  end

  test "create refuses a non-empty target" do
    target = tmp_target()
    File.mkdir_p!(target)
    File.write!(Path.join(target, "existing.txt"), "x")
    assert {:error, :target_not_empty} = Scaffold.create(target)
  end

  test "valid? recognizes a scaffolded workspace and rejects others" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    assert Scaffold.valid?(target)
    refute Scaffold.valid?(System.tmp_dir!())
  end

  test "inspect_summary counts content" do
    target = tmp_target()
    :ok = Scaffold.create(target)
    summary = Scaffold.inspect_summary(target)
    assert summary.valid
    assert summary.icm_pages >= 12
    assert summary.workflows == 4
    assert summary.queue_pending == 0
    assert summary.has_audit_log
  end
end
```

- [ ] **Step 3: Run to verify failure** — `cd backend && mix test test/valea/workspace/scaffold_test.exs` — Expected: FAIL, module undefined.

- [ ] **Step 4: Implement** — `backend/lib/valea/workspace/scaffold.ex`

```elixir
defmodule Valea.Workspace.Scaffold do
  @moduledoc """
  Creates and validates workspace folders from the priv/workspace_template
  seed. The workspace is the user's property: everything here must remain
  plain, readable files.
  """

  @marker_dirs ~w(icm workflows queue logs)

  def template_dir, do: Path.join(:code.priv_dir(:valea), "workspace_template")

  def create(target) do
    cond do
      File.exists?(target) and not empty_dir?(target) -> {:error, :target_not_empty}
      true -> do_create(target)
    end
  end

  def valid?(path) do
    File.dir?(path) and Enum.all?(@marker_dirs, &File.dir?(Path.join(path, &1)))
  end

  def inspect_summary(path) do
    %{
      valid: valid?(path),
      icm_pages: count_files(Path.join(path, "icm"), "**/*.md"),
      workflows: count_files(Path.join(path, "workflows"), "*.yaml"),
      queue_pending: count_files(Path.join(path, "queue/pending"), "*.json"),
      has_audit_log: File.exists?(Path.join(path, "logs/audit.jsonl"))
    }
  end

  defp do_create(target) do
    with :ok <- File.mkdir_p(target),
         {:ok, _} <- File.cp_r(template_dir(), target) do
      # template ships the gitignore un-dotted so tooling never ignores
      # template files; the real workspace gets the dotted name
      File.rename(Path.join(target, "gitignore"), Path.join(target, ".gitignore"))
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  defp empty_dir?(path), do: File.dir?(path) and File.ls!(path) == []

  defp count_files(dir, glob) do
    if File.dir?(dir), do: dir |> Path.join(glob) |> Path.wildcard() |> length(), else: 0
  end
end
```

- [ ] **Step 5: Run tests** — Expected: 4 pass. (If `File.cp_r` errors on the unusual `{:error, reason, file}` shape, match as written above.)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(backend): workspace template (brief seed content) + scaffold module"
```

---

### Task 7: Workspace.Manager — open/create lifecycle, dynamic Repo

**Files:**
- Create: `backend/lib/valea/workspace/manager.ex`, `backend/lib/valea/workspace/supervisor.ex`
- Modify: `backend/lib/valea/application.ex` (add `Valea.Workspace.Supervisor`)
- Test: `backend/test/valea/workspace/manager_test.exs`

**Interfaces:**
- Consumes: `Valea.Workspace.Scaffold` (Task 6), `Valea.App.Config` (Task 5)
- Produces:
  - `Valea.Workspace.Manager.create(parent_dir, name)` → `{:ok, info} | {:error, term}` (scaffold + open)
  - `Valea.Workspace.Manager.open(path)` → `{:ok, info} | {:error, :not_a_workspace | term}`
  - `Valea.Workspace.Manager.close/0` → `:ok`
  - `Valea.Workspace.Manager.current/0` → `{:ok, %{path: p, name: n}} | {:error, :no_workspace}`
  - `info` = `%{path: String.t(), name: String.t()}` (name = folder basename)
  - PubSub topic `"workspace"` events: `{:workspace_opened, info}`, `{:workspace_closed}`
  - At boot: auto-opens `Valea.App.Config.read()["last_opened"]` if it validates.
  - While open: `Valea.Repo` is started (database `{path}/app.sqlite`) and migrated.

- [ ] **Step 1: Write the failing tests** — `backend/test/valea/workspace/manager_test.exs`

```elixir
defmodule Valea.Workspace.ManagerTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    %{parent: Path.join(dir, "workspaces")}
  end

  test "no workspace open by default" do
    assert {:error, :no_workspace} = Manager.current()
  end

  test "create scaffolds, opens, starts repo, records config", %{parent: parent} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    assert {:ok, %{name: "Mara Coaching"} = info} = Manager.create(parent, "Mara Coaching")
    assert {:ok, ^info} = Manager.current()
    assert File.exists?(Path.join(info.path, "app.sqlite"))
    assert Process.whereis(Valea.Repo)
    assert Valea.App.Config.read()["last_opened"] == info.path
    assert_receive {:workspace_opened, ^info}
  end

  test "open rejects a non-workspace folder", %{parent: parent} do
    bogus = Path.join(parent, "bogus")
    File.mkdir_p!(bogus)
    assert {:error, :not_a_workspace} = Manager.open(bogus)
    assert {:error, :no_workspace} = Manager.current()
  end

  test "close stops the repo and clears current", %{parent: parent} do
    {:ok, _} = Manager.create(parent, "W")
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    :ok = Manager.close()
    assert {:error, :no_workspace} = Manager.current()
    refute Process.whereis(Valea.Repo)
    assert_receive {:workspace_closed}
  end

  test "reopen after close works (repo restart)", %{parent: parent} do
    {:ok, info} = Manager.create(parent, "W")
    :ok = Manager.close()
    assert {:ok, ^info} = Manager.open(info.path)
  end
end
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL, `Valea.Workspace.Manager` undefined.

- [ ] **Step 3: Implement supervisor + manager**

`backend/lib/valea/workspace/supervisor.ex`:
```elixir
defmodule Valea.Workspace.Supervisor do
  @moduledoc """
  Owns everything whose lifetime is 'while a workspace is open': the Repo and
  (Task 9) the ICM watcher run under the DynamicSupervisor; the Manager
  decides when they start and stop.
  """
  use Supervisor

  def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: Valea.Workspace.DynamicSupervisor, strategy: :one_for_one},
      Valea.Workspace.Manager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

`backend/lib/valea/workspace/manager.ex`:
```elixir
defmodule Valea.Workspace.Manager do
  @moduledoc """
  The open-workspace lifecycle. The app boots workspace-less; this GenServer
  opens/creates workspaces, starting the Repo against {workspace}/app.sqlite
  and running migrations. Loud, specific failures — a workspace is never
  presented as healthy when half-opened.
  """
  use GenServer

  alias Valea.App.Config
  alias Valea.Workspace.Scaffold

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(parent_dir, name), do: GenServer.call(__MODULE__, {:create, parent_dir, name}, 30_000)
  def open(path), do: GenServer.call(__MODULE__, {:open, path}, 30_000)
  def close, do: GenServer.call(__MODULE__, :close)
  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(_opts) do
    {:ok, %{workspace: nil, children: []}, {:continue, :auto_open}}
  end

  @impl true
  def handle_continue(:auto_open, state) do
    case Config.read()["last_opened"] do
      nil -> {:noreply, state}
      path ->
        case do_open(path, state) do
          {:ok, state} -> {:noreply, state}
          {:error, _reason} ->
            Config.clear_last_opened()
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_call({:create, parent_dir, name}, _from, state) do
    target = Path.join(parent_dir, name)

    with :ok <- Scaffold.create(target),
         {:ok, state} <- do_open(target, state) do
      {:reply, {:ok, state.workspace}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open, path}, _from, state) do
    case do_open(path, state) do
      {:ok, state} -> {:reply, {:ok, state.workspace}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, do_close(state)}
  end

  def handle_call(:current, _from, %{workspace: nil} = state) do
    {:reply, {:error, :no_workspace}, state}
  end

  def handle_call(:current, _from, %{workspace: ws} = state) do
    {:reply, {:ok, ws}, state}
  end

  defp do_open(path, state) do
    path = Path.expand(path)

    cond do
      not Scaffold.valid?(path) ->
        {:error, :not_a_workspace}

      true ->
        state = do_close(state)

        with {:ok, repo_pid} <- start_repo(path),
             :ok <- migrate() do
          info = %{path: path, name: Path.basename(path)}
          Config.record_opened(path, info.name)
          Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_opened, info})
          {:ok, %{state | workspace: info, children: [repo_pid]}}
        end
    end
  end

  defp do_close(%{workspace: nil} = state), do: state

  defp do_close(state) do
    Enum.each(state.children, fn pid ->
      DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, pid)
    end)

    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_closed})
    %{state | workspace: nil, children: []}
  end

  defp start_repo(workspace_path) do
    spec = {Valea.Repo, database: Path.join(workspace_path, "app.sqlite"), pool_size: 5}

    case DynamicSupervisor.start_child(Valea.Workspace.DynamicSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp migrate do
    path = Ecto.Migrator.migrations_path(Valea.Repo)
    Ecto.Migrator.run(Valea.Repo, path, :up, all: true)
    :ok
  rescue
    e -> {:error, {:migration_failed, Exception.message(e)}}
  end
end
```

- [ ] **Step 4: Wire into application.ex** — in `Valea.Application` children, insert `Valea.Workspace.Supervisor` between PubSub and Endpoint.

- [ ] **Step 5: Run tests** — `cd backend && mix test` — Expected: all pass (config, scaffold, manager, health). Watch for: Repo needs `config :valea, Valea.Repo, []` present in `config/config.exs` for `start_link` opts merging — add if `start_repo` raises on missing config.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(backend): workspace manager (workspace-less boot, dynamic repo, migrate on open)"
```

---

### Task 8: Valea.ICM — tree, page read, containment, URIs

**Files:**
- Create: `backend/lib/valea/icm.ex`
- Test: `backend/test/valea/icm_test.exs`

**Interfaces:**
- Consumes: `Valea.Workspace.Manager.current/0`
- Produces:
  - `Valea.ICM.tree/0` → `{:ok, [node]} | {:error, :no_workspace}` where `node` = `%{name: String.t(), path: String.t() (workspace-relative, e.g. "Offers"), type: :folder | :page, children: [node] (folders only), page_count: n (folders), uri: "icm://..." (pages)}` — folders sorted first, then pages, both alphabetically
  - `Valea.ICM.page(rel_path)` → `{:ok, %{path: rel, title: t, uri: u, content: markdown}} | {:error, :not_found | :outside_workspace | :no_workspace}` (title = first `# ` heading or filename sans `.md`)
  - `Valea.ICM.uri(rel_path)` → `"icm://" <> rel_path`

- [ ] **Step 1: Write the failing tests** — `backend/test/valea/icm_test.exs`

```elixir
defmodule Valea.ICMTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager
  alias Valea.ICM

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, _} = Manager.create(Path.join(dir, "workspaces"), "W")

    on_exit(fn ->
      Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    :ok
  end

  test "tree lists seeded folders with counts" do
    {:ok, tree} = ICM.tree()
    names = Enum.map(tree, & &1.name)
    assert "Offers" in names
    assert "Tone & Voice" in names
    offers = Enum.find(tree, &(&1.name == "Offers"))
    assert offers.type == :folder
    assert offers.page_count == 2
    assert Enum.any?(offers.children, &(&1.name == "Founder Coaching Package"))
  end

  test "page reads content with title and uri" do
    {:ok, page} = ICM.page("Offers/Founder Coaching Package.md")
    assert page.title == "Founder Coaching Package"
    assert page.uri == "icm://Offers/Founder Coaching Package.md"
    assert page.content =~ "## Best fit"
  end

  test "page rejects escape attempts" do
    assert {:error, :outside_workspace} = ICM.page("../logs/audit.jsonl")
    assert {:error, :outside_workspace} = ICM.page("Offers/../../secrets/x")
  end

  test "page returns not_found for a missing page" do
    assert {:error, :not_found} = ICM.page("Offers/Nope.md")
  end

  test "errors without a workspace" do
    Manager.close()
    assert {:error, :no_workspace} = ICM.tree()
    assert {:error, :no_workspace} = ICM.page("Offers/Founder Coaching Package.md")
  end
end
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL, `Valea.ICM` undefined.

- [ ] **Step 3: Implement** — `backend/lib/valea/icm.ex`

```elixir
defmodule Valea.ICM do
  @moduledoc """
  Read access to the workspace's icm/ tree — the user's business memory.
  The filesystem is the source of truth. This module is the single
  containment chokepoint for icm reads: every path is expanded and checked
  against the icm root AFTER expansion, so `..` (or a `~`) can never escape.
  """

  alias Valea.Workspace.Manager

  def uri(rel_path), do: "icm://" <> rel_path

  def tree do
    with {:ok, root} <- icm_root() do
      {:ok, build_tree(root, root)}
    end
  end

  def page(rel_path) do
    with {:ok, root} <- icm_root(),
         {:ok, abs} <- contain(root, rel_path) do
      case File.read(abs) do
        {:ok, content} ->
          {:ok,
           %{
             path: rel_path,
             title: title_of(content, abs),
             uri: uri(rel_path),
             content: content
           }}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp icm_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, Path.join(ws, "icm")}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  defp contain(root, rel_path) do
    abs = Path.expand(rel_path, root)

    if String.starts_with?(abs, root <> "/") do
      {:ok, abs}
    else
      {:error, :outside_workspace}
    end
  end

  defp build_tree(dir, root) do
    dir
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.map(&node_for(Path.join(dir, &1), root))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn n -> {if(n.type == :folder, do: 0, else: 1), String.downcase(n.name)} end)
  end

  defp node_for(abs, root) do
    rel = Path.relative_to(abs, root)

    cond do
      File.dir?(abs) ->
        children = build_tree(abs, root)

        %{
          name: Path.basename(abs),
          path: rel,
          type: :folder,
          children: children,
          page_count: count_pages(children)
        }

      Path.extname(abs) == ".md" ->
        %{
          name: Path.basename(abs, ".md"),
          path: rel,
          type: :page,
          uri: uri(rel)
        }

      true ->
        nil
    end
  end

  defp count_pages(children) do
    Enum.reduce(children, 0, fn
      %{type: :page}, acc -> acc + 1
      %{type: :folder, page_count: n}, acc -> acc + n
    end)
  end

  defp title_of(content, abs) do
    content
    |> String.split("\n", parts: 20)
    |> Enum.find_value(fn
      "# " <> title -> String.trim(title)
      _ -> nil
    end) || Path.basename(abs, ".md")
  end
end
```

- [ ] **Step 4: Run tests** — Expected: 5 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(backend): ICM tree/page reads with containment and icm:// URIs"
```

---

### Task 9: ICM file watcher

**Files:**
- Create: `backend/lib/valea/icm/watcher.ex`
- Modify: `backend/lib/valea/workspace/manager.ex` (start/stop watcher with the workspace)
- Test: `backend/test/valea/icm/watcher_test.exs`

**Interfaces:**
- Consumes: workspace open lifecycle (Task 7)
- Produces: PubSub topic `"icm"` message `{:icm_changed}` (debounced ≥ 200ms) whenever anything under `{workspace}/icm` changes.

- [ ] **Step 1: Write the failing test** — `backend/test/valea/icm/watcher_test.exs`

```elixir
defmodule Valea.ICM.WatcherTest do
  use ExUnit.Case, async: false

  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "W")

    on_exit(fn ->
      Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    %{ws: ws}
  end

  test "a new folder under icm/ broadcasts icm_changed", %{ws: ws} do
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    File.mkdir_p!(Path.join(ws.path, "icm/New Folder"))
    assert_receive {:icm_changed}, 3_000
  end

  test "watcher dies with the workspace", %{ws: _ws} do
    Manager.close()
    refute Process.whereis(Valea.ICM.Watcher)
  end
end
```

- [ ] **Step 2: Run to verify failure** — Expected: FAIL (no broadcast / watcher module missing).

- [ ] **Step 3: Implement** — `backend/lib/valea/icm/watcher.ex`

```elixir
defmodule Valea.ICM.Watcher do
  @moduledoc """
  Watches {workspace}/icm and broadcasts a debounced {:icm_changed} on the
  "icm" PubSub topic. Consumers refetch the tree — events carry no payload
  by design (the tree is cheap to rebuild and the fs events are noisy).
  """
  use GenServer

  @debounce_ms 200

  def start_link(icm_path), do: GenServer.start_link(__MODULE__, icm_path, name: __MODULE__)

  @impl true
  def init(icm_path) do
    {:ok, watcher} = FileSystem.start_link(dirs: [icm_path])
    FileSystem.subscribe(watcher)
    {:ok, %{watcher: watcher, timer: nil}}
  end

  @impl true
  def handle_info({:file_event, _pid, {_path, _events}}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :flush, @debounce_ms)}}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:flush, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})
    {:noreply, %{state | timer: nil}}
  end
end
```

- [ ] **Step 4: Start/stop with the workspace.** In `Valea.Workspace.Manager.do_open/2`, after `start_repo`, start the watcher as a second dynamic child and add its pid to `children`:

```elixir
defp start_watcher(workspace_path) do
  spec = {Valea.ICM.Watcher, Path.join(workspace_path, "icm")}

  case DynamicSupervisor.start_child(Valea.Workspace.DynamicSupervisor, spec) do
    {:ok, pid} -> {:ok, pid}
    {:error, {:already_started, pid}} -> {:ok, pid}
    {:error, reason} -> {:error, {:watcher_start_failed, reason}}
  end
end
```

and in `do_open`: `with {:ok, repo_pid} <- start_repo(path), :ok <- migrate(), {:ok, watcher_pid} <- start_watcher(path) do ... children: [repo_pid, watcher_pid]`.

- [ ] **Step 5: Run all backend tests** — `cd backend && mix test` — Expected: green (macOS fsevents can be slow; the 3s assert_receive window covers it).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(backend): debounced icm file watcher broadcasting icm_changed"
```

---

### Task 10: Valea.Cockpit — seeded Today narrative

**Files:**
- Create: `backend/lib/valea/cockpit.ex`
- Test: `backend/test/valea/cockpit_test.exs`

**Interfaces:**
- Produces: `Valea.Cockpit.today/0` → `{:ok, map}` — the brief §17 narrative, string keys ready for JSON. Shape:

```elixir
%{
  "workspace" => "Mara Lindt Coaching",
  "date_label" => "Wednesday, 9 July · 8:31",
  "greeting" => "Good morning, Mara.",
  "summary" =>
    "Two sessions today, one new inquiry, one overdue invoice. I prepared three things overnight — nothing has been sent or changed without your approval.",
  "schedule" => [
    %{"time" => "09:30", "title" => "Admin hour", "subtitle" => "you're in it now", "status" => "current"},
    %{"time" => "11:00", "title" => "Session · Lea Brunner", "subtitle" => "Zoom · 75 min", "status" => "prep_ready"},
    %{"time" => "15:00", "title" => "Deep work", "subtitle" => "no meetings — protected", "status" => nil},
    %{"time" => "16:30", "title" => "Session · Markus Weber", "subtitle" => "in person · Zürich", "status" => "prep_at_14"}
  ],
  "prepared_items" => [ ... exact §17 prepared items: type/title/summary/used_sources/primary_action/secondary_action ... ],
  "open_loops" => [ ... exact §17 open loops: title/source ... ],
  "while_you_were_away" => [ ... exact §17 strings ... ]
}
```

Copy every string **verbatim from brief §17** (they are reproduced in the spec's acceptance section context; the brief text is authoritative — it is quoted in full in the spec's referenced project brief. The three prepared items are Priya Nair reply_drafted, Lea Brunner prep_brief, Julia Steiner follow_up_drafted; four open loops; three while-you-were-away lines).

- [ ] **Step 1: Write the failing test** — `backend/test/valea/cockpit_test.exs`

```elixir
defmodule Valea.CockpitTest do
  use ExUnit.Case, async: true

  test "today returns the seeded narrative" do
    {:ok, today} = Valea.Cockpit.today()
    assert today["greeting"] == "Good morning, Mara."
    assert length(today["schedule"]) == 4
    assert length(today["prepared_items"]) == 3
    assert length(today["open_loops"]) == 4
    assert length(today["while_you_were_away"]) == 3
    [priya | _] = today["prepared_items"]
    assert priya["type"] == "reply_drafted"
    assert priya["title"] == "Priya Nair · new inquiry"
    assert is_list(priya["used_sources"])
  end
end
```

- [ ] **Step 2: Run to verify failure**, **Step 3: Implement** (a module with the literal data; no logic), **Step 4: Run tests** — Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(backend): seeded cockpit today narrative (brief §17)"
```

---

### Task 11: Ash resources + ash_typescript RPC (HTTP) + codegen

**Files:**
- Create: `backend/lib/valea/api.ex` (domain), `backend/lib/valea/api/workspace.ex`, `backend/lib/valea/api/icm.ex`, `backend/lib/valea/api/cockpit.ex`, `backend/lib/valea_web/controllers/rpc_controller.ex`
- Modify: `backend/config/config.exs` (ash_domains + ash_typescript config), `backend/lib/valea_web/router.ex` (RPC routes)
- Create (generated): `frontend/src/lib/api/ash_rpc.ts`
- Test: `backend/test/valea_web/rpc_test.exs`

**Interfaces:**
- Consumes: Manager/Scaffold/ICM/Cockpit (Tasks 5–10)
- Produces:
  - RPC actions (all generic actions, `:map`/`{:array, :map}` returns): `get_workspace` (`:current` — returns `%{"open" => bool, "path" => _, "name" => _}`), `create_workspace(parent_dir, name)`, `open_workspace(path)`, `close_workspace`, `recent_workspaces`, `inspect_workspace(path)`, `icm_tree`, `icm_page(path)`, `cockpit_today`
  - `POST /rpc/run`, `POST /rpc/validate`
  - Generated TS client at `frontend/src/lib/api/ash_rpc.ts` with functions `getWorkspace`, `createWorkspace`, `openWorkspace`, `closeWorkspace`, `recentWorkspaces`, `inspectWorkspace`, `icmTree`, `icmPage`, `cockpitToday`
  - Error convention: workspace-required actions return an Ash error with message `"workspace_not_open"` when no workspace is open — the frontend matches on that string.

- [ ] **Step 1: Configure.** In `backend/config/config.exs`:

```elixir
config :valea, ash_domains: [Valea.Api]

config :ash_typescript,
  output_file: "../frontend/src/lib/api/ash_rpc.ts",
  run_endpoint: "/rpc/run",
  validate_endpoint: "/rpc/validate",
  input_field_formatter: :camel_case,
  output_field_formatter: :camel_case
```

- [ ] **Step 2: Write the failing controller test** — `backend/test/valea_web/rpc_test.exs`

```elixir
defmodule ValeaWeb.RpcTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  @endpoint ValeaWeb.Endpoint

  alias Valea.Workspace.Manager

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()

    on_exit(fn ->
      Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    %{parent: Path.join(dir, "workspaces")}
  end

  defp rpc(action, input) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/run", %{"action" => action, "input" => input, "fields" => []})
    |> json_response(200)
  end

  test "get_workspace reports closed, then open after create_workspace", %{parent: parent} do
    assert %{"success" => true, "data" => %{"open" => false}} = rpc("get_workspace", %{})

    assert %{"success" => true, "data" => %{"open" => true, "name" => "W"}} =
             rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})

    assert %{"success" => true, "data" => %{"open" => true}} = rpc("get_workspace", %{})
  end

  test "icm_tree requires a workspace" do
    assert %{"success" => false, "errors" => errors} = rpc("icm_tree", %{})
    assert inspect(errors) =~ "workspace_not_open"
  end

  test "icm_tree and cockpit_today succeed with a workspace open", %{parent: parent} do
    rpc("create_workspace", %{"parentDir" => parent, "name" => "W"})

    assert %{"success" => true, "data" => %{"nodes" => nodes}} = rpc("icm_tree", %{})
    assert Enum.any?(nodes, &(&1["name"] == "Offers"))

    assert %{"success" => true, "data" => %{"greeting" => "Good morning, Mara."}} =
             rpc("cockpit_today", %{})
  end
end
```

Note: exact request/response envelope may differ slightly by ash_typescript
version (consult the installed version's docs under `deps/ash_typescript/`).
Adjust the test's envelope to the real one — the assertions that matter are:
closed→open flow, the `workspace_not_open` error, seeded tree + greeting.

- [ ] **Step 3: Run to verify failure**, then implement the domain + resources.

`backend/lib/valea/api.ex`:
```elixir
defmodule Valea.Api do
  use Ash.Domain, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Valea.Api.Workspace do
      rpc_action :get_workspace, :current
      rpc_action :create_workspace, :create_workspace
      rpc_action :open_workspace, :open_workspace
      rpc_action :close_workspace, :close_workspace
      rpc_action :recent_workspaces, :recent
      rpc_action :inspect_workspace, :inspect_workspace
    end

    resource Valea.Api.ICM do
      rpc_action :icm_tree, :tree
      rpc_action :icm_page, :page
    end

    resource Valea.Api.Cockpit do
      rpc_action :cockpit_today, :today
    end
  end

  resources do
    resource Valea.Api.Workspace
    resource Valea.Api.ICM
    resource Valea.Api.Cockpit
  end
end
```

`backend/lib/valea/api/workspace.ex` (pattern for all three — data-layer-less resource, generic actions):
```elixir
defmodule Valea.Api.Workspace do
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name "Workspace"
  end

  alias Valea.Workspace.Manager
  alias Valea.Workspace.Scaffold

  actions do
    action :current, :map do
      run fn _input, _ctx ->
        case Manager.current() do
          {:ok, info} -> {:ok, %{"open" => true, "path" => info.path, "name" => info.name}}
          {:error, :no_workspace} -> {:ok, %{"open" => false, "path" => nil, "name" => nil}}
        end
      end
    end

    action :create_workspace, :map do
      argument :parent_dir, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.create(input.arguments.parent_dir, input.arguments.name) do
          {:ok, info} -> {:ok, %{"open" => true, "path" => info.path, "name" => info.name}}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :open_workspace, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Manager.open(input.arguments.path) do
          {:ok, info} -> {:ok, %{"open" => true, "path" => info.path, "name" => info.name}}
          {:error, reason} -> {:error, error_message(reason)}
        end
      end
    end

    action :close_workspace, :map do
      run fn _input, _ctx ->
        :ok = Manager.close()
        {:ok, %{"open" => false}}
      end
    end

    action :recent, {:array, :map} do
      run fn _input, _ctx -> {:ok, Valea.App.Config.recent()} end
    end

    action :inspect_workspace, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        summary = Scaffold.inspect_summary(input.arguments.path)
        {:ok, Map.new(summary, fn {k, v} -> {to_string(k), v} end)}
      end
    end
  end

  defp error_message(:not_a_workspace), do: "not_a_workspace"
  defp error_message(:target_not_empty), do: "target_not_empty"
  defp error_message(other), do: inspect(other)
end
```

`backend/lib/valea/api/icm.ex`:
```elixir
defmodule Valea.Api.ICM do
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name "ICM"
  end

  actions do
    action :tree, :map do
      run fn _input, _ctx ->
        case Valea.ICM.tree() do
          {:ok, nodes} -> {:ok, %{"nodes" => stringify(nodes)}}
          {:error, :no_workspace} -> {:error, "workspace_not_open"}
        end
      end
    end

    action :page, :map do
      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        case Valea.ICM.page(input.arguments.path) do
          {:ok, page} -> {:ok, Map.new(page, fn {k, v} -> {to_string(k), v} end)}
          {:error, :no_workspace} -> {:error, "workspace_not_open"}
          {:error, reason} -> {:error, to_string(reason)}
        end
      end
    end
  end

  defp stringify(nodes) when is_list(nodes), do: Enum.map(nodes, &stringify/1)

  defp stringify(%{} = node) do
    Map.new(node, fn
      {:children, children} -> {"children", stringify(children)}
      {:type, t} -> {"type", to_string(t)}
      {k, v} -> {to_string(k), v}
    end)
  end
end
```

`backend/lib/valea/api/cockpit.ex`:
```elixir
defmodule Valea.Api.Cockpit do
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name "Cockpit"
  end

  actions do
    action :today, :map do
      run fn _input, _ctx ->
        {:ok, today} = Valea.Cockpit.today()
        {:ok, today}
      end
    end
  end
end
```

`backend/lib/valea_web/controllers/rpc_controller.ex`:
```elixir
defmodule ValeaWeb.RpcController do
  use Phoenix.Controller, formats: [:json]

  def run(conn, params) do
    json(conn, AshTypescript.Rpc.run_action(:valea, conn, params))
  end

  def validate(conn, params) do
    json(conn, AshTypescript.Rpc.validate_action(:valea, conn, params))
  end
end
```

Router additions (inside the `/` scope, `:api` pipeline, ABOVE the SPA catch-all):
```elixir
scope "/rpc", ValeaWeb do
  pipe_through :api
  post "/run", RpcController, :run
  post "/validate", RpcController, :validate
end
```

Reality check: ash_typescript's DSL evolves — if `typescript_rpc`/`rpc_action`
or generic-action exposure differs in the installed 0.17.x, read
`deps/ash_typescript/documentation/` and adapt the DSL, keeping the produced
interface (action names, TS function names) EXACTLY as specified above. If
generic actions turn out to be unsupported for RPC in the installed version,
STOP and report back — do not invent a workaround.

- [ ] **Step 4: Run the tests** — `cd backend && mix test test/valea_web/rpc_test.exs` — Expected: 3 pass (after envelope adjustments per the installed version).

- [ ] **Step 5: Generate the client**

```bash
cd backend && mix ash_typescript.codegen
ls ../frontend/src/lib/api/ash_rpc.ts
cd ../frontend && bun run check
```
Expected: file exists; `check` still passes (the generated file typechecks standalone).

- [ ] **Step 6: Full test pass + commit**

```bash
cd /Users/daniel/Development/valea && just test
git add -A && git commit -m "feat(api): ash_typescript RPC surface (workspace/icm/cockpit) + generated client"
```

---

### Task 12: Channel transport + workspace events channel

**Files:**
- Create: `backend/lib/valea_web/channels/user_socket.ex`, `backend/lib/valea_web/channels/rpc_channel.ex`, `backend/lib/valea_web/channels/workspace_events_channel.ex`
- Modify: `backend/lib/valea_web/endpoint.ex` (enable socket mount), `backend/config/config.exs` (channel RPC codegen flag)
- Test: `backend/test/valea_web/channels/workspace_events_test.exs`, `backend/test/valea_web/channels/rpc_channel_test.exs`

**Interfaces:**
- Produces:
  - Socket `/socket` (no auth — loopback app)
  - Channel `ash_typescript_rpc:*` → RPC over channel (generated TS `*Channel` functions)
  - Channel `workspace:events` → pushes `"icm_changed"` `%{}` and `"workspace"` `%{"open" => bool, "name" => n}` on the corresponding PubSub events
  - Config `generate_phx_channel_rpc_actions: true` (regenerates the TS client with channel variants)

- [ ] **Step 1: Write failing channel tests**

`backend/test/valea_web/channels/workspace_events_test.exs`:
```elixir
defmodule ValeaWeb.WorkspaceEventsTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint ValeaWeb.Endpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "valea-app-#{System.unique_integer([:positive])}")
    System.put_env("VALEA_APP_DIR", dir)
    Valea.Workspace.Manager.close()

    on_exit(fn ->
      Valea.Workspace.Manager.close()
      System.delete_env("VALEA_APP_DIR")
    end)

    {:ok, _, socket} =
      socket(ValeaWeb.UserSocket, nil, %{})
      |> subscribe_and_join(ValeaWeb.WorkspaceEventsChannel, "workspace:events")

    %{socket: socket, parent: Path.join(dir, "workspaces")}
  end

  test "workspace open pushes workspace event", %{parent: parent} do
    {:ok, _} = Valea.Workspace.Manager.create(parent, "W")
    assert_push "workspace", %{"open" => true, "name" => "W"}
  end

  test "icm change pushes icm_changed", %{parent: parent} do
    {:ok, ws} = Valea.Workspace.Manager.create(parent, "W")
    File.mkdir_p!(Path.join(ws.path, "icm/Fresh"))
    assert_push "icm_changed", %{}, 3_000
  end
end
```

`backend/test/valea_web/channels/rpc_channel_test.exs`:
```elixir
defmodule ValeaWeb.RpcChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint ValeaWeb.Endpoint

  test "runs an rpc action over the channel" do
    {:ok, _, socket} =
      socket(ValeaWeb.UserSocket, nil, %{})
      |> subscribe_and_join(ValeaWeb.RpcChannel, "ash_typescript_rpc:client")

    ref = push(socket, "run", %{"action" => "cockpit_today", "input" => %{}, "fields" => []})
    assert_reply ref, :ok, reply
    assert reply[:success] || reply["success"]
  end
end
```

- [ ] **Step 2: Run to verify failure**, then implement.

`backend/lib/valea_web/channels/user_socket.ex`:
```elixir
defmodule ValeaWeb.UserSocket do
  use Phoenix.Socket

  channel "ash_typescript_rpc:*", ValeaWeb.RpcChannel
  channel "workspace:events", ValeaWeb.WorkspaceEventsChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
```

`backend/lib/valea_web/channels/rpc_channel.ex`:
```elixir
defmodule ValeaWeb.RpcChannel do
  use Phoenix.Channel

  @impl true
  def join("ash_typescript_rpc:" <> _rest, _payload, socket), do: {:ok, socket}

  @impl true
  def handle_in("run", params, socket) do
    {:reply, {:ok, AshTypescript.Rpc.run_action(:valea, socket, params)}, socket}
  end

  def handle_in("validate", params, socket) do
    {:reply, {:ok, AshTypescript.Rpc.validate_action(:valea, socket, params)}, socket}
  end
end
```

`backend/lib/valea_web/channels/workspace_events_channel.ex`:
```elixir
defmodule ValeaWeb.WorkspaceEventsChannel do
  use Phoenix.Channel

  @impl true
  def join("workspace:events", _payload, socket) do
    Phoenix.PubSub.subscribe(Valea.PubSub, "workspace")
    Phoenix.PubSub.subscribe(Valea.PubSub, "icm")
    {:ok, socket}
  end

  @impl true
  def handle_info({:workspace_opened, info}, socket) do
    push(socket, "workspace", %{"open" => true, "name" => info.name, "path" => info.path})
    {:noreply, socket}
  end

  def handle_info({:workspace_closed}, socket) do
    push(socket, "workspace", %{"open" => false})
    {:noreply, socket}
  end

  def handle_info({:icm_changed}, socket) do
    push(socket, "icm_changed", %{})
    {:noreply, socket}
  end
end
```

Endpoint: uncomment/add `socket "/socket", ValeaWeb.UserSocket, websocket: true, longpoll: false`.

Config addition:
```elixir
config :ash_typescript,
  generate_phx_channel_rpc_actions: true,
  phoenix_import_path: "phoenix"
```

- [ ] **Step 3: Regenerate client + run tests**

```bash
cd backend && mix ash_typescript.codegen && mix test
cd ../frontend && bun run check
```
Expected: channel tests pass; regenerated `ash_rpc.ts` now exports `*Channel` variants; `check` passes.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(api): channel RPC transport + workspace:events channel"
```

---

### Task 13: Design tokens, fonts, shadcn theme (Paper & ink)

**Files:**
- Modify: `frontend/src/routes/layout.css` (complete rewrite), `frontend/src/routes/+layout.svelte` (font imports)
- Create: `frontend/src/lib/components/ui/**` (shadcn-svelte base components via CLI)

**Interfaces:**
- Produces: CSS custom properties for every DESIGN_SYSTEM.md §2 token; shadcn semantic vars mapped onto them; `@theme` Tailwind utilities; font faces `Newsreader` (display), `Instrument Sans` (UI), `IBM Plex Mono` (mono). Utility classes later tasks rely on: `font-display`, `font-mono`, `text-overline` (10.5px/700/+0.09em/uppercase), radius utilities from tokens.

- [ ] **Step 1: Install shadcn base components**

```bash
cd /Users/daniel/Development/valea/frontend
bunx shadcn-svelte@latest add button badge separator scroll-area tooltip dialog input label
```
(components.json was copied from legend in Task 2 — if the CLI complains, run `bunx shadcn-svelte@latest init` first, base color neutral, css `src/routes/layout.css`, alias `$lib/components`.)

- [ ] **Step 2: Rewrite `frontend/src/routes/layout.css`.** Structure (all hex values verbatim from `docs/DESIGN_SYSTEM.md` §2 — every one of the 12 paper, 6 ink, 4 green, 5 amber, 5 terracotta tokens):

```css
@import 'tailwindcss';
@import 'tw-animate-css';

/* ── Raw tokens — Paper & ink (docs/DESIGN_SYSTEM.md is canonical) ── */
:root {
  /* paper */
  --paper-canvas: #e9e3d6;
  --paper-surface: #fbf8f1;
  --paper-card: #fffefa;
  --paper-panel: #f7f2e7;
  --paper-sidebar: #f3eee2;
  --paper-track: #eee8d9;
  --paper-pill: #ece5d2;
  --paper-nav-active: #e7dfca;
  --paper-border: #e6decb;
  --paper-hairline: #efe9da;
  --paper-chip-border: #e0d7c1;
  --paper-button-border: #d8cfb9;
  /* ink */
  --ink-heading: #29251e;
  --ink-body: #3d3b30;
  --ink-secondary: #57503f;
  --ink-subtitle: #6e6656;
  --ink-meta: #948a75;
  --ink-overline: #a89085;
  /* green — acts */
  --act: #2f5d48;
  --act-hover: #244938;
  --act-tint: #e6ede2;
  --act-dot: #2f8a5b;
  /* amber — suggests */
  --suggest-ink: #8f6e1f;
  --suggest-dash: #c9a24b;
  --suggest-tint: #f4e8d2;
  --suggest-bg: #f9f2e3;
  --suggest-border: #e8d9b5;
  /* terracotta — warns */
  --warn-ink: #b4512e;
  --warn-dot: #c0793f;
  --warn-tint: #f6e7de;
  --warn-border: #ebd5c6;
  --warn-checkbox: #e0bda9;

  /* ── shadcn semantic mapping (the seam) ── */
  --background: var(--paper-surface);
  --foreground: var(--ink-body);
  --card: var(--paper-card);
  --card-foreground: var(--ink-body);
  --popover: var(--paper-card);
  --popover-foreground: var(--ink-body);
  --primary: var(--act);
  --primary-foreground: #fffefa;
  --secondary: var(--paper-pill);
  --secondary-foreground: var(--ink-secondary);
  --muted: var(--paper-track);
  --muted-foreground: var(--ink-meta);
  --accent: var(--paper-nav-active);
  --accent-foreground: var(--ink-heading);
  --destructive: var(--warn-ink);
  --destructive-foreground: #fffefa;
  --border: var(--paper-border);
  --input: var(--paper-button-border);
  --ring: var(--act);
  --radius: 0.75rem; /* 12px cards */
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-card: var(--card);
  --color-card-foreground: var(--card-foreground);
  --color-popover: var(--popover);
  --color-popover-foreground: var(--popover-foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  --color-secondary: var(--secondary);
  --color-secondary-foreground: var(--secondary-foreground);
  --color-muted: var(--muted);
  --color-muted-foreground: var(--muted-foreground);
  --color-accent: var(--accent);
  --color-accent-foreground: var(--accent-foreground);
  --color-destructive: var(--destructive);
  --color-border: var(--border);
  --color-input: var(--input);
  --color-ring: var(--ring);
  /* raw palettes as tailwind colors: bg-paper-card, text-ink-meta, ... */
  --color-paper-canvas: var(--paper-canvas);
  --color-paper-surface: var(--paper-surface);
  --color-paper-card: var(--paper-card);
  --color-paper-panel: var(--paper-panel);
  --color-paper-sidebar: var(--paper-sidebar);
  --color-paper-track: var(--paper-track);
  --color-paper-pill: var(--paper-pill);
  --color-paper-nav-active: var(--paper-nav-active);
  --color-paper-border: var(--paper-border);
  --color-paper-hairline: var(--paper-hairline);
  --color-paper-chip-border: var(--paper-chip-border);
  --color-paper-button-border: var(--paper-button-border);
  --color-ink-heading: var(--ink-heading);
  --color-ink-body: var(--ink-body);
  --color-ink-secondary: var(--ink-secondary);
  --color-ink-subtitle: var(--ink-subtitle);
  --color-ink-meta: var(--ink-meta);
  --color-ink-overline: var(--ink-overline);
  --color-act: var(--act);
  --color-act-hover: var(--act-hover);
  --color-act-tint: var(--act-tint);
  --color-act-dot: var(--act-dot);
  --color-suggest-ink: var(--suggest-ink);
  --color-suggest-dash: var(--suggest-dash);
  --color-suggest-tint: var(--suggest-tint);
  --color-suggest-bg: var(--suggest-bg);
  --color-suggest-border: var(--suggest-border);
  --color-warn-ink: var(--warn-ink);
  --color-warn-dot: var(--warn-dot);
  --color-warn-tint: var(--warn-tint);
  --color-warn-border: var(--warn-border);
  --color-warn-checkbox: var(--warn-checkbox);
  /* type */
  --font-display: 'Newsreader Variable', georgia, serif;
  --font-sans: 'Instrument Sans Variable', system-ui, sans-serif;
  --font-mono: 'IBM Plex Mono', ui-monospace, monospace;
  /* shadows (design system geometry) */
  --shadow-card: 0 1px 2px rgba(42, 38, 32, 0.05);
  --shadow-window: 0 24px 60px rgba(42, 38, 32, 0.28);
}

@layer base {
  body {
    background: var(--paper-surface);
    color: var(--ink-body);
    font-family: var(--font-sans);
    font-size: 13.5px;
    line-height: 1.5;
  }
}

@utility text-overline {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: var(--ink-overline);
}
```

- [ ] **Step 3: Fonts in `+layout.svelte`**

```svelte
<script lang="ts">
  import '@fontsource-variable/newsreader';
  import '@fontsource-variable/instrument-sans';
  import '@fontsource/ibm-plex-mono/400.css';
  import '@fontsource/ibm-plex-mono/500.css';
  import './layout.css';
  let { children } = $props();
</script>

{@render children()}
```
If a fontsource package name 404s on install, check the registry (`bun add @fontsource-variable/newsreader` etc.) and use the closest official fontsource package (static `@fontsource/newsreader` acceptable fallback); update the CSS family names to the package's documented family string.

- [ ] **Step 4: Sanity page.** Temporarily set `+page.svelte` to render one specimen of each: display greeting, body copy, overline, mono path, primary/secondary/danger button, three badges (act/suggest/warn tints). Run `bun run dev` and eyeball against `docs/design/cockpit-design-system-v1.pdf` p.1. Then `bun run check`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(frontend): paper & ink design tokens, fonts, shadcn semantic mapping"
```

---

### Task 14: AppShell component family

**Files:**
- Create: `frontend/src/lib/components/shell/AppShell.svelte`, `Sidebar.svelte`, `SidebarItem.svelte`, `IcmTree.svelte`, `ListPane.svelte`, `Rail.svelte`, `StatusPill.svelte`, `SectionOverline.svelte`, `index.ts`
- Create: `frontend/src/lib/shell/nav.ts` + Test: `frontend/src/lib/shell/nav.test.ts`

**Interfaces:**
- Consumes: design tokens (Task 13); ICM tree node type from the generated client (Task 11) — import type from `$lib/api/ash_rpc` if exported; otherwise define `IcmNode` in `nav.ts`: `{ name: string; path: string; type: 'folder' | 'page'; children?: IcmNode[]; pageCount?: number; uri?: string }`
- Produces:
  - `AppShell` — props `{ sidebar, list?, main, rail? }` snippets; grid: sidebar 236px fixed, list pane 250–340px (resizable via shadcn Resizable), main flexible with content `max-w-[660px]`, rail 290–340px; panes use Scroll Area.
  - `Sidebar` — workspace identity header (initials avatar + name + "Local workspace"), grouped items (SectionOverline per group: no label for Daily, `ASSISTANT`, `SYSTEM`), `IcmTree` under the Knowledge item, footer = `StatusPill` + `>_ Open the hood` mono row (design system §7 metrics: item 13.5px label, active `bg-paper-nav-active` + 600 weight, idle `text-ink-secondary`, hover `bg-paper-pill`; tree indent 17px behind 1px `paper-chip-border` guide line, 12.5px rows, right-aligned page counts).
  - `nav.ts` — `mainNav()` returns the static section model `[{ label: null, items: [today, mail, calendar, chat, tasks] }, { label: 'Assistant', items: [workflows, knowledge, files] }, { label: 'System', items: [sources, audit] }]` each item `{ id, label, href, icon }`; `icmToNav(nodes: IcmNode[]): NavTreeItem[]` maps ICM folders/pages to `{ label, href: '/knowledge/' + encodePath(path), children, count }` with `encodePath` = encodeURIComponent per segment, preserving `/`.

- [ ] **Step 1: Write failing vitest for nav model** — `frontend/src/lib/shell/nav.test.ts`

```typescript
import { describe, expect, it } from 'vitest';
import { icmToNav, encodePath, type IcmNode } from './nav';

const tree: IcmNode[] = [
  {
    name: 'Tone & Voice',
    path: 'Tone & Voice',
    type: 'folder',
    pageCount: 2,
    children: [
      { name: 'Email Tone Guide', path: 'Tone & Voice/Email Tone Guide.md', type: 'page', uri: 'icm://Tone & Voice/Email Tone Guide.md' }
    ]
  }
];

describe('icmToNav', () => {
  it('maps folders with counts and encoded hrefs', () => {
    const nav = icmToNav(tree);
    expect(nav[0].label).toBe('Tone & Voice');
    expect(nav[0].count).toBe(2);
    expect(nav[0].children?.[0].href).toBe('/knowledge/Tone%20%26%20Voice/Email%20Tone%20Guide.md');
  });
});

describe('encodePath', () => {
  it('encodes segments but keeps separators', () => {
    expect(encodePath('A B/C&D.md')).toBe('A%20B/C%26D.md');
  });
});
```

- [ ] **Step 2: Run to verify failure** (`bun run test`), **Step 3: Implement `nav.ts`**

```typescript
export type IcmNode = {
  name: string;
  path: string;
  type: 'folder' | 'page';
  children?: IcmNode[];
  pageCount?: number;
  uri?: string;
};

export type NavItem = { id: string; label: string; href: string };
export type NavSection = { label: string | null; items: NavItem[] };
export type NavTreeItem = { label: string; href: string; count?: number; children?: NavTreeItem[] };

export function mainNav(): NavSection[] {
  return [
    {
      label: null,
      items: [
        { id: 'today', label: 'Today', href: '/' },
        { id: 'mail', label: 'Mail', href: '/mail' },
        { id: 'calendar', label: 'Calendar', href: '/calendar' },
        { id: 'chat', label: 'Chat', href: '/chat' },
        { id: 'tasks', label: 'Tasks', href: '/tasks' }
      ]
    },
    {
      label: 'Assistant',
      items: [
        { id: 'workflows', label: 'Workflows', href: '/workflows' },
        { id: 'knowledge', label: 'Knowledge', href: '/knowledge' },
        { id: 'files', label: 'Files', href: '/files' }
      ]
    },
    {
      label: 'System',
      items: [
        { id: 'sources', label: 'Sources', href: '/sources' },
        { id: 'audit', label: 'Audit log', href: '/audit' }
      ]
    }
  ];
}

export function encodePath(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/');
}

export function icmToNav(nodes: IcmNode[]): NavTreeItem[] {
  return nodes.map((n) =>
    n.type === 'folder'
      ? {
          label: n.name,
          href: `/knowledge/${encodePath(n.path)}`,
          count: n.pageCount,
          children: icmToNav(n.children ?? [])
        }
      : { label: n.name, href: `/knowledge/${encodePath(n.path)}` }
  );
}
```

- [ ] **Step 4: Run test** — Expected: PASS.

- [ ] **Step 5: Build the components.** Follow the design system §7 metrics precisely. Component sketches (fill in with token classes; keep each file small):

`AppShell.svelte`:
```svelte
<script lang="ts">
  import type { Snippet } from 'svelte';
  let { sidebar, list, main, rail }: {
    sidebar: Snippet; list?: Snippet; main: Snippet; rail?: Snippet;
  } = $props();
</script>

<div class="flex h-screen bg-paper-surface text-ink-body">
  <aside class="w-[236px] shrink-0 border-r border-paper-hairline bg-paper-sidebar">
    {@render sidebar()}
  </aside>
  {#if list}
    <section class="w-[300px] min-w-[250px] max-w-[340px] shrink-0 border-r border-paper-hairline bg-paper-panel overflow-y-auto">
      {@render list()}
    </section>
  {/if}
  <main class="min-w-0 flex-1 overflow-y-auto">
    <div class="mx-auto max-w-[660px] px-8 py-8">
      {@render main()}
    </div>
  </main>
  {#if rail}
    <aside class="w-[320px] min-w-[290px] max-w-[340px] shrink-0 border-l border-paper-hairline bg-paper-panel overflow-y-auto">
      {@render rail()}
    </aside>
  {/if}
</div>
```
(Resizable upgrade of the list pane is welcome if shadcn Resizable composes cleanly; fixed 300px is acceptable for Phase 1 — note whichever you ship in the component comment.)

`Sidebar.svelte` — props `{ workspaceName: string; icmNav: NavTreeItem[]; syncedAt?: string }`; renders identity block, `mainNav()` sections with `SidebarItem` (active = `page.url.pathname` match), `IcmTree` nested under the Knowledge item, and the footer:
```svelte
<footer class="mt-auto px-3 pb-3">
  <StatusPill label={syncedAt ? `All local · synced ${syncedAt}` : 'All local'} />
  <button class="font-mono text-[11.5px] text-ink-meta px-2 py-2 hover:text-ink-secondary" disabled>
    &gt;_ Open the hood
  </button>
</footer>
```
("Open the hood" is a disabled placeholder this phase — tooltip "Coming with the audit log".)

`IcmTree.svelte` — recursive over `NavTreeItem[]`: folders as disclosure rows (12.5px, count right-aligned in `text-ink-meta`), pages as links; children container `class="ml-[17px] border-l border-paper-chip-border pl-2"`.

`ListPane.svelte` — snippets `{ header, filter?, children, footer? }`, header row + Scroll Area body.

`Rail.svelte` — Newsreader title prop + children snippet.

`StatusPill.svelte` — `bg-paper-pill` 999px pill, `--act-dot` green dot, 11.5px label.

`SectionOverline.svelte` — `<div class="text-overline px-2 pt-4 pb-1">{label}</div>`.

`index.ts` — re-export all.

- [ ] **Step 6: Verify** — `bun run check && bun run test` — Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(frontend): AppShell family (sidebar 236, list pane, rail) per design system"
```

---

### Task 15: API client integration, socket, workspace store

**Files:**
- Create: `frontend/src/lib/api/client.ts`, `frontend/src/lib/socket.ts` (adapt legend's `frontend/src/lib/socket.ts`), `frontend/src/lib/stores/workspace.svelte.ts`, `frontend/src/lib/stores/icm.svelte.ts`
- Test: `frontend/src/lib/stores/workspace.test.ts`

**Interfaces:**
- Consumes: generated `$lib/api/ash_rpc` (Tasks 11–12), `nav.ts` types (Task 14)
- Produces:
  - `client.ts` — thin wrappers choosing channel transport with HTTP fallback: `api.getWorkspace()`, `api.createWorkspace(parentDir, name)`, `api.openWorkspace(path)`, `api.recentWorkspaces()`, `api.inspectWorkspace(path)`, `api.icmTree()`, `api.icmPage(path)`, `api.cockpitToday()` — each returns `{ ok: true, data } | { ok: false, error: string }` (never throws; `workspace_not_open` surfaced as the error string)
  - `socket.ts` — `connectSocket()` singleton Phoenix socket at `/socket`; `joinWorkspaceEvents(handlers: { onWorkspace?, onIcmChanged? })`
  - `workspace.svelte.ts` — `workspaceStore` runes class: `state: 'loading' | 'none' | 'open'`, `name`, `path`, `recent`, methods `refresh()`, `create()`, `open()`; drives onboarding-vs-app in the root layout
  - `icm.svelte.ts` — `icmStore`: `nodes: IcmNode[]`, `refetch()`; subscribes to `icm_changed`

- [ ] **Step 1: Failing test for store state machine** — `frontend/src/lib/stores/workspace.test.ts` (pure logic: inject a fake api)

```typescript
import { describe, expect, it } from 'vitest';
import { WorkspaceStore } from './workspace.svelte';

const fakeApi = (open: boolean) => ({
  getWorkspace: async () => ({ ok: true as const, data: { open, name: open ? 'W' : null, path: open ? '/w' : null } }),
  recentWorkspaces: async () => ({ ok: true as const, data: [] })
});

describe('WorkspaceStore', () => {
  it('starts loading, resolves to none when closed', async () => {
    const store = new WorkspaceStore(fakeApi(false) as never);
    expect(store.state).toBe('loading');
    await store.refresh();
    expect(store.state).toBe('none');
  });

  it('resolves to open with name', async () => {
    const store = new WorkspaceStore(fakeApi(true) as never);
    await store.refresh();
    expect(store.state).toBe('open');
    expect(store.name).toBe('W');
  });
});
```

- [ ] **Step 2: Run to verify failure**, **Step 3: Implement** the four files. `client.ts` wraps generated functions; on channel unavailability (socket not connected) it calls the HTTP variants. Keep transport choice inside `client.ts` — nothing else may import `ash_rpc` directly (grep-able boundary).

- [ ] **Step 4: `bun run test && bun run check`** — Expected: green.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(frontend): api client (channel+http), socket, workspace/icm stores"
```

---

### Task 16: Onboarding screen

**Files:**
- Create: `frontend/src/lib/components/onboarding/Onboarding.svelte`, `CreateWorkspaceDialog.svelte`, `OpenWorkspaceFlow.svelte`, `TrustBar.svelte`, `WhatsInAWorkspace.svelte`
- Modify: `frontend/src/routes/+layout.svelte` (workspaceStore gate: loading → spinner; none → Onboarding; open → AppShell + page)

**Interfaces:**
- Consumes: `workspaceStore` (Task 15), tokens (Task 13), shadcn Dialog/Button/Input
- Produces: the onboarding screen per the 2026-07-09 mockup + spec: centered folder glyph, Newsreader H1 "Welcome. Your business runs on a folder you own.", subtitle, two cards, trust bar, mono `>_ What's in a workspace?` bottom-right opening an explainer dialog.

Card behaviors (spec-decided):
- **Start fresh** (white card, overline `START FRESH · MOST PEOPLE BEGIN HERE` in green): title "Set it up in conversation", body + 3 numbered rows as in the mockup; primary button **"Start the conversation"** opens `CreateWorkspaceDialog` (the guided fallback until chat exists): fields = workspace name (default "My business"), parent folder (Tauri dialog `open({ directory: true })` when `window.__TAURI_INTERNALS__` exists, else a plain text input) → calls `workspaceStore.create()` → on success the layout gate flips to the app. Caption right of button: "nothing connects without asking you".
- **Continue** (panel-tinted card, overline `CONTINUE · FROM A HANDOFF OR BACKUP`): title "Open an existing workspace", dashed drop zone listing mono `icm/ · workflows/ · queue/ · logs/`; "Choose folder…" secondary button → folder pick → `api.inspectWorkspace(path)` → render summary ("14 memory pages · 4 workflows · 0 pending approvals · audit log present") with Open/Cancel → `workspaceStore.open(path)`. Invalid folder → calm inline error "This folder doesn't look like a Valea workspace." Caption: "also restores from a git remote" struck through or omitted — omitted (deferred feature; never show dead UI).
- **TrustBar**: three items with icons (green dot / lock / folder): "Runs on this Mac — nothing leaves it during setup", "Your keys stay in the system keychain", "Export or walk away with the folder anytime".

- [ ] **Step 1: Build the components** (visual work — follow mockup card anatomy; overlines via `text-overline` with green override for the fresh card).
- [ ] **Step 2: Layout gate in `+layout.svelte`** — `onMount(() => workspaceStore.refresh())`; render `{#if workspaceStore.state === 'none'}<Onboarding/>{:else if ...}`.
- [ ] **Step 3: Manual verification** — `just dev` with no `VALEA_APP_DIR` state: onboarding renders; create a workspace into a tmp folder; app shell appears with seeded Knowledge tree. Then `bun run check`.
- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(frontend): onboarding (two-card welcome, guided create, open with inspection)"
```

---

### Task 17: Today cockpit page

**Files:**
- Create: `frontend/src/lib/components/today/PreparedItemCard.svelte`, `ScheduleList.svelte`, `OpenLoops.svelte`, `AwayList.svelte`, `SourceChips.svelte`
- Modify: `frontend/src/routes/+page.svelte` (the Today page)

**Interfaces:**
- Consumes: `api.cockpitToday()` (Task 15), AppShell (Task 14), tokens
- Produces: the Today page rendering the seeded narrative: page header (overline `WEDNESDAY, 9 JULY · 8:31` → Newsreader "Good morning, Mara." 32–40 → summary line with the trust sentence bold: "**nothing has been sent or changed without your approval.**"); two-column content: left `TODAY'S SCHEDULE` overline + `ScheduleList`; right/main `PREPARED FOR YOU · 3` + three `PreparedItemCard`s; below: `OPEN LOOPS` via `OpenLoops` checklist rows + `WHILE YOU WERE AWAY` receipts via `AwayList`.

`PreparedItemCard` (reusable — the approval-card anatomy from design system §6): props `{ item: PreparedItem }` where `PreparedItem = { type: string; title: string; summary: string; usedSources: string[]; primaryAction: string; secondaryAction?: string }`; renders kind badge (type → label/tint map: `reply_drafted` → `REPLY DRAFTED` green tint, `prep_brief` → `PREP BRIEF` neutral, `follow_up_drafted` → `FOLLOW-UP DRAFTED` green tint), title 650, summary body, `SourceChips` ("Used: " + chips with source dots), actions row (primary green fill, secondary outline — **no-op `console.info` handlers this phase**, visually real), "Why this? →" link bottom-right (opens a Dialog listing the used sources — satisfies acceptance step 7).

`ScheduleList`: time column (mono 11.5px `text-ink-meta`), 3px left bar `--act` for real events, status chips (`Prep ready` act-tint badge; `prep_at_14` renders "Prep at 14:00" neutral badge; `current` renders "you're in it now" subtitle emphasis).

- [ ] **Step 1: Build components + page wiring** — fetch on mount via `api.cockpitToday()`, render states: loading skeleton, error (calm inline message), data.
- [ ] **Step 2: Manual verification against the Today mockup** (`just dev`, workspace open): header, schedule, three cards with sources, open loops, away list. Check typography roles (serif greeting, sans body, mono times) and the §6 card anatomy (badge → title → summary → chips → actions, "Why this?" bottom-right).
- [ ] **Step 3: `bun run check`** — Expected: clean.
- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(frontend): seeded Today cockpit (header, schedule, prepared cards, open loops)"
```

---

### Task 18: Knowledge routes, live ICM nav, stub pages

**Files:**
- Create: `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte`
- Create: `frontend/src/routes/(stubs)/mail/+page.svelte` and same-pattern stubs: `calendar`, `chat`, `tasks`, `workflows`, `files`, `sources`, `audit`
- Create: `frontend/src/lib/components/shell/EmptyState.svelte`
- Modify: `frontend/src/routes/+layout.svelte` (Sidebar gets `icmStore` nav + joins `workspace:events` for live refetch)

**Interfaces:**
- Consumes: `icmStore` + `joinWorkspaceEvents` (Task 15), `icmToNav` (Task 14), `api.icmPage` (Task 15), ListPane (Task 14)
- Produces:
  - Sidebar Knowledge tree live-updates when `icm_changed` arrives (acceptance step: add folder on disk → nav updates without restart).
  - `/knowledge` — ListPane exercise: pane lists top-level ICM folders with counts; main shows a calm intro ("Your business memory — every page is a plain Markdown file in your workspace.").
  - `/knowledge/[...path]` — folder path → ListPane lists that folder's pages, main prompts to pick a page; page path → main renders breadcrumb (mono file path `icm/<path>` per ownership-signature rule), Newsreader title, raw markdown content in a readable `<pre class="whitespace-pre-wrap">` (real viewer is Phase 2), and the ownership card (`bg-paper-pill`): "This folder is yours — plain files. Export or hand it over anytime."
  - `EmptyState` — icon + one Newsreader line + one body line, no dead buttons; stubs use copy in Valea's voice, e.g. Mail: "Mail arrives in a later step. Your inbox will connect over IMAP — drafts only, nothing sends without you."

- [ ] **Step 1: Wire live nav.** In the layout (workspace-open branch): `icmStore.refetch()` on mount and on `icm_changed` (via `joinWorkspaceEvents({ onIcmChanged: () => icmStore.refetch() })`); pass `icmToNav(icmStore.nodes)` into `Sidebar`.
- [ ] **Step 2: Build routes + stubs** as specified.
- [ ] **Step 3: Manual verification** — `just dev`: click through every nav item (no console errors, calm stubs); open a Knowledge page (content renders, mono breadcrumb correct); `mkdir "…workspace/icm/Fresh Folder"` → tree updates within ~1s without reload.
- [ ] **Step 4: `bun run check && bun run test`** — Expected: clean.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(frontend): knowledge routes with live icm nav + calm stub pages"
```

---

### Task 19: Desktop packaging + acceptance walkthrough

**Files:**
- Modify: `docs/ARCHITECTURE.md` (fill in what shipped), `README.md` (correct any drift)

**Interfaces:**
- Consumes: everything.
- Produces: a verified end-to-end foundation.

- [ ] **Step 1: Full check suite** — `just test` — Expected: backend green, codegen fresh, svelte-check clean, vitest green.
- [ ] **Step 2: Package the sidecar** — `just package-backend` — Expected: `desktop/src-tauri/binaries/valea-server-<triple>` exists. Then `cd desktop/src-tauri && cargo check` — Expected: compiles (externalBin now present).
- [ ] **Step 3: Desktop smoke** — `just dev-desktop` — window opens against dev servers; onboarding or workspace shows. (Full bundled-app run via `just desktop-bundle` is optional here — heavy; do it if time allows.)
- [ ] **Step 4: Acceptance walkthrough (spec "done when")** — perform and check each:
  1. Fresh state (unset `VALEA_APP_DIR`, move any real app-data config aside) → onboarding screen with both cards + trust bar.
  2. Create workspace → full seeded tree on disk (spot-check `icm/Offers/Founder Coaching Package.md`, 4 workflow YAMLs, `queue/*/`, `logs/audit.jsonl`, `sources/mail/normalized/priya-nair-inquiry.json`, `.gitignore`).
  3. Knowledge nav shows seeded folders with correct counts.
  4. Today shows the §17 narrative (greeting, schedule, 3 prepared cards with "Why this?" source dialog, 4 open loops, 3 away lines).
  5. `mkdir` under `icm/` → nav updates without restart.
  6. Relaunch backend (`Ctrl-C`, `just dev` again) → same workspace auto-opens; app skips onboarding.
- [ ] **Step 5: Update `docs/ARCHITECTURE.md`** to reflect reality (workspace model as-built, RPC surface list, channel names, shell component inventory). Fix README drift.
- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "chore: foundation acceptance pass — architecture doc, packaging verified"
```

---

## Self-review notes (already applied)

- Spec coverage: onboarding (T16), AppShell/ListPane (T14), design system tokens+fonts (T13), ash_typescript all-in incl. channel transport + codegen staleness gate (T11/T12/T4), workspace-less boot + in-workspace sqlite (T7), template in priv (T6), ICM tree/page/watcher (T8/T9), cockpit §17 (T10/T17), Knowledge label + live nav (T14/T18), stubs in Valea voice (T18), ports/naming (T1–T4), acceptance list (T19). Deferred-by-spec items (badges, Suggested Focus, Needs a Decision, holds, Files browser, hood modal) are deliberately absent; "Open the hood" is a labeled disabled placeholder.
- Known adaptation points called out inline: ash_typescript envelope/DSL drift (T11 note), fontsource package names (T13), shadcn Resizable optionality (T14). Each has a bounded fallback and a STOP condition where invention would be dangerous.
- Type consistency: `IcmNode`/`NavTreeItem` defined once in `nav.ts` (T14) and consumed in T15/T18; RPC action names in T11 match the TS function names used in T15; `PreparedItem` shape in T17 matches the cockpit map keys from T10 (camelCased by the ash_typescript output formatter — verify `usedSources` vs `used_sources` against the actual generated client in T15 and align T10's keys if needed).
