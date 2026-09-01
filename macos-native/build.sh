#!/usr/bin/env bash
# Build the native macOS SPICE viewer PoC.  Standalone: it does not touch the
# project's meson build in any way.
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-build}"
BIN="$BUILD_DIR/spice-viewer"

export PKG_CONFIG_PATH="$(brew --prefix)/opt/libxml2/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

CFLAGS_PKG=$(pkg-config --cflags spice-client-glib-2.0)
LIBS_PKG=$(pkg-config --libs spice-client-glib-2.0)

mkdir -p "$BUILD_DIR"

# shellcheck disable=SC2086  # pkg-config output must word-split
clang -g -O2 -Wall -Wextra -Werror -fobjc-arc \
      -o "$BIN" \
      main.m vsm-connect.m vsm-debug.m vsm-tap.m vsm-spice.c vsm-keymap.c \
      $CFLAGS_PKG $LIBS_PKG \
      -framework Cocoa -framework QuartzCore -framework IOSurface -framework ImageIO -framework CoreServices

# Ad-hoc signature so the binary can take keyboard focus when launched from a
# terminal on a machine with a hardened runtime policy.
codesign --force --sign - "$BIN" >/dev/null 2>&1 || true

echo "built $PWD/$BIN"
