#!/usr/bin/env bash
# Build a relocatable, ad-hoc-signed "Remote Viewer.app" from a finished meson
# build tree.
#
#   bash build-aux/macos/check.sh          # configure + compile + test
#   bash build-aux/macos/make-bundle.sh    # then bundle
#
# Environment overrides:
#   BUILD_DIR    meson build directory to install from (default: build)
#   APP_DIR      output bundle (default: $BUILD_DIR/Remote Viewer.app)
#   BREW_PREFIX  Homebrew prefix (default: `brew --prefix`, else /opt/homebrew)
#
# The script is re-runnable: $APP_DIR is wiped and recreated on every run. It
# can be started from any working directory. See docs/macos.md for what ends up
# inside the bundle and what deliberately does not.
set -euo pipefail

cd "$(dirname "$0")/../.."
SRC_ROOT="$PWD"

msg() { printf '==> %s\n' "$*"; }
warn() { printf 'make-bundle: warning: %s\n' "$*" >&2; }
die() { printf 'make-bundle: error: %s\n' "$*" >&2; exit 1; }

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s\n' "$SRC_ROOT/$1" ;;
    esac
}

# Resolve `.`, `..` and symlinks, so that the APP_DIR safety check in the
# preflight judges the path `rm -rf` would really delete.
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
APP_DIR="$(canonicalize "$(abspath "${APP_DIR:-${BUILD_DIR}/Remote Viewer.app}")")"
BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix 2>/dev/null || echo /opt/homebrew)}"
export PKG_CONFIG_PATH="${BREW_PREFIX}/opt/libxml2/lib/pkgconfig:${BREW_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Relative to Contents/Resources/lib and to $BREW_PREFIX/lib alike.
PIXBUF_SUB="gdk-pixbuf-2.0/2.10.0"
GTK_SUB="gtk-3.0/3.0.0"
# The one LC_RPATH every binary in the bundle gets: handed to dylibbundler as
# -p, and deduplicated afterwards.
RPATH="@executable_path/../Resources/lib/"

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
LIB_DIR="$RES_DIR/lib"
SHARE_DIR="$RES_DIR/share"

# ---------------------------------------------------------------- preflight --

# $APP_DIR is wiped with `rm -rf` below and comes from the environment, so it
# is checked before anything else runs: it must name a *.app that either does
# not exist yet or is an existing bundle we are replacing. Without this,
# APP_DIR=. deletes the source tree.
case "$(basename -- "$APP_DIR")" in
    *.app) ;;
    *) die "refusing APP_DIR=$APP_DIR: it must name a *.app directory that is either absent or an existing bundle" ;;
esac
if [ -e "$APP_DIR" ] || [ -L "$APP_DIR" ]; then
    [ -d "$APP_DIR" ] && [ -f "$APP_DIR/Contents/Info.plist" ] || \
        die "refusing APP_DIR=$APP_DIR: it exists but is not a bundle (no Contents/Info.plist)"
fi

for tool in meson python3 dylibbundler otool install_name_tool codesign iconutil sips plutil \
            glib-compile-schemas gdk-pixbuf-query-loaders; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
done
[ -f "$BUILD_DIR/build.ninja" ] || \
    die "no configured meson build in $BUILD_DIR — run build-aux/macos/check.sh first"
[ -d "$BREW_PREFIX" ] || die "Homebrew prefix not found: $BREW_PREFIX"

# Info.plist declares the spice/vnc URL schemes and the .vv document type
# unconditionally. A build without gtk-mac-integration has no handler for the
# open events LaunchServices would then deliver, so such a bundle is refused
# rather than shipped with dead declarations.
grep -q '#define HAVE_GTK_MAC_INTEGRATION 1' "$BUILD_DIR/config.h" 2>/dev/null || \
    die "$BUILD_DIR was configured without the macOS integration — reconfigure with -Dmacos_integration=enabled before bundling"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/virt-viewer-bundle.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

VERSION="$(meson introspect --projectinfo "$BUILD_DIR" | python3 -c \
    'import json, sys; print(json.load(sys.stdin)["version"])')"
PREFIX="$(meson introspect --buildoptions "$BUILD_DIR" | python3 -c \
    'import json, sys
for opt in json.load(sys.stdin):
    if opt["name"] == "prefix":
        print(opt["value"])
        break')"
[ -n "$VERSION" ] || die "could not read the project version from $BUILD_DIR"
[ -n "$PREFIX" ] || die "could not read the install prefix from $BUILD_DIR"

