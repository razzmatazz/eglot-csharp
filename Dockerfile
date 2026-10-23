# EMACS is the GNU release to build, e.g. 30.2 or 31.1.  Ubuntu 26.04
# packages only Emacs 30, so every version is built the same way.
ARG EMACS=31.1

FROM ubuntu:26.04 AS build

ARG EMACS

# GnuTLS is for fetching packages.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential pkg-config curl ca-certificates xz-utils \
      libgnutls28-dev libncurses-dev zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL --retry 5 https://ftp.gnu.org/gnu/emacs/emacs-${EMACS}.tar.xz | tar xJ -C /tmp && \
    cd /tmp/emacs-${EMACS} && \
    ./configure --prefix=/opt/emacs \
                --without-x --without-native-compilation \
                --without-sound --without-dbus --without-selinux && \
    make -j"$(nproc)" && \
    make install

FROM ubuntu:26.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl git ca-certificates unzip \
      libgnutls30t64 libncurses6 zlib1g && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/emacs /opt/emacs
ENV PATH="/opt/emacs/bin:/root/.local/bin:$PATH"

RUN curl -fsSL https://raw.githubusercontent.com/emacs-eask/cli/master/webinstall/install.sh | sh
