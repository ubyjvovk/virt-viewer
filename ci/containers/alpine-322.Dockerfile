# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

FROM docker.io/library/alpine:3.22

RUN apk update && \
    apk upgrade && \
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
        rest1-dev \
        samurai \
        spice-gtk-dev \
        vte3-dev && \
    apk list --installed | sort > /packages.txt && \
    mkdir -p /usr/libexec/ccache-wrappers && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/cc && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/gcc

ENV CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
ENV LANG="en_US.UTF-8"
ENV MAKE="/usr/bin/make"
ENV NINJA="/usr/bin/ninja"
