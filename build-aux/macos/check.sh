#!/usr/bin/env bash
# macOS build + test entry point.
#   build-aux/macos/check.sh            configure (if needed), compile, run meson tests
#   BUILD_DIR=other build-aux/macos/check.sh
# Requires Homebrew deps — see docs/macos.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
BUILD_DIR="${BUILD_DIR:-build}"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PKG_CONFIG_PATH="${BREW_PREFIX}/opt/libxml2/lib/pkgconfig:${BREW_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
  meson setup "$BUILD_DIR" "$@"
fi
ninja -C "$BUILD_DIR"
meson test -C "$BUILD_DIR" --print-errorlogs
