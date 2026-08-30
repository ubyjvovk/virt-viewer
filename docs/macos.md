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
## Keyboard

### Default hotkeys

Global hotkeys (see `--hotkeys` in the man pages) only fire while the guest
display widget does *not* have input focus. Their defaults follow the
upstream Ctrl+Alt combinations and are therefore awkward on a Mac keyboard:

| Action | Default binding | Mac equivalent |
| --- | --- | --- |
| release-cursor | `ctrl+alt` | `ctrl+option` |
| secure-attention | `ctrl+alt+del` | (via menu, below) |

`--hotkeys` accepts case-insensitive modifier tokens `shift`, `ctrl`, `alt`,
`cmd` and `meta`. On macOS only, both `cmd` and `meta` select the **Command**
key, while **Option** is selected with `alt`. On other platforms, `cmd`
retains its legacy meaning as an alias for `ctrl`. For example:

```sh
remote-viewer --hotkeys=release-cursor=cmd+alt+r
```

binds ⌘⌥R (spelt `cmd+alt+r`) as the release-cursor hotkey.

### Sending Ctrl+Alt+Del

The guest sees nothing of the host's Command key, and hotkeys containing
`cmd`/`meta` never reach the guest. To send a key combination (such as
Ctrl+Alt+Del for a Windows guest) to the guest, use the **Send key** menu (header bar *Send key* button):
*Send key* → *Ctrl+Alt+Del*. This goes through the guest channel
and is unaffected by the host hotkey bindings.

> For more on the Send key menu and how its accelerators are handled on
> quartz, see `virt_viewer_window_send_keys()` in `src/virt-viewer-window.c`
> and the bottom-left header bar "Send key" button.
