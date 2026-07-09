#!/usr/bin/env bash
# Builds a prod release. Usage: build-release.sh [release-name]
# valea          → plain release for web deploys
# valea_desktop  → Burrito-wrapped self-contained sidecar binary (needs zig)
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE="${1:-valea}"
export MIX_ENV=prod

# Burrito 1.5.x requires EXACTLY zig 0.15.2 (it hard-exits on any other
# version and its vendored build.zig uses pre-0.16 std.Build APIs). The repo
# toolchain ships zig 0.16.0 for other purposes, so for the desktop sidecar we
# fetch a pinned, isolated zig 0.15.2 into a cache dir and put it first on PATH.
# This only kicks in when wrapping the Burrito target.
if [ "$RELEASE" = "valea_desktop" ]; then
  ZIG_VERSION="0.15.2"
  if ! command -v zig >/dev/null 2>&1 || [ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
    case "$(uname -m)" in
      arm64 | aarch64) ZIG_ARCH="aarch64" ;;
      x86_64) ZIG_ARCH="x86_64" ;;
      *) echo "Unsupported CPU arch for zig: $(uname -m)" >&2; exit 1 ;;
    esac
    case "$(uname -s)" in
      Darwin) ZIG_OS="macos" ;;
      Linux) ZIG_OS="linux" ;;
      *) echo "Unsupported OS for zig: $(uname -s)" >&2; exit 1 ;;
    esac
    ZIG_DIR="${ZIG_CACHE_DIR:-$HOME/.local/zig}/zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}"
    if [ ! -x "$ZIG_DIR/zig" ]; then
      echo "Fetching pinned zig ${ZIG_VERSION} for Burrito into $ZIG_DIR ..."
      mkdir -p "$(dirname "$ZIG_DIR")"
      TARBALL="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}.tar.xz"
      curl -fsSL -o "$(dirname "$ZIG_DIR")/$TARBALL" \
        "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}"
      tar -xJf "$(dirname "$ZIG_DIR")/$TARBALL" -C "$(dirname "$ZIG_DIR")"
    fi
    export PATH="$ZIG_DIR:$PATH"
    echo "Using zig $(zig version) from $ZIG_DIR"
  fi
fi

mix deps.get --only prod
mix release "$RELEASE" --overwrite
