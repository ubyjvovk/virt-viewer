#!/usr/bin/env bash
# Package Remote Viewer.app and an Applications shortcut in a compressed DMG.
#
#   bash build-aux/macos/make-dmg.sh [app-bundle] [output-dmg]
#
# The defaults are build/Remote Viewer.app and
# build/RemoteViewer-<bundle-version>.dmg. The script can be run from any
# working directory.
set -euo pipefail

cd "$(dirname "$0")/../.."
SRC_ROOT="$PWD"

die() { printf 'make-dmg: error: %s\n' "$*" >&2; exit 1; }

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$SRC_ROOT/$1" ;;
    esac
}

APP_DIR="$(abspath "${1:-build/Remote Viewer.app}")"
[ -d "$APP_DIR" ] || die "app bundle not found: $APP_DIR"
[ -f "$APP_DIR/Contents/Info.plist" ] || \
    die "bundle Info.plist not found: $APP_DIR/Contents/Info.plist"

for tool in hdiutil plutil; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
done

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - \
    "$APP_DIR/Contents/Info.plist")"
[ -n "$VERSION" ] || die "could not read the bundle version from $APP_DIR"
OUT_DMG="$(abspath "${2:-build/RemoteViewer-${VERSION}.dmg}")"
mkdir -p "$(dirname "$OUT_DMG")"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/virt-viewer-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_DIR" "$STAGING/Remote Viewer.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Remote Viewer" -srcfolder "$STAGING" -ov \
    -format UDZO "$OUT_DMG"

printf 'DMG: %s\n' "$OUT_DMG"
