#!/usr/bin/env bash
# Build a relocatable, ad-hoc-signed .app around the native SPICE viewer.
#
#   bash macos-native/make-bundle.sh
#
# The result is a double-clickable bundle that carries every non-system dylib
# it needs, so it runs on a machine with no Homebrew.  It is what registers the
# spice:// URL scheme and the .vv document type with LaunchServices; the plain
# `build.sh` binary keeps working unchanged and is what this script bundles.
#
# Environment overrides:
#   BUILD_DIR    where build.sh puts spice-viewer (default: macos-native/build)
#   APP_DIR      output bundle (default: $BUILD_DIR/$APP_NAME.app)
#   BREW_PREFIX  Homebrew prefix (default: `brew --prefix`, else /opt/homebrew)
#   SKIP_BUILD=1 bundle the existing binary instead of rebuilding it
#
# Re-runnable: $APP_DIR is wiped and recreated on every run.  Runs from any
# working directory.
set -euo pipefail

cd "$(dirname "$0")"
SRC_DIR="$PWD"

# --- naming -----------------------------------------------------------------
# PLACEHOLDERS, pending a user decision on what this viewer is called.  Both
# appear in exactly one place each; Info.plist.in substitutes them.  Changing
# APP_NAME renames the bundle, changing BUNDLE_ID makes macOS treat it as a
# different application (LaunchServices registrations, Accessibility grant and
# NSUserDefaults are all keyed on it), so change it before shipping, not after.
APP_NAME="SPICE Viewer"
BUNDLE_ID="io.github.virt-viewer.spice-viewer"
APP_VERSION="0.1.0"

msg()  { printf '==> %s\n' "$*"; }
warn() { printf 'make-bundle: warning: %s\n' "$*" >&2; }
die()  { printf 'make-bundle: error: %s\n' "$*" >&2; exit 1; }

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$SRC_DIR/$1" ;;
    esac
}

# Resolve `.`, `..` and symlinks, so the APP_DIR safety check below judges the
# path `rm -rf` would really delete.
canonicalize() {
    local path="$1" dir base
    if [ -d "$path" ]; then
        (cd -- "$path" && pwd -P)
        return
    fi
    dir="$(dirname -- "$path")"
    base="$(basename -- "$path")"
    if [ -d "$dir" ]; then
        printf '%s/%s\n' "$(cd -- "$dir" && pwd -P)" "$base"
    else
        printf '%s\n' "$path"
    fi
}

BUILD_DIR="$(abspath "${BUILD_DIR:-build}")"
APP_DIR="$(canonicalize "$(abspath "${APP_DIR:-${BUILD_DIR}/${APP_NAME}.app}")")"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
LIB_DIR="$RES_DIR/lib"
# The one LC_RPATH every Mach-O in the bundle gets: handed to dylibbundler as
# -p, and deduplicated afterwards.
RPATH="@executable_path/../Resources/lib/"

# ---------------------------------------------------------------- preflight --

# $APP_DIR is wiped with `rm -rf` below and comes from the environment, so it
# is checked before anything else runs: it must name a *.app that either does
# not exist yet or is an existing bundle we are replacing.  Without this,
# APP_DIR=. deletes the source tree.
case "$(basename -- "$APP_DIR")" in
    *.app) ;;
    *) die "refusing APP_DIR=$APP_DIR: it must name a *.app directory that is either absent or an existing bundle" ;;
esac
if [ -e "$APP_DIR" ] || [ -L "$APP_DIR" ]; then
    [ -d "$APP_DIR" ] && [ -f "$APP_DIR/Contents/Info.plist" ] || \
        die "refusing APP_DIR=$APP_DIR: it exists but is not a bundle (no Contents/Info.plist)"
fi

for tool in dylibbundler otool install_name_tool codesign plutil; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
done
[ -d "$BREW_PREFIX" ] || die "Homebrew prefix not found: $BREW_PREFIX"

# ------------------------------------------------------------------- build ---

if [ "${SKIP_BUILD:-0}" = 1 ]; then
    msg "SKIP_BUILD=1: bundling the existing binary"
else
    msg "Building the viewer"
    BUILD_DIR="$BUILD_DIR" bash "$SRC_DIR/build.sh"
fi
[ -x "$BUILD_DIR/spice-viewer" ] || die "no spice-viewer in $BUILD_DIR — run build.sh first"

msg "Creating $APP_DIR"
rm -rf "$APP_DIR"
# Contents/Resources/lib is deliberately not pre-created: the dylibbundler run
# owns (and with -od erases) that directory.
mkdir -p "$MACOS_DIR" "$RES_DIR"
install -m 0755 "$BUILD_DIR/spice-viewer" "$MACOS_DIR/spice-viewer"

# ------------------------------------------------------------- shared libs ---

