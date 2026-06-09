# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

function install_buildenv() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get dist-upgrade -y
    apt-get install --no-install-recommends -y \
            bash-completion \
            ca-certificates \
            ccache \
            gcc \
            gettext \
            git \
            icoutils \
            libc6-dev \
            libglib2.0-dev \
            libgtk-3-dev \
            libgtk-vnc-2.0-dev \
            librest-dev \
            libspice-client-gtk-3.0-dev \
            libtool \
            libtool-bin \
            libvirt-dev \
            libvirt-glib-1.0-dev \
            libvte-2.91-dev \
            libxml2-dev \
            libxml2-utils \
            locales \
            make \
            meson \
            ninja-build \
            pkgconf
    sed -Ei 's,^# (en_US\.UTF-8 .*)$,\1,' /etc/locale.gen
    dpkg-reconfigure locales
    dpkg-query --showformat '${Package}_${Version}_${Architecture}\n' --show > /packages.txt
    mkdir -p /usr/libexec/ccache-wrappers
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/cc
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/gcc
}

export CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
export LANG="en_US.UTF-8"
export MAKE="/usr/bin/make"
export NINJA="/usr/bin/ninja"
