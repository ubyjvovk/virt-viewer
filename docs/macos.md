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

`build-aux/macos/make-bundle.sh` turns a finished meson build into a
self-contained, relocatable, ad-hoc-signed `Remote Viewer.app` that runs on a
Mac without Homebrew installed.

```sh
bash build-aux/macos/check.sh          # configure, compile, test
bash build-aux/macos/make-bundle.sh    # produces "build/Remote Viewer.app"
```

The script can be run from any directory and is re-runnable — it wipes and
recreates the bundle every time. It honours three environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BUILD_DIR` | `build` | configured meson build directory to install from |
| `APP_DIR` | `$BUILD_DIR/Remote Viewer.app` | output bundle |
| `BREW_PREFIX` | `$(brew --prefix)` | where the runtime data is copied from |

It finishes by printing the bundle path and its size.

### What ends up in the bundle

```
Remote Viewer.app/Contents/
├── Info.plist                     generated from build-aux/macos/Info.plist.in
├── PkgInfo                        "APPL????"
├── MacOS/
│   ├── remote-viewer-launcher     CFBundleExecutable (see below)
│   ├── remote-viewer
│   └── virt-viewer
└── Resources/
    ├── remote-viewer.icns
    ├── lib/                       all non-system dylibs, plus the dlopen()ed
    │                              gdk-pixbuf loaders, GTK immodules and their
    │                              caches
    └── share/                     locale, icons/hicolor, icons/Adwaita,
                                   glib-2.0/schemas, mime