# ------------------------------------------------------------------ install --

msg "Installing $BUILD_DIR into a staging tree"
DESTDIR="$STAGE/dest" meson install -C "$BUILD_DIR" >/dev/null
STAGED="$STAGE/dest$PREFIX"
[ -x "$STAGED/bin/remote-viewer" ] || die "remote-viewer missing from the staged install"

msg "Creating $APP_DIR"
rm -rf "$APP_DIR"
# Contents/Resources/lib is deliberately not pre-created: the first
# dylibbundler run owns (and with -od erases) that directory.
mkdir -p "$MACOS_DIR" "$SHARE_DIR"

install -m 0755 "$STAGED/bin/remote-viewer" "$MACOS_DIR/remote-viewer"
bundle_targets=(-x Contents/MacOS/remote-viewer)
if [ -x "$STAGED/bin/virt-viewer" ]; then
    install -m 0755 "$STAGED/bin/virt-viewer" "$MACOS_DIR/virt-viewer"
    bundle_targets+=(-x Contents/MacOS/virt-viewer)
else
    warn "virt-viewer was not built (libvirt missing?) — bundling remote-viewer only"
fi

# ------------------------------------------------------------- shared libs ---

# dylibbundler builds `install_name_tool`/`mkdir`/`cp` command lines by string
# concatenation without quoting, so it breaks on the space in "Remote
# Viewer.app". Every path handed to it below is therefore relative to the
# bundle, and the bundle itself is reached with cd — keep it that way.
msg "Bundling shared libraries with dylibbundler"
(
    cd "$APP_DIR"
    # dylibbundler's output is left on stdout on purpose: it prompts on stdin
    # when it cannot resolve a dependency, and a hidden prompt is a hang.
    dylibbundler -od -b "${bundle_targets[@]}" \
        -d Contents/Resources/lib/ \
        -p "$RPATH" \
        -s "$BREW_PREFIX/lib"
)

# ------------------------------------------------------- GTK runtime modules --

