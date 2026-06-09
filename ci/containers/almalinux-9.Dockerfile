# THIS FILE WAS AUTO-GENERATED
#
#  $ lcitool manifest ci/manifest.yml
#
# https://gitlab.com/libvirt/libvirt-ci

FROM docker.io/library/almalinux:9

RUN dnf --quiet update -y && \
    dnf --quiet install 'dnf-command(config-manager)' -y && \
    dnf --quiet config-manager --set-enabled -y crb && \
    dnf --quiet install -y epel-release && \
    dnf --quiet install almalinux-release-devel -y && \
    dnf --quiet config-manager --set-enabled -y devel && \
    dnf --quiet install -y \
                bash-completion \
                ca-certificates \
                ccache \
                cpp \
                cyrus-sasl-devel \
                gcc \
                gdk-pixbuf2-devel \
                gettext \
                git \
                glib2-devel \
                glibc-devel \
                glibc-langpack-en \
                gnutls-devel \
                gobject-introspection-devel \
                gtk-doc \
                gtk3-devel \
                icoutils \
                libgcrypt-devel \
                libnl3-devel \
                libtirpc-devel \
                libtool \
                libxml2 \
                libxml2-devel \
                libxslt \
                make \
                meson \
                ninja-build \
                perl-base \
                pkgconfig \
                pulseaudio-libs-devel \
                python3 \
                python3-docutils \
                rpm-build \
                vala \
                vte291-devel && \
    dnf --quiet autoremove -y && \
    dnf --quiet clean all -y && \
    rm -f /usr/lib*/python3*/EXTERNALLY-MANAGED && \
    rpm -qa | sort > /packages.txt && \
    mkdir -p /usr/libexec/ccache-wrappers && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/cc && \
    ln -s /usr/bin/ccache /usr/libexec/ccache-wrappers/gcc

ENV CCACHE_WRAPPERSDIR="/usr/libexec/ccache-wrappers"
ENV LANG="en_US.UTF-8"
ENV MAKE="/usr/bin/make"
ENV NINJA="/usr/bin/ninja"
ENV PYTHON="/usr/bin/python3"
