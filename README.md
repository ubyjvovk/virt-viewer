# Virt Viewer

Virt Viewer provides a graphical viewer for the guest OS
display. At this time is supports guest OS using the VNC
or SPICE protocols. Further protocols may be supported in
the future as user demand dictates. The viewer can connect
directly to both local and remotely hosted guest OS, optionally
using SSL/TLS encryption.

Virt Viewer is the GTK3 application. Virt Viewer 3.0 was
the last release that supported GTK2.

Virt Viewer uses the GTK-VNC (>= 0.4.0) widget to provide a
display of the VNC protocol, which is available from

  https://wiki.gnome.org/Projects/gtk-vnc

Virt Viewer uses the SPICE-GTK (>= 0.35) widget to provide a
display of the SPICE protocol, which is available from:

  https://www.spice-space.org/download.html

Use of either SPICE-GTK or GTK-VNC can be disabled at time
of configure, with `--without-gtk-vnc` or `--without-spice-gtk`
respectively.

Virt Viewer uses libvirt to lookup information about the
guest OS display. This is available from

  https://libvirt.org/

Bug reports / support questions should be submitted to

  https://gitlab.com/virt-viewer/virt-viewer/-/issues

Code contributions should be submitted as merge requests to

  https://gitlab.com/virt-viewer/virt-viewer/-/merge_requests

## macOS

For native macOS prerequisites, build and test instructions, and current
feature availability, see [Building on macOS](docs/macos.md).
