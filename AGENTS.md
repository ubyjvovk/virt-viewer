# Agent orientation — virt-viewer macOS port

<!-- Maintained by the Tiger Team PM. Workers read this first; workers never
     edit it. -->

## What this project is
virt-viewer / remote-viewer: a GTK3 (C, GLib/GObject) client for SPICE and
VNC displays of virtual machines (upstream: gitlab.com/virt-viewer/virt-viewer).
This branch (`mac-port`) carries TWO tracks:

1. **GTK macOS port (COMPLETE — maintenance only).** Builds against Homebrew
   libraries, ships as a `.app` bundle, integrates with macOS (menu bar, Cmd
   shortcuts, URL/`.vv` handlers). Assembled as an upstream merge-request
   series on branch `mac-port-pr`; every change here must be platform-guarded
   (`#ifdef __APPLE__` in C, `host_machine.system() == 'darwin'` in meson)
   and must not alter Linux/Windows behaviour. GTK window-management bug
   FIXING is abandoned by user decision (2026-09-01) — those defects are
   documented in docs/macos.md "Known issues"; do not fix them.

2. **Native macOS SPICE viewer (`macos-native/`) — the ACTIVE track.** A
   from-scratch Cocoa client over spice-client-glib: IOSurface/CALayer
   rendering, keycodemapdb-generated osx→xtkbd keyboard, absolute mouse.
   Zero GTK; standalone build, deliberately OUTSIDE the meson tree. Read
   `macos-native/README.md` before touching it.

## Layout
- `meson.build`, `meson_options.txt` — top-level build; per-dir `meson.build`
- `src/` — all C sources. `virt-viewer-app.c` (GtkApplication, CLI options,
  hotkeys), `virt-viewer-window.c` (per-window UI, menus, fullscreen),
  `virt-viewer-util.c` (init, locale, helpers), `remote-viewer*.c`
  (remote-viewer binary), `virt-viewer.c` (libvirt-based binary),
  `src/resources/` — GTK builder `.ui` files compiled into a gresource
- `tests/` — 4 GLib tests (`meson test`)
- `build-aux/` — build helper scripts; `build-aux/macos/` — macOS-only helpers
- `data/` — desktop/mime/appdata (Linux-only install), `icons/` — app icons
- `man/` — POD man pages, `docs/` — project docs (put `docs/macos.md` here)
- `ci/` — upstream GitLab CI (lcitool-generated; do NOT hand-edit `ci/`)
- `macos-native/` — the native viewer: `vsm-spice.c` (GLib-thread SPICE
  session, damage→IOSurface blit, cross-thread input marshalling), `main.m`
  (NSApplication, window, `VsmView` responder methods), `vsm-keymap.c`
  (generated osx→xtkbd table), `vsm-debug.m` (frame dump + input self-test),
  `build.sh`, `README.md`
- `.tigerteam/` — ticket board; not part of the product

## Conventions
- C: gnu99, GLib style (4-space indent, `g_*` APIs, GObject boilerplate,
  `g_autoptr`/`g_autofree`). Builds with `-Werror` when in git: **zero
  warnings**. Prototypes for every non-static function; static otherwise.
- Platform code: `#ifdef __APPLE__` (not `G_OS_DARWIN` — GLib has none).
  Existing `G_OS_WIN32` blocks show the pattern; macOS is `G_OS_UNIX`.
- Meson: gate darwin-only deps/targets on `host_machine.system() == 'darwin'`;
  new optional features get a `meson_options.txt` feature (`auto` default).
- Objective-C is allowed only in darwin-gated files (`src/*-macos.m`) and only
  if plain C / CoreFoundation cannot do the job.
- Shell scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, run from any cwd.
- Docs live in `docs/macos.md`; keep the man pages (`man/*.pod`) in sync when
  CLI behaviour changes.
- `macos-native/`: Objective-C with ARC, `-Wall -Wextra -Werror`, C for the
  SPICE/GLib layer. AppKit only on the main thread; all spice-glib calls on
  the GLib thread; marshal between them (dispatch_async up,
  g_main_context_invoke-style down). No GTK includes, no meson — build only
  via `bash macos-native/build.sh`.

## Config
- Project config is root `tigerteam.toml` (optional `~/.tigerteam.toml` for
  machine-local facts).
- `test_cmd = bash build-aux/macos/check.sh` — the runner injects it as
  `TIGERTEAM_TEST_CMD`.

## Commands
- Tests: `bash .tigerteam/scripts/run-tests.sh` (the ONLY way to run tests).
  It configures `build/` on first run, compiles, runs `meson test`. Full
  log path is printed; grep it, never cat it whole.
- Direct build (same thing): `bash build-aux/macos/check.sh`
- Binaries after build: `build/src/remote-viewer`, `build/src/virt-viewer`
- Native viewer: `bash macos-native/build.sh` →
  `macos-native/build/spice-viewer <spice://host:port>` (run-tests.sh does
  NOT cover it; it must still exit 0 to prove the meson tree is untouched)
- Homebrew deps are already installed on this host: meson ninja pkgconf gtk+3
  gtk-vnc spice-gtk spice-protocol libvirt libvirt-glib vte3 libxml2
  gettext adwaita-icon-theme gtk-mac-integration dylibbundler.
  `PKG_CONFIG_PATH` must include `$(brew --prefix)/opt/libxml2/lib/pkgconfig`
  (check.sh does this).

## Landmarks & gotchas
- The tree ALREADY builds and passes tests on macOS unmodified. The port work
  is packaging/integration, not compile fixes. Keep it that way.
- Sandboxed workers cannot open GUI windows, `open` apps, or write outside the
  worktree. Tickets tagged `capability: [macbuild]` run unsandboxed and may
  launch the app / take screenshots.
- `-Werror` is on (git checkout). Clang: a stray unused variable fails the build.
- `LOCALE_DIR` is baked in from the meson prefix — wrong inside a relocatable
  `.app`; darwin code must derive paths from the bundle at runtime.
- oVirt (`govirt`) and bash-completion are not available on macOS/Homebrew;
  they are auto-disabled — do not try to enable them.
- `build/` is gitignored; put QA screenshots/reports under `build/qa/`
  (preserved as artifacts by the board).
- **spice-glib context gotcha:** its coroutines self-schedule with
  `g_idle_add`/`g_timeout_add_full` — the GLOBAL default GMainContext — so a
  private per-thread GMainContext silently stalls the session after the main
  channel appears. Run the DEFAULT context's loop on the dedicated GLib
  thread instead (macos-native/vsm-spice.c shows the pattern).
- Live test target for native tickets: the ticket names the URI (a
  disposable user VM — treat with care: no destructive/power key sequences).
  If a guest unlock password is needed, the ticket will point at a root
  `.env` variable; use the value as typed input only, never echo it into
  reports, logs, or commits.
- The engine wall-clock ceiling is ≈45 min: commit early and often; hand
  off INCOMPLETE with precise next steps rather than pushing through.
- **Never `pkill -f <pattern>`.** Sibling workers' and the PM's command lines
  contain the same paths and app names (`build/src/remote-viewer`,
  `Remote Viewer.app`), so a pattern kill takes them down too (incident
  2026-08-30: it killed another worker mid-ticket). Record the PID of every
  process you start (`cmd & p=$!`) and `kill "$p"` that exact PID.
