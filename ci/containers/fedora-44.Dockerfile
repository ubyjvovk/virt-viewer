# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

FROM registry.fedoraproject.org/fedora:44

RUN dnf --quiet install -y nosync && \
    printf '#!/bin/sh\n\
if test -d /usr/lib64\n\
then\n\
    export LD_PRELOAD=/usr/lib64/nosync/nosync.so\n\
else\n\
    export LD_PRELOAD=/usr/lib/nosync/nosync.so\n\
fi\n\
exec "$@"\n' > /usr/bin/nosync && \
    chmod +x /usr/bin/nosync && \
    nosync dnf --quiet update -y && \
    nosync dnf --quiet install -y \
                       bash-completion-devel \
                       ca-certificates \
                       ccache \
                       cppi \
                       gcc \
                       gettext \
                       git \
                       glib2-devel \
                       glibc-devel \
                       glibc-langpack-en \
                       gtk-vnc2-devel \
                       gtk3-devel \
                       icoutils \
                       libgovirt-devel \
                       libtool \
                       libvirt-devel \
                       libvirt-glib-devel \
                       libxml2 \
                       libxml2-devel \
                       make \
                       meson \
                       ninja-build \
                       pkgconfig \
                       rest-devel \
                       rpm-build \
                       spice-gtk3-devel \
                       vte291-devel && \
    nosync dnf --quiet autoremove -y && \
    nosync dnf --quiet clean all -y && \
    rpm -qa | sort > /packages.txt && \
    mkdir -p /usr/libexec/ccache-wrappers && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/cc && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/gcc

ENV CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
ENV LANG="en_US.UTF-8"
ENV MAKE="/usr/bin/make"
ENV NINJA="/usr/bin/ninja"
