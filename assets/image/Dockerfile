# syntax=docker/dockerfile:1.7

# Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
# Distributed under the terms of the Apache License, Version 2.0.

# ---------- Build Stage - Rust CLI tools ----------
FROM rust:1.93-alpine3.22 AS rust-builder

RUN apk add --no-cache \
        build-base \
        cmake \
        pkgconf

RUN cargo install \
        --locked \
        --root /opt/rust-tools \
        --version 0.0.34 \
        chromsize \
    && cargo install \
        --all-features \
        --locked \
        --root /opt/rust-tools \
        --version 0.0.13 \
        chaintools \
    && cargo install \
        --all-features \
        --locked \
        --force \
        --root /opt/rust-tools \
        --version 0.0.3 \
        psltools \
    && cargo install \
        --all-features \
        --locked \
        --root /opt/rust-tools \
        --version 0.0.1 \
        chainc

# ---------- Build Stage - LASTZ ----------
FROM alpine:3.22 AS lastz-builder

RUN apk add --no-cache \
        build-base \
        ca-certificates \
        curl

COPY assets/image/SHA256SUMS /tmp/SHA256SUMS

RUN curl -fsSL \
        https://github.com/lastz/lastz/archive/refs/tags/1.04.60.tar.gz \
        -o /tmp/lastz-1.04.60.tar.gz \
    && cd /tmp \
    && grep ' lastz-1.04.60.tar.gz$' SHA256SUMS | sha256sum -c - \
    && tar -xzf lastz-1.04.60.tar.gz \
    && make -C /tmp/lastz-1.04.60/src -j"$(getconf _NPROCESSORS_ONLN)" lastz \
    && install -Dm0755 /tmp/lastz-1.04.60/src/lastz /opt/lastz/bin/lastz \
    && strip /opt/lastz/bin/lastz

# ---------- Build Stage - UCSC Kent tools ----------
FROM alpine:3.22 AS kent-builder

RUN apk add --no-cache \
        bash \
        build-base \
        bzip2-dev \
        ca-certificates \
        curl \
        libpng-dev \
        linux-headers \
        openssl-dev \
        util-linux-dev \
        zlib-dev

COPY assets/image/SHA256SUMS /tmp/SHA256SUMS

RUN curl -fsSL \
        https://github.com/ucscGenomeBrowser/kent/archive/refs/tags/v482_base.tar.gz \
        -o /tmp/kent-v482.tar.gz \
    && cd /tmp \
    && grep ' kent-v482.tar.gz$' SHA256SUMS | sha256sum -c - \
    && mkdir -p /build/kent-482 \
    && tar -xzf kent-v482.tar.gz -C /build/kent-482 --strip-components=1

# Kent utility makefiles link the large jkhgap database archive for all tools
# under src/hg. These selected CLIs only use jkweb, so link that archive alone
# and bypass the corresponding unused MySQL development-system requirement.
RUN set -eux; \
    build_kent() { \
        src="$1"; \
        out="$2"; \
        shift 2; \
        printf '%s\n' \
            "export DESTDIR = ${out}" \
            'export BINDIR = /bin' \
            'export MACHTYPE = local' \
            'export NOSQLTEST = 1' \
            > "${src}/src/inc/localEnvironment.mk"; \
        make -C "${src}/src/htslib" -j"$(getconf _NPROCESSORS_ONLN)" USE_HIC=0 MYSQLINC=/usr/include MYSQLLIBS=-lm; \
        make -C "${src}/src/lib" -j"$(getconf _NPROCESSORS_ONLN)" USE_HIC=0 MYSQLINC=/usr/include MYSQLLIBS=-lm; \
        for tool in "$@"; do \
            make -C "${src}/src/${tool}" \
                -j"$(getconf _NPROCESSORS_ONLN)" \
                compile \
                USE_HIC=0 \
                MYSQLINC=/usr/include \
                MYSQLLIBS=-lm \
                DEPLIBS="${src}/src/lib/local/jkweb.a" \
                LINKLIBS="${src}/src/lib/local/jkweb.a"; \
            install -Dm0755 \
                "${src}/src/${tool}/$(basename "${tool}")" \
                "${out}/bin/$(basename "${tool}")"; \
            strip "${out}/bin/$(basename "${tool}")"; \
        done; \
    }; \
    build_kent /build/kent-482 /opt/kent-482 \
        utils/faToTwoBit \
        utils/twoBitToFa \
        hg/mouseStuff/axtChain \
        hg/mouseStuff/axtToPsl \
        hg/mouseStuff/chainSort

