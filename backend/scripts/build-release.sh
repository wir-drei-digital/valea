#!/usr/bin/env bash
# Builds a prod release. Usage: build-release.sh [release-name]
# valea          → plain release for web deploys
# valea_desktop  → Burrito-wrapped self-contained sidecar binary (needs zig)
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE="${1:-valea}"
export MIX_ENV=prod

# Burrito requires an EXACT zig version (it hard-exits on any other). Burrito
# 1.6.x pins zig 0.16.0 — do not fall back to the 1.5.x/zig 0.15.2 pair: zig
# 0.15.2's build runner fails to link libSystem against the macOS 26 SDK
# (undefined _abort/__availability_version_check/... on both local Tahoe
# machines and the macos-26 release runners). We fetch the pinned zig into an
# isolated cache dir and put it first on PATH; this only kicks in when
# wrapping the Burrito target. Keep ZIG_VERSION below, the `{:burrito, ...}`
# constraint in mix.exs, and the zig cache keys in .github/workflows/ in
# lockstep.
if [ "$RELEASE" = "valea_desktop" ]; then
  # Pin Burrito to the single target matching this host (overridable by an
  # explicit BURRITO_TARGET). Without this, a multi-target config would make
  # Burrito wrap EVERY target from one host — but the assembled release
  # carries host-compiled NIFs (exqlite, erlexec), so cross-wrapped outputs
  # would be silently broken. Targets are declared in mix.exs.
  if [ -z "${BURRITO_TARGET:-}" ]; then
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) BURRITO_TARGET="macos_arm" ;;
      Linux-x86_64) BURRITO_TARGET="linux_x64" ;;
      Windows_NT-x86_64 | MINGW*-x86_64 | MSYS*-x86_64) BURRITO_TARGET="windows_x64" ;;
      *)
        echo "No Burrito target for host $(uname -s)/$(uname -m) — see mix.exs releases." >&2
        exit 1
        ;;
    esac
    export BURRITO_TARGET
  fi
  echo "Burrito target: $BURRITO_TARGET"

  ZIG_VERSION="0.16.0"
  if ! command -v zig >/dev/null 2>&1 || [ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
    case "$(uname -m)" in
      arm64 | aarch64) ZIG_ARCH="aarch64" ;;
      x86_64) ZIG_ARCH="x86_64" ;;
      *) echo "Unsupported CPU arch for zig: $(uname -m)" >&2; exit 1 ;;
    esac
    case "$(uname -s)" in
      Darwin) ZIG_OS="macos" ;;
      Linux) ZIG_OS="linux" ;;
      Windows_NT | MINGW* | MSYS*) ZIG_OS="windows" ;;
      *) echo "Unsupported OS for zig: $(uname -s)" >&2; exit 1 ;;
    esac
    ZIG_DIR="${ZIG_CACHE_DIR:-$HOME/.local/zig}/zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}"
    ZIG_EXE="zig"
    if [ "$ZIG_OS" = "windows" ]; then ZIG_EXE="zig.exe"; fi
    if [ ! -e "$ZIG_DIR/$ZIG_EXE" ]; then
      echo "Fetching pinned zig ${ZIG_VERSION} for Burrito into $ZIG_DIR ..."
      mkdir -p "$(dirname "$ZIG_DIR")"
      if [ "$ZIG_OS" = "windows" ]; then
        ARCHIVE="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.zip"
        curl -fsSL -o "$(dirname "$ZIG_DIR")/$ARCHIVE" \
          "https://ziglang.org/download/${ZIG_VERSION}/${ARCHIVE}"
        unzip -qo "$(dirname "$ZIG_DIR")/$ARCHIVE" -d "$(dirname "$ZIG_DIR")"
      else
        TARBALL="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.tar.xz"
        curl -fsSL -o "$(dirname "$ZIG_DIR")/$TARBALL" \
          "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
        tar -xJf "$(dirname "$ZIG_DIR")/$TARBALL" -C "$(dirname "$ZIG_DIR")"
      fi
    fi
    export PATH="$ZIG_DIR:$PATH"
    echo "Using zig $(zig version) from $ZIG_DIR"
  fi
fi

mix deps.get --only prod
mix release "$RELEASE" --overwrite