# dylibbundler builds its `install_name_tool`/`cp` command lines by string
# concatenation without quoting, so it breaks on the space in "SPICE
# Viewer.app".  Every path handed to it is therefore relative to the bundle,
# and the bundle itself is reached with cd — keep it that way.
msg "Bundling shared libraries with dylibbundler"
(
    cd "$APP_DIR"
    # dylibbundler's output stays on stdout on purpose: it prompts on stdin
    # when it cannot resolve a dependency, and a hidden prompt is a hang.
    dylibbundler -od -b -x Contents/MacOS/spice-viewer \
        -d Contents/Resources/lib/ \
        -p "$RPATH" \
        -s "$BREW_PREFIX/lib"
)

# dylibbundler can leave a binary carrying its -p rpath twice.  dyld tolerates
# that in an executable but refuses to dlopen() anything that has it, so drop
# the extra copies; -delete_rpath removes one per call.
msg "Removing duplicate LC_RPATH entries"
count_rpaths() {
    otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' \
        | grep -c -x -F -- "$RPATH" || true
}
mach_os() {
    find "$APP_DIR" \( -name '*.dylib' -o -path '*/MacOS/*' \) -type f
}
while IFS= read -r binary; do
    n="$(count_rpaths "$binary")"
    while [ "$n" -gt 1 ]; do
        install_name_tool -delete_rpath "$RPATH" "$binary"
        n=$((n - 1))
    done
done < <(mach_os)

msg "Checking that nothing links outside the bundle"
external="$(while IFS= read -r b; do otool -L "$b"; done < <(mach_os) \
    | grep -E "$BREW_PREFIX|/opt/homebrew|/usr/local" || true)"
if [ -n "$external" ]; then
    printf '%s\n' "$external" >&2
    die "the bundle still references libraries outside it"
fi

# ------------------------------------------------------------------- icon ----

# The viewer has no icon of its own yet; borrow the project's, which is what a
# virt-viewer-family application should look like in the Dock anyway.
icon_src="$SRC_DIR/../icons/256x256/virt-viewer.png"
if [ -f "$icon_src" ] && command -v iconutil >/dev/null 2>&1 \
                      && command -v sips >/dev/null 2>&1; then
    msg "Building spice-viewer.icns"
    iconset="$(mktemp -d "${TMPDIR:-/tmp}/spice-viewer-icon.XXXXXX")/icon.iconset"
    mkdir -p "$iconset"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" \
                "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" \
                "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" \
                "1024 icon_512x512@2x"; do
        sips -z "${spec%% *}" "${spec%% *}" "$icon_src" \
             --out "$iconset/${spec##* }.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$RES_DIR/spice-viewer.icns"
    rm -rf "$(dirname "$iconset")"
else
    warn "no $icon_src (or no iconutil/sips) — the bundle gets the generic icon"
fi

# --------------------------------------------------------------- metadata ----

msg "Writing Info.plist and PkgInfo"
# LSMinimumSystemVersion has to match what the bundled Mach-Os really need, and
# that is the HIGHEST deployment target among them, not the viewer's own: the
# Homebrew dylibs inherit their builder's SDK, and claiming to run on an older
# macOS than they do only buys a silent dyld abort instead of a LaunchServices
# dialog.
minos_of() {
    otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}'
}
MINOS="$(while IFS= read -r b; do minos_of "$b"; done < <(mach_os) \
    | grep -E '^[0-9]+(\.[0-9]+)*$' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if [ -z "$MINOS" ]; then
    MINOS="12.0"
    warn "no LC_BUILD_VERSION minos in any bundled Mach-O — falling back to LSMinimumSystemVersion $MINOS"
fi
msg "LSMinimumSystemVersion: $MINOS"
sed -e "s|@APP_NAME@|$APP_NAME|g" \
    -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
    -e "s|@VERSION@|$APP_VERSION|g" \
    -e "s|@MINOS@|$MINOS|g" \
    "$SRC_DIR/Info.plist.in" > "$CONTENTS_DIR/Info.plist"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null || die "generated Info.plist is malformed"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# ------------------------------------------------------------------- sign ----

# Signing goes inside out.  `codesign --deep` descends into nested *bundles*,
# but the libraries here are loose Mach-O files, which it only seals as
# resources — and every one of them has had its Homebrew signature invalidated
# by dylibbundler's install_name_tool rewrites.  On arm64 dyld kills the
# process outright the first time it maps a library whose signature does not
# match, so each file gets its own ad-hoc signature first, AFTER the last
# rewrite above.  (virt-viewer T-0006: getting this order wrong shows up as
# "the application quit unexpectedly", not as a link error.)
msg "Ad-hoc signing the bundled libraries"
while IFS= read -r binary; do
    codesign --force --sign - "$binary" 2>/dev/null || die "could not sign $binary"
done < <(find "$APP_DIR" -name '*.dylib' -type f)

msg "Ad-hoc signing the bundle"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# ----------------------------------------------------------------- report ----

printf '\nBundle: %s\nSize:   %s\n' "$APP_DIR" "$(du -sh "$APP_DIR" | awk '{print $1}')"
