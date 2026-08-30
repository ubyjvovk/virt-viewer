# Agent orientation — virt-viewer macOS port

<!-- Maintained by the Tiger Team PM. Workers read this first; workers never
     edit it. -->

## What this project is
virt-viewer / remote-viewer: a GTK3 (C, GLib/GObject) client for SPICE and
VNC displays of virtual machines (upstream: gitlab.com/virt-viewer/virt-viewer).
This branch (`mac-port`) makes it a first-class **native macOS** application:
builds against Homebrew libraries, ships as a `.app` bundle, integrates with
macOS (menu bar, Cmd shortcuts, URL/`.vv` file handlers). The end product is a
pull request against upstream `master`, so every change must be
platform-guarded (`#ifdef __APPLE__` in C, `host_machine.system() == 'darwin'`
in meson) and must not alter Linux/Windows behaviour.

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
- **Never `pkill -f <pattern>`.** Sibling workers' and the PM's command lines
  contain the same paths and app names (`build/src/remote-viewer`,
  `Remote Viewer.app`), so a pattern kill takes them down too (incident
  2026-08-30: it killed another worker mid-ticket). Record the PID of every
  process you start (`cmd & p=$!`) and `kill "$p"` that exact PID.
