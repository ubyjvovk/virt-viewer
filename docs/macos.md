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