# ---------- Build Stage - trimmed Python ----------
# pip/setuptools/wheel, ensurepip and the IDLE/Tk/2to3/pydoc data (~18 MB) are never used by the pipeline's scripts,
# and files of a base image cannot be dropped in a later layer, so the runtime gets a trimmed copy of /usr/local.
FROM python:3.11-alpine3.22 AS python-trim

RUN cd /usr/local/lib/python3.11 \
    && rm -rf site-packages/pip site-packages/pip-* \
        site-packages/setuptools site-packages/setuptools-* site-packages/pkg_resources \
        site-packages/_distutils_hack site-packages/distutils-precedence.pth \
        site-packages/wheel site-packages/wheel-* \
        ensurepip idlelib tkinter turtledemo turtle.py lib2to3 pydoc_data \
    && rm -f /usr/local/bin/pip* /usr/local/bin/idle* /usr/local/bin/2to3* /usr/local/bin/pydoc* /usr/local/bin/wheel

# ---------- Runtime Stage ----------
FROM alpine:3.22 AS runtime

ARG MODULE_VERSION
LABEL module.version="${MODULE_VERSION}"
RUN echo "Building version ${MODULE_VERSION}"

ENV LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /work

# bash, GNU grep/gzip and procps (ps) for the task scripts and Nextflow's wrapper; libssl/libcrypto/zlib for the
# Kent tools; the rest are the shared libraries of python:3.11-alpine3.22 (its .python-rundeps).
RUN apk add --no-cache \
        bash \
        ca-certificates \
        grep \
        gzip \
        procps \
        so:libbz2.so.1 \
        so:libcrypto.so.3 \
        so:libffi.so.8 \
        so:libgdbm.so.6 \
        so:libgdbm_compat.so.4 \
        so:liblzma.so.5 \
        so:libncursesw.so.6 \
        so:libnsl.so.3 \
        so:libpanelw.so.6 \
        so:libreadline.so.8 \
        so:libsqlite3.so.0 \
        so:libssl.so.3 \
        so:libtirpc.so.3 \
        so:libuuid.so.1 \
        so:libz.so.1

COPY --from=python-trim /usr/local /usr/local

COPY --from=rust-builder /opt/rust-tools/bin/chaintools /usr/local/bin/chaintools
COPY --from=rust-builder /opt/rust-tools/bin/chromsize /usr/local/bin/chromsize
COPY --from=rust-builder /opt/rust-tools/bin/psltools /usr/local/bin/psltools
COPY --from=rust-builder /opt/rust-tools/bin/chainc /usr/local/bin/chainc
COPY --from=lastz-builder /opt/lastz/bin/lastz /usr/local/bin/lastz
COPY --from=kent-builder /opt/kent-482/bin/ /usr/local/bin/

COPY --from=ghcr.io/hillerlab/repeat_filler:latest /usr/local/bin/repeat_filler.py /usr/local/bin/repeat_filler.py
COPY bin/partition.py /usr/local/bin/partition.py
COPY bin/psl_bundle.py /usr/local/bin/psl_bundle.py
COPY bin/run_keg_lastz.py /usr/local/bin/run_keg_lastz.py
COPY bin/run_lastz.py /usr/local/bin/run_lastz.py
COPY bin/run_lastz_intermediate_layer.py /usr/local/bin/run_lastz_intermediate_layer.py

RUN chmod 0755 \
        /usr/local/bin/partition.py \
        /usr/local/bin/psl_bundle.py \
        /usr/local/bin/repeat_filler.py \
        /usr/local/bin/run_keg_lastz.py \
        /usr/local/bin/run_lastz.py \
        /usr/local/bin/run_lastz_intermediate_layer.py \
    && ln -s /usr/local/bin/repeat_filler.py /usr/local/bin/repeat_filler \
    && test -x /bin/bash \
    && ps --version >/dev/null \
    && python --version 2>&1 | grep -q '^Python 3\.11\.' \
    && python -c 'import bz2, concurrent.futures, gzip, hashlib, json, lzma, sqlite3, ssl, subprocess' \
    && chaintools --version \
    && chaintools stats --help >/dev/null \
    && chaintools coverage --help >/dev/null \
    && chromsize --version \
    && psltools --version \
    && chainc --version \
    && { lastz --version || test "$?" -eq 1; } \
    && repeat_filler --help >/dev/null \
    && partition.py --help >/dev/null \
    && psl_bundle.py --help >/dev/null \
    && run_keg_lastz.py --help >/dev/null \
    && run_lastz.py --help >/dev/null \
    && run_lastz_intermediate_layer.py --help >/dev/null \
    && for command in \
        axtChain \
        axtToPsl \
        chainSort \
        faToTwoBit \
        twoBitToFa; \
    do \
        command -v "${command}" >/dev/null || { echo "missing ${command}" >&2; exit 1; }; \
    done

CMD ["/bin/bash"]
