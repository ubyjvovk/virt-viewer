# virt-viewer on macOS

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
