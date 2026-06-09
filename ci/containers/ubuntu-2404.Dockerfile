# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

FROM docker.io/library/ubuntu:24.04

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y eatmydata && \
    eatmydata apt-get dist-upgrade -y && \
    eatmydata apt-get install --no-install-recommends -y \
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
                      pkgconf && \
    eatmydata apt-get autoremove -y && \
    eatmydata apt-get autoclean -y && \
    sed -Ei 's,^# (en_US\.UTF-8 .*)$,\1,' /etc/locale.gen && \
    dpkg-reconfigure locales && \
    dpkg-query --showformat '${Package}_${Version}_${Architecture}\n' --show > /packages.txt && \
    mkdir -p /usr/libexec/ccache-wrappers && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/cc && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/gcc

ENV CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
ENV LANG="en_US.UTF-8"
ENV MAKE="/usr/bin/make"
ENV NINJA="/usr/bin/ninja"
