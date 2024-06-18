# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

function install_buildenv() {
    apk update
    apk upgrade
    apk add \
        bash-completion \
        ca-certificates \
        ccache \
        gcc \
        gettext \
        git \
        glib-dev \
        gtk+3.0-dev \
        gtk-vnc-dev \
        icoutils \
        libtool \
        libvirt-dev \
        libvirt-glib-dev \
        libxml2-dev \
        libxml2-utils \
        make \
        meson \
        musl-dev \
        pkgconf \
        rest-dev \
        samurai \
        spice-gtk-dev \
        vte3-dev
    apk list --installed | sort > /packages.txt
    mkdir -p /usr/libexec/ccache-wrappers
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/cc
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/gcc
}
function export_buildenv() {

export CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
export LANG="en_US.UTF-8"
export MAKE="/usr/bin/make"
export NINJA="/usr/bin/ninja"
}