# gdk-pixbuf image loaders and GTK input-method modules are dlopen()ed, so they
# are invisible to dylibbundler's dependency walk and must be copied by hand.
copy_modules() {
    local src="$1" dst="$2" what="$3" module found=0
    if [ -d "$src" ]; then
        # An existing but empty directory must take the same warn-and-skip
        # path: the unexpanded glob would otherwise fail cp under `set -e`.
        for module in "$src"/*.so; do
            if [ -e "$module" ]; then
                found=1
                break
            fi
        done
    fi
    if [ "$found" = 0 ]; then
        warn "no $what found in $src — skipping"
        return 1
    fi
    mkdir -p "$dst"
    cp "$src"/*.so "$dst/"
}

msg "Copying gdk-pixbuf loaders and GTK immodules"
have_pixbuf_loaders=0
have_immodules=0
if copy_modules "$BREW_PREFIX/lib/$PIXBUF_SUB/loaders" "$LIB_DIR/$PIXBUF_SUB/loaders" \
                "gdk-pixbuf loaders"; then
    have_pixbuf_loaders=1
fi
if copy_modules "$BREW_PREFIX/lib/$GTK_SUB/immodules" "$LIB_DIR/$GTK_SUB/immodules" \
                "GTK immodules"; then
    have_immodules=1
fi

# The module caches must be generated from the Homebrew originals, before
# dylibbundler rewrites the copied .so files: the query tools dlopen() each
# module, which only works while its original rpaths are still valid.
#
# Both caches are written with module paths relative to the cache file itself,
# so that nothing in the bundle is tied to where it was built. Neither
# gdk-pixbuf nor GTK resolves such an entry against the cache file, though —
# both hand it straight to g_module_open(), where dlopen() would look it up
# relative to the process's working directory. The launcher therefore turns
# these caches into absolute ones at startup; see "Writing the launcher" below.
relativize_cache() {
    local abs_cache="$1" strip_prefix="$2" out="$3"
    python3 - "$abs_cache" "$strip_prefix" "$out" <<'PY'
import sys

src, strip_prefix, out = sys.argv[1:4]
with open(src, encoding="utf-8") as fh:
    data = fh.read()
# Cache entries quote the module path; drop the bundle prefix from each one.
data = data.replace('"' + strip_prefix, '"')
with open(out, "w", encoding="utf-8") as fh:
    fh.write(data)
PY
}

if [ "$have_pixbuf_loaders" = 1 ]; then
    msg "Generating loaders.cache with bundle-relative module paths"
    gdk-pixbuf-query-loaders "$BREW_PREFIX/lib/$PIXBUF_SUB/loaders/"*.so \
        > "$STAGE/loaders.cache"
    relativize_cache "$STAGE/loaders.cache" "$BREW_PREFIX/lib/$PIXBUF_SUB/" \
        "$LIB_DIR/$PIXBUF_SUB/loaders.cache"
fi

if [ "$have_immodules" = 1 ]; then
    if command -v gtk-query-immodules-3.0 >/dev/null 2>&1; then
        msg "Generating immodules.cache with bundle-relative module paths"
        gtk-query-immodules-3.0 "$BREW_PREFIX/lib/$GTK_SUB/immodules/"*.so \
            > "$STAGE/immodules.cache"
        relativize_cache "$STAGE/immodules.cache" "$BREW_PREFIX/lib/$GTK_SUB/" \
            "$LIB_DIR/$GTK_SUB/immodules.cache"
    else
        warn "gtk-query-immodules-3.0 not on PATH — no immodules.cache generated"
    fi
fi

msg "Bundling the dependencies of the copied modules"
module_targets=()
module_files=()
while IFS= read -r module; do
    module_files+=("$module")
    module_targets+=(-x "$module")
done < <(cd "$APP_DIR" && find Contents/Resources/lib -type f -name '*.so')
if [ "${#module_targets[@]}" -gt 0 ]; then
    (
        cd "$APP_DIR"
        # -of (not -od) on this pass: the destination directory now holds the
        # dylibs from the first pass and must not be erased.
        dylibbundler -of -b "${module_targets[@]}" \
            -d Contents/Resources/lib/ \
            -p "$RPATH" \
            -s "$BREW_PREFIX/lib"
    )
fi

# Some Homebrew .so modules are Mach-O dylibs with an absolute LC_ID_DYLIB
# (notably librsvg's pixbuf loader). dylibbundler fixes dependencies of -x
# targets but leaves their own install IDs unchanged, so normalize those IDs.
for module in "${module_files[@]}"; do
    module_id="$(otool -D "$APP_DIR/$module" 2>/dev/null | sed -n '2p')"
    if [ -n "$module_id" ]; then
        install_name_tool -id "@loader_path/$(basename "$module")" "$APP_DIR/$module"
    fi
done

# dylibbundler can leave a binary carrying its -p rpath twice — librsvg's
# pixbuf loader is one. dyld tolerates that in an executable but refuses to
# dlopen() a module that has it ("duplicate LC_RPATH"), and losing the SVG
# loader loses every symbolic icon in the UI, which aborts GTK the first time
# it has to draw one. Drop the extra copies; -delete_rpath removes one per
# call.
msg "Removing duplicate LC_RPATH entries"
count_rpaths() {
    otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' \
        | grep -c -x -F -- "$RPATH" || true
}
while IFS= read -r binary; do
    n="$(count_rpaths "$binary")"
    while [ "$n" -gt 1 ]; do
        install_name_tool -delete_rpath "$RPATH" "$binary"
        n=$((n - 1))
    done
done < <(find "$APP_DIR" \
    \( -name '*.dylib' -o -name '*.so' -o -path '*/MacOS/*' \) -type f)

msg "Checking that nothing links outside the bundle"
external="$(find "$APP_DIR" \
    \( -name '*.dylib' -o -name '*.so' -o -path '*/MacOS/*' \) -type f \
    -exec otool -L {} + 2>/dev/null | grep -E "$BREW_PREFIX|/opt/homebrew|/usr/local" || true)"
if [ -n "$external" ]; then
    printf '%s\n' "$external" >&2
    die "the bundle still references libraries outside it"
fi

# ----------------------------------------------------------- resource data ---

msg "Copying installed data files"
for sub in locale icons/hicolor mime; do
    if [ -d "$STAGED/share/$sub" ]; then
        mkdir -p "$SHARE_DIR/$(dirname "$sub")"
        cp -R "$STAGED/share/$sub" "$SHARE_DIR/$sub"
    fi
done

msg "Copying GSettings schemas"
mkdir -p "$SHARE_DIR/glib-2.0/schemas"
cp -RL "$BREW_PREFIX/share/glib-2.0/schemas/." "$SHARE_DIR/glib-2.0/schemas/"
if [ -d "$STAGED/share/glib-2.0/schemas" ]; then
    cp -R "$STAGED/share/glib-2.0/schemas/." "$SHARE_DIR/glib-2.0/schemas/"
fi
rm -f "$SHARE_DIR/glib-2.0/schemas/gschemas.compiled"
glib-compile-schemas "$SHARE_DIR/glib-2.0/schemas"

# Only the icon sizes GTK actually asks for, to keep the bundle small.
msg "Copying the Adwaita icon theme"
adwaita_src="$BREW_PREFIX/share/icons/Adwaita"
adwaita_dst="$SHARE_DIR/icons/Adwaita"
if [ -d "$adwaita_src" ]; then
    mkdir -p "$adwaita_dst"
    if [ -f "$adwaita_src/index.theme" ]; then
        cp -L "$adwaita_src/index.theme" "$adwaita_dst/"
    fi
    for size in 16x16 22x22 24x24 32x32 48x48 scalable symbolic; do
        if [ -d "$adwaita_src/$size" ]; then
            cp -RL "$adwaita_src/$size" "$adwaita_dst/$size"
        fi
    done
else
    warn "adwaita-icon-theme not found in $adwaita_src — stock icons will be missing"
fi

# virt-viewer installs its own icons into hicolor but not the theme index.
if [ ! -f "$SHARE_DIR/icons/hicolor/index.theme" ] && \
   [ -f "$BREW_PREFIX/share/icons/hicolor/index.theme" ]; then
    mkdir -p "$SHARE_DIR/icons/hicolor"
    cp -L "$BREW_PREFIX/share/icons/hicolor/index.theme" "$SHARE_DIR/icons/hicolor/"
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    for theme in "$adwaita_dst" "$SHARE_DIR/icons/hicolor"; do
        [ -f "$theme/index.theme" ] && gtk-update-icon-cache -qtf "$theme" || true
    done
fi

msg "Copying the shared MIME database"
if [ -d "$BREW_PREFIX/share/mime" ]; then
    mkdir -p "$SHARE_DIR/mime"
    cp -RL "$BREW_PREFIX/share/mime/." "$SHARE_DIR/mime/"
    # Put virt-viewer's own .vv definition back on top of the freedesktop one.
    if [ -d "$STAGED/share/mime/packages" ]; then
        cp -R "$STAGED/share/mime/packages/." "$SHARE_DIR/mime/packages/"
    fi
    if command -v update-mime-database >/dev/null 2>&1; then
        update-mime-database "$SHARE_DIR/mime"
    else
        warn "update-mime-database not on PATH — the .vv MIME type is not registered"
    fi
else
    warn "no shared MIME database in $BREW_PREFIX/share/mime"
fi

# ------------------------------------------------------------------- icon ----

msg "Building remote-viewer.icns"
iconset="$STAGE/remote-viewer.iconset"
mkdir -p "$iconset"
icon256="$SRC_ROOT/icons/256x256/virt-viewer.png"
[ -f "$icon256" ] || die "missing $icon256"
cp "$SRC_ROOT/icons/16x16/virt-viewer.png" "$iconset/icon_16x16.png"
cp "$SRC_ROOT/icons/32x32/virt-viewer.png" "$iconset/icon_16x16@2x.png"
cp "$SRC_ROOT/icons/32x32/virt-viewer.png" "$iconset/icon_32x32.png"
cp "$icon256" "$iconset/icon_128x128@2x.png"
cp "$icon256" "$iconset/icon_256x256.png"
# The 64, 128, 512 and 1024 px variants do not exist in icons/; derive them from
# the 256 px master (upscaling for 512/1024 is acceptable for an app icon).
sips -z 64 64 "$icon256" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon256" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 512 512 "$icon256" --out "$iconset/icon_256x256@2x.png" >/dev/null
cp "$iconset/icon_256x256@2x.png" "$iconset/icon_512x512.png"
sips -z 1024 1024 "$icon256" --out "$iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset" -o "$RES_DIR/remote-viewer.icns"

# --------------------------------------------------------------- metadata ----

msg "Writing Info.plist and PkgInfo"
# LSMinimumSystemVersion has to match what the bundled Mach-Os really need: the
# Homebrew libraries inherit their builder's deployment target, and a lower
# value in the plist only buys a silent dyld abort instead of a LaunchServices
# dialog on an older macOS.
MINOS="$(otool -l "$MACOS_DIR/remote-viewer" \
    | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2;exit}')"
if [ -z "$MINOS" ]; then
    MINOS="12.0"
    warn "no LC_BUILD_VERSION minos in the bundled remote-viewer — falling back to LSMinimumSystemVersion $MINOS"
fi
msg "LSMinimumSystemVersion: $MINOS"
sed -e "s|@VERSION@|$VERSION|g" -e "s|@MINOS@|$MINOS|g" \
    "$SRC_ROOT/build-aux/macos/Info.plist.in" \
    > "$CONTENTS_DIR/Info.plist"
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null || die "generated Info.plist is malformed"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# CFBundleExecutable is this launcher rather than remote-viewer itself: the two
# dlopen() module caches are located through GDK_PIXBUF_MODULE_FILE and
# GTK_IM_MODULE_FILE, which must hold absolute paths and therefore cannot be
# baked into Info.plist's LSEnvironment in a relocatable app. The launcher
# resolves them from its own location at startup — including the module paths
# inside them. Everything else the app needs
# (locale, XDG_DATA_DIRS, GSETTINGS_SCHEMA_DIR) is derived inside the binary by
# virt_viewer_util_init(), so the launcher stays this small.
msg "Writing the launcher"
cat > "$MACOS_DIR/remote-viewer-launcher" <<'LAUNCHER'
#!/bin/bash
# Remote Viewer.app launcher — see docs/macos.md ("Packaging").
set -eu
here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
res="$(cd -- "$here/../Resources" && pwd -P)"

export GDK_PIXBUF_MODULE_FILE="$res/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
export GTK_IM_MODULE_FILE="$res/lib/gtk-3.0/3.0.0/immodules.cache"

# The bundled caches name their modules relative to themselves, which keeps the
# bundle relocatable but is not something gdk-pixbuf or GTK knows how to
# resolve: both pass the entry to dlopen(), which reads it relative to the
# working directory and fails. Rewrite the two caches with absolute paths into
# a per-user cache directory on every launch, so that moving the bundle simply
# regenerates them. If that directory is not usable, fall back to the bundled
# caches: SVG icons and non-default input methods are then unavailable, which
# is a degraded UI rather than no application.
cachedir="${XDG_CACHE_HOME:-$HOME/Library/Caches}/org.virt-manager.remote-viewer"
if mkdir -p "$cachedir" 2>/dev/null; then
    # Written through a temporary file and mv'd into place: a second copy of
    # the app can be launched while this one runs (an arriving URI does exactly
    # that), and it would otherwise dlopen against a half-written cache.
    absolutize() { # <bundled cache> <relative dir the entries start with> <output>
        local dir tmp
        dir="$(dirname -- "$1")"
        tmp="$3.tmp.$$"
        if sed -e "s|\"$2/|\"$dir/$2/|g" -- "$1" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$3" 2>/dev/null && return 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }
    if absolutize "$GDK_PIXBUF_MODULE_FILE" loaders "$cachedir/loaders.cache"; then
        export GDK_PIXBUF_MODULE_FILE="$cachedir/loaders.cache"
    fi
    if absolutize "$GTK_IM_MODULE_FILE" immodules "$cachedir/immodules.cache"; then
        export GTK_IM_MODULE_FILE="$cachedir/immodules.cache"
    fi
fi

# LaunchServices may append a -psn_0_... process serial number argument, which
# remote-viewer's option parser would reject.
case "${1-}" in
    -psn_*) shift ;;
esac

exec "$here/remote-viewer" ${1+"$@"}
LAUNCHER
chmod 0755 "$MACOS_DIR/remote-viewer-launcher"

# ------------------------------------------------------------------- sign ----

# Signing goes inside out. `codesign --deep` descends into nested *bundles*,
# but the libraries and modules here are loose Mach-O files, which it only
# seals as resources — and every one of them has had its Homebrew signature
# invalidated by install_name_tool. On arm64 dyld kills the process outright
# the first time it dlopen()s a module whose signature does not match, so each
# file gets its own ad-hoc signature first.
msg "Ad-hoc signing the bundled libraries and modules"
while IFS= read -r binary; do
    codesign --force --sign - "$binary" 2>/dev/null || die "could not sign $binary"
done < <(find "$APP_DIR" \( -name '*.dylib' -o -name '*.so' \) -type f)

msg "Ad-hoc signing the bundle"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# ----------------------------------------------------------------- report ----

if ! version_out="$("$MACOS_DIR/remote-viewer" --version 2>&1)"; then
    warn "could not run the bundled remote-viewer --version:"
    printf '%s\n' "$version_out" >&2
else
    msg "$version_out"
fi

printf '\nBundle: %s\nSize:   %s\n' "$APP_DIR" "$(du -sh "$APP_DIR" | awk '{print $1}')"
