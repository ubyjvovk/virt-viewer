# macOS port notes

This file documents macOS-specific behaviour of the virt-viewer /
remote-viewer port. Sections are self-contained so they can be merged
independently.

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
