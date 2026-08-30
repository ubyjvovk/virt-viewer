class VirtViewer < Formula
  desc "Graphical console client for virtual machines"
  homepage "https://virt-manager.org/"
  head "https://github.com/ubyjvovk/virt-viewer.git", branch: "mac-port"
  license "GPL-2.0-or-later"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => :build
  depends_on "adwaita-icon-theme"
  depends_on "gettext"
  depends_on "gtk+3"
  depends_on "gtk-mac-integration"
  depends_on "gtk-vnc"
  depends_on "libvirt"
  depends_on "libvirt-glib"
  depends_on "libxml2"
  depends_on "spice-gtk"
  depends_on "spice-protocol"
  depends_on "vte3"

  def install
    system "meson", "setup", "build", *std_meson_args
    system "ninja", "-C", "build"
    system "ninja", "-C", "build", "install"
  end

  test do
    system bin/"remote-viewer", "--version"
  end
end
