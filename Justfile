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
    cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/ || (echo "STALE GENERATED CLIENT — commit the regenerated files" && exit 1)
    cd frontend && bun run check
    cd frontend && bun run test