```

* **Libraries** are copied and relinked by `dylibbundler` to
  `@executable_path/../Resources/lib/`. The script runs it twice — once over
  the two executables, then once over every bundled `.so` module, because
  modules are `dlopen()`ed and so are invisible to the first dependency walk.
  It then fails the build if any `otool -L` line in the bundle still points at
  `/opt/homebrew` or `/usr/local`.
* **Runtime data that meson does not install** is copied from the Homebrew
  prefix: the GSettings schemas (recompiled with `glib-compile-schemas`), the
  shared MIME database (rebuilt with `update-mime-database` so virt-viewer's
  own `.vv` type is registered), and the Adwaita icon theme. Only the
  `16x16 22x22 24x24 32x32 48x48 scalable symbolic` subtrees of Adwaita are
  taken, which is what keeps the bundle small. Homebrew resource symlinks are
  dereferenced while copying, so the result does not depend on Cellar paths.
* **The icon** is built with `sips` + `iconutil` from `icons/*/virt-viewer.png`.
  The tree only ships up to 256×256, so the 64, 128, 512 and 1024 px iconset
  members are derived from the 256 px master.

### What is deliberately *not* bundled

* **GStreamer plugins.** SPICE audio and GStreamer-based video decoding are out
  of scope for the bundle; the `libgst*` dylibs that spice-gtk links against are
  bundled, but no plugins (`lib/gstreamer-1.0/`) are, so audio playback does not
  work from the `.app`. Run the binary from a Homebrew build if you need it.
* **oVirt support** (`govirt-1.0`, `rest-1.0`) — no Homebrew formula, so it is
  auto-disabled at configure time and cannot be bundled.
* **GIO modules** (`lib/gio/modules`, e.g. glib-networking's TLS backend).
  SPICE and VNC do their own TLS, so nothing in the bundle needs them.
* **Linux desktop metadata** — `share/applications` and `share/metainfo` are
  installed by meson but have no meaning inside a `.app`.

### Why there is a launcher script

`CFBundleExecutable` is `remote-viewer-launcher`, a small shell script that
`exec`s the real `remote-viewer` next to it. It exists for exactly two
environment variables:

* `GDK_PIXBUF_MODULE_FILE` → `Resources/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache`
* `GTK_IM_MODULE_FILE` → `Resources/lib/gtk-3.0/3.0.0/immodules.cache`

Both must be **absolute** paths, which rules out baking them into `Info.plist`
as `LSEnvironment` entries: a relocatable app does not know at build time where
it will be installed. The launcher resolves them from its own location at
startup instead. The module paths *inside* those two caches are stored relative
to the cache file, which both gdk-pixbuf and GTK resolve against the cache's
directory — so the caches survive relocation too.

Everything else is handled inside the binary rather than by the launcher: as
described under "Running from a bundle" below, `virt_viewer_util_init()`
derives the locale directory, `XDG_DATA_DIRS` and `GSETTINGS_SCHEMA_DIR` from
the bundle at runtime. The launcher also drops a `-psn_0_...` argument if
LaunchServices adds one, which the option parser would otherwise reject.

### Signing

`make-bundle.sh` ad-hoc signs the result (`codesign --force --deep --sign -`)
and verifies it. An ad-hoc signature is enough to run the app locally and to
satisfy the hardened-runtime checks of libraries loaded from the bundle, but
Gatekeeper will still quarantine it after a download.

To ship the bundle, re-sign it with a Developer ID Application certificate:

```sh
codesign --force --deep --timestamp --options runtime \
         --sign "Developer ID Application: Your Name (TEAMID)" \
         "build/Remote Viewer.app"
codesign --verify --deep --strict --verbose=2 "build/Remote Viewer.app"
```

Notarization (`xcrun notarytool submit` + `xcrun stapler staple`) is not covered
by this script.

## Distribution

### Homebrew formula

`build-aux/macos/virt-viewer.rb` is a head-only Homebrew formula for the
`mac-port` branch. Install it directly from a checkout with:

```sh
brew install --HEAD --formula ./build-aux/macos/virt-viewer.rb
```

To use it from a local tap instead, create a tap and copy the formula into it:

```sh
brew tap-new local/virt-viewer
cp build-aux/macos/virt-viewer.rb \
   "$(brew --repository local/virt-viewer)/Formula/virt-viewer.rb"
brew install --HEAD local/virt-viewer/virt-viewer
```

The formula builds and installs the command-line `remote-viewer` and
`virt-viewer` programs. It does not create the standalone application bundle.

### Disk image

After building the application bundle, package it in a compressed DMG with:

```sh
bash build-aux/macos/make-bundle.sh
bash build-aux/macos/make-dmg.sh
```

By default the input is `build/Remote Viewer.app` and the output is
`build/RemoteViewer-<version>.dmg`, where `<version>` comes from the bundle's
`Info.plist`. The disk image contains the application and an `Applications`
symlink for drag-and-drop installation. To use other paths, pass the app bundle
and output DMG as the first and second arguments:

```sh
bash build-aux/macos/make-dmg.sh \
    "/path/to/Remote Viewer.app" "/path/to/RemoteViewer.dmg"
```

Creating the DMG does not add Developer ID signing or notarization; the
signing notes above still apply to a distributed build.

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

## macOS integration

virt-viewer and remote-viewer optionally integrate with the Cocoa desktop
through [gtk-mac-integration](https://gitlab.gnome.org/GNOME/gtk-mac-integration)
(Homebrew: `brew install gtk-mac-integration`, pkg-config module
`gtk-mac-integration-gtk3`).

### Build option

    -Dmacos_integration=auto|enabled|disabled     (default: auto)

The dependency is only ever looked up when the host system is `darwin`; on
Linux and Windows the option is ignored entirely, so nothing about those
builds changes. With `auto` the integration is compiled in whenever
`gtk-mac-integration-gtk3` is installed, and silently skipped when it is not.

When the dependency is found, meson defines `HAVE_GTK_MAC_INTEGRATION` in
`config.h` and adds `src/virt-viewer-macos.c` to the build; that file is the
only place the library is used, and every call site in the portable sources is
wrapped in `#ifdef HAVE_GTK_MAC_INTEGRATION`.

### What it does

* **Global menu bar.** The menus normally reached through the header bar
  buttons (Machine, Send key, More actions) also appear in the macOS menu bar
  at the top of the screen. The header bar buttons stay where they are — the
  two are views of the same `GMenu` models, so the Machine menu keeps listing
  displays as they come and go, and the Send key menu follows the configured
  release-cursor hotkey.
* **Quartz accelerators.** GTK renders accelerators the Cocoa way, so
  `<Control>` accelerators are shown and handled as ⌘ combinations.
* **Quit / ⌘Q.** Quitting from the application menu goes through the normal
  `virt_viewer_app_maybe_quit()` path, so the "Do you want to close the
  session?" confirmation still appears and cancelling it really does cancel.
  Cocoa's own termination is always vetoed; the app exits through
  `g_application_quit()` instead.
* **About.** The application menu's About item opens the usual About dialog.
* **Dock reopen.** Activating the app from the Dock un-minimizes any window
  the user had minimized.

### How the menu bar is built

Unlike a classic GTK application, virt-viewer has no in-window `GtkMenuBar` to
hand over: its menus are `GtkMenuButton` popovers in the header bar. Each
`VirtViewerWindow` therefore builds an extra `GtkMenuBar` from the same menu
models and passes it to `virt_viewer_macos_window_set_menubar()`, which mirrors
it into the Cocoa menu bar.

That extra bar is packed hidden under the window as an overlay child of
`viewer-overlay` and marked `no-show-all`, so it is never drawn. Packing it
there makes `gtk_widget_get_toplevel()` return the real `GtkWindow`, allowing
gtk-mac-integration to install the mirrored menu accelerators on that window.
Being inside the `GtkApplicationWindow` also lets the bar's items resolve
their `win.*` and `app.*` actions, exactly as the header bar popovers do.

Because there is one Cocoa menu bar but one `GtkMenuBar` per window, the menu
bar is re-pointed at whichever window is active (`notify::is-active`). With
several displays open, the menu bar therefore always reflects the focused
window.

### Known limitations

* Accelerators defined in the `GtkAccelGroup` of `virt-viewer.ui` rather than
  on the menu model itself are not shown next to the mirrored menu items.
  The shortcuts still work; only the labels in the macOS menu bar are blank.
* About appears twice: once in the application menu (Cocoa's own slot) and
  once inside the "More actions" menu, which is the same item the header bar
  popover shows.
* Dock reopen only un-minimizes windows. It deliberately does not
  `gtk_window_present()` anything, which with several open displays would pull
  focus away from the window the user clicked on.
* `.vv` file and `spice://` / `vnc://` URL handling is *not* part of this
  integration; the `NSApplicationOpenFile` signal is intentionally left
  unconnected here.
* Building with `-Dmacos_integration=disabled` (or on a machine without the
  library) produces a working application with the plain GTK behaviour: menus
  only in the header bar, and no macOS menu bar.
