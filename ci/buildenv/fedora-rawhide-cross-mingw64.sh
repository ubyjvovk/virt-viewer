# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

function install_buildenv() {
    dnf update -y --nogpgcheck fedora-gpg-keys
    dnf distro-sync -y
    dnf install -y \
        bash-completion-devel \
        ca-certificates \
        ccache \
        cppi \
        git \
        glibc-langpack-en \
        gtk-vnc2-devel \
        icoutils \
        libtool \
        libxml2 \
        make \
        meson \
        ninja-build \
        rpm-build
    dnf install -y \
        mingw64-gcc \
        mingw64-gettext \
        mingw64-glib2 \
        mingw64-gstreamer1-plugins-bad-free \
        mingw64-gstreamer1-plugins-good \
        mingw64-gtk3 \
        mingw64-headers \
        mingw64-libgovirt \
        mingw64-libvirt \
        mingw64-libxml2 \
        mingw64-pkg-config \
        mingw64-rest \
        mingw64-spice-gtk3
    rpm -qa | sort > /packages.txt
    mkdir -p /usr/libexec/ccache-wrappers
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/x86_64-w64-mingw32-cc
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/x86_64-w64-mingw32-gcc
}
function export_buildenv() {

export CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
export LANG="en_US.UTF-8"
export MAKE="/usr/bin/make"
export NINJA="/usr/bin/ninja"

export ABI="x86_64-w64-mingw32"
export MESON_OPTS="--cross-file=/usr/share/mingw/toolchain-mingw64.meson"
}
