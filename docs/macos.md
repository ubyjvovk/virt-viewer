# Building on macOS

virt-viewer and remote-viewer can be built natively on macOS using
Homebrew-provided dependencies.

## Prerequisites

Install the build tools and libraries with Homebrew:

```sh
brew install meson ninja pkgconf gtk+3 gtk-vnc spice-gtk spice-protocol libvirt libvirt-glib vte3 libxml2 gettext adwaita-icon-theme gtk-mac-integration dylibbundler
```

## Build & test

The macOS build helper configures the project when necessary, compiles it, and
runs the test suite:

```sh
bash build-aux/macos/check.sh
```

To run the equivalent commands manually, first expose Homebrew's keg-only
`libxml2` package to `pkg-config`:

```sh
export PKG_CONFIG_PATH="$(brew --prefix)/opt/libxml2/lib/pkgconfig:$(brew --prefix)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
meson setup build
ninja -C build
meson test -C build
```

The helper sets `PKG_CONFIG_PATH` automatically.

## Running

Run remote-viewer directly from the build directory:

```sh
build/src/remote-viewer
```

## Feature matrix

| Feature | Available on macOS |
| --- | --- |
| SPICE | Yes |
| VNC | Yes |
| libvirt | Yes |
| VTE | Yes |
| oVirt (`govirt-1.0`, `rest-1.0`) | No; auto-disabled |
| bash-completion | No; auto-disabled |

## Packaging

`make-bundle.sh` is described in a later revision.

## Continuous integration

GitHub Actions workflow `.github/workflows/macos.yml` builds and tests every
push and pull request on `macos-latest` (Homebrew dependencies plus
`bash build-aux/macos/check.sh`). Meson logs are uploaded as artifacts; a
`.app` bundle is uploaded too when one is present under `build/`.

## Running from a bundle

When the binary runs from inside a macOS `.app` bundle, the traditional
trick of baking the compile-time install prefix (`LOCALE_DIR`) into the
binary no longer works: a bundled app is relocatable, so the prefix is not
fixed. Instead, the app derives its data paths from the bundle at runtime.

`virt_viewer_util_get_bundle_resources_dir()` in `src/virt-viewer-util.c`
returns the bundle's `Contents/Resources` directory. It uses only
CoreFoundation (C API) — `CFBundleGetMainBundle()` +
`CFBundleCopyResourcesDirectoryURL()` + `CFURLGetFileSystemRepresentation()`.
Because CoreFoundation returns a bundle for any executable, "in a bundle"
is decided by the trailing path shape: the resources directory must end in
`.app/Contents/Resources`. Otherwise the function returns NULL and the app
falls back to its compile-time paths, so behaviour outside a bundle (a
plain `build/src/remote-viewer`, or a `/opt/homebrew` install) is unchanged.

When a bundle resources dir is found, `virt_viewer_util_init()` sets the
following, all before GTK is initialised:

* **Locale**: `bindtextdomain(GETTEXT_PACKAGE, "<res>/share/locale")` — so
  translations ship inside the bundle.
* **`XDG_DATA_DIRS`** → `<res>/share` — set only if currently unset; makes
  the icon theme and the mime database bundled under the Resources dir
  discoverable. Because it is only set when unset, a user-supplied value is
  never clobbered.
* **`GSETTINGS_SCHEMA_DIR`** → `<res>/share/glib-2.0/schemas` — set only if
  currently unset, so GSettings schema files bundled in the app are found.

The CoreFoundation framework is linked on macOS only, gated in
`src/meson.build` behind `host_machine.system() == 'darwin'`.
