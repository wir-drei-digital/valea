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
    # Match the backend's dev default (config/runtime.exs) so the browser dev
    # build sends a token the control-token plug + socket accept.
    export VITE_VALEA_CONTROL_TOKEN=valea-dev-token
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd frontend && bun run dev) &
    wait

# Backend + Tauri dev shell (Tauri starts the frontend dev server itself)
dev-desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    # Tauri spawns the frontend dev server (beforeDevCommand); it inherits this.
    export VITE_VALEA_CONTROL_TOKEN=valea-dev-token
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

# Package the backend as the desktop sidecar binary (host-native only:
# the release embeds host-compiled NIFs, so each OS builds its own — the
# same recipe runs on the macOS and Linux release runners).
package-backend:
    #!/usr/bin/env bash
    set -euo pipefail
    cd frontend && bun run build
    cd ..
    rm -rf backend/priv/static/_app backend/priv/static/index.html
    cp -R frontend/build/. backend/priv/static/
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) export BURRITO_TARGET="${BURRITO_TARGET:-macos_arm}" ;;
      Linux-x86_64) export BURRITO_TARGET="${BURRITO_TARGET:-linux_x64}" ;;
      *) echo "No sidecar target for host $(uname -s)/$(uname -m) — see mix.exs releases." >&2; exit 1 ;;
    esac
    backend/scripts/build-release.sh valea_desktop
    triple=$(rustc -vV | sed -n 's/host: //p')
    mkdir -p desktop/src-tauri/binaries
    cp "backend/burrito_out/valea_desktop_${BURRITO_TARGET}" "desktop/src-tauri/binaries/valea-server-${triple}"

# Full desktop bundle
desktop-bundle: package-backend
    cd desktop && bun tauri build

# Throwaway Dovecot for manual mail E2E (mara / marapass, IMAPS-only,
# scripts/dovecot/dovecot.conf mounted in place of the image's own config).
#
#   - Pinned to the `2.3` tag, not `latest`: as of this writing
#     `dovecot/dovecot:latest` resolves to Dovecot 2.4, which renamed the
#     directives this conf uses (`ssl_cert`/`ssl_key` -> `ssl_server_*_file`,
#     unnamed `passdb { driver = static }` -> named `passdb static { }`,
#     `mail_location` -> `mail_driver`+`mail_path`, plus new mandatory
#     `dovecot_config_version`/`dovecot_storage_version` settings) and would
#     fail to boot against this file. `2.3` is a real, still-published tag
#     matching the syntax authored here — re-pin (and rewrite the conf) if
#     that tag is ever pulled.
#   - Connect from the app: host `localhost`, port `3993`, user `mara`,
#     password `marapass`. Set these via the mail setup RPC / onboarding UI
#     (`config/mail.yaml` + the OS keychain), not by hand-editing files.
#   - AI folders (AI/Review, AI/Processed) are NOT pre-created by this
#     container — run the connection doctor's "Create AI folders" action
#     (or the `create_mail_folders` RPC) once connected; see
#     `Valea.Mail.Doctor.create_folders/1`.
#   - TLS trust: the mounted `scripts/dovecot/dovecot.conf` serves
#     `backend/test/fixtures/tls/server.pem` (CN=localhost, signed by the
#     fixture `ca.pem`) instead of the stock image's own self-signed cert —
#     but `Valea.Mail.ImapClient` always dials `verify: :verify_peer` against
#     the OS trust store (see its moduledoc: this is never configurable, and
#     `VALEA_MAIL_TLS_INSECURE=1` / any such escape hatch is NOT supported,
#     by design — there is no way to weaken it from the app side). To make
#     verify_peer trust the fixture CA for this manual run only, point the
#     BEAM's own CA bundle at it when you boot the backend — this is a
#     startup-time trust-root swap, not a code change, and it exercises the
#     exact same `verify_peer` path production traffic does:
#
#       export ELIXIR_ERL_OPTIONS="-public_key cacerts_path \"$(pwd)/backend/test/fixtures/tls/ca.pem\""
#       just dev
#
#     (run from the repo root; equivalently, export it before
#     `cd backend && mix phx.server`). Assumes the checkout path contains no
#     spaces: the elixir launcher splices $ELIXIR_ERL_OPTIONS into the erl
#     invocation unquoted, so a space in $(pwd) would split the argument.
#     Unset it / start a normal shell for anything other than this manual
#     E2E — it globally replaces the BEAM's trusted roots for the process.
mail-dev:
    docker run --rm -p 3993:993 --name valea-dovecot \
      -v "$(pwd)/scripts/dovecot/dovecot.conf:/etc/dovecot/dovecot.conf:ro" \
      -v "$(pwd)/backend/test/fixtures/tls:/etc/dovecot/tls:ro" \
      dovecot/dovecot:2.3

# Run all checks (fails if the generated RPC client is stale)
test:
    cd backend && mix test
    cd backend && mix ash_typescript.codegen && git diff --exit-code ../frontend/src/lib/api/ || (echo "STALE GENERATED CLIENT — commit the regenerated files" && exit 1)
    cd frontend && bun run check
    cd frontend && bun run test
