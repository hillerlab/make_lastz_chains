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
        --version 0.0.3 \
        chaintools

# ---------- Build Stage - LASTZ ----------
FROM alpine:3.22 AS lastz-builder

RUN apk add --no-cache \
        build-base \
        ca-certificates \
        curl

COPY images/make_lastz_chains/SHA256SUMS /tmp/SHA256SUMS

RUN curl -fsSL \
        https://github.com/lastz/lastz/archive/refs/tags/1.04.52.tar.gz \
        -o /tmp/lastz-1.04.52.tar.gz \
    && cd /tmp \
    && grep ' lastz-1.04.52.tar.gz$' SHA256SUMS | sha256sum -c - \
    && tar -xzf lastz-1.04.52.tar.gz \
    && make -C /tmp/lastz-1.04.52/src -j"$(getconf _NPROCESSORS_ONLN)" lastz \
    && install -Dm0755 /tmp/lastz-1.04.52/src/lastz /opt/lastz/bin/lastz \
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

COPY images/make_lastz_chains/SHA256SUMS /tmp/SHA256SUMS

RUN curl -fsSL \
        https://github.com/ucscGenomeBrowser/kent/archive/refs/tags/v482_base.tar.gz \
        -o /tmp/kent-v482.tar.gz \
    && curl -fsSL \
        https://github.com/ucscGenomeBrowser/kent/archive/refs/tags/v455_base.tar.gz \
        -o /tmp/kent-v455.tar.gz \
    && cd /tmp \
    && grep ' kent-v482.tar.gz$' SHA256SUMS | sha256sum -c - \
    && grep ' kent-v455.tar.gz$' SHA256SUMS | sha256sum -c - \
    && mkdir -p /build/kent-482 /build/kent-455 \
    && tar -xzf kent-v482.tar.gz -C /build/kent-482 --strip-components=1 \
    && tar -xzf kent-v455.tar.gz -C /build/kent-455 --strip-components=1

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
            extra_link=''; \
            if [ "$(basename "${tool}")" = chainCleaner ]; then \
                make -C "${src}/src/hg/lib" chainNet.o USE_HIC=0 MYSQLINC=/usr/include MYSQLLIBS=-lm; \
                extra_link="${src}/src/hg/lib/chainNet.o"; \
            fi; \
            make -C "${src}/src/${tool}" \
                -j"$(getconf _NPROCESSORS_ONLN)" \
                compile \
                USE_HIC=0 \
                MYSQLINC=/usr/include \
                MYSQLLIBS=-lm \
                DEPLIBS="${src}/src/lib/local/jkweb.a" \
                LINKLIBS="${extra_link} ${src}/src/lib/local/jkweb.a"; \
            install -Dm0755 \
                "${src}/src/${tool}/$(basename "${tool}")" \
                "${out}/bin/$(basename "${tool}")"; \
            strip "${out}/bin/$(basename "${tool}")"; \
        done; \
    }; \
    build_kent /build/kent-482 /opt/kent-482 \
        utils/faToTwoBit \
        utils/twoBitToFa \
        hg/pslSortAcc \
        hg/mouseStuff/axtChain \
        hg/mouseStuff/axtToPsl \
        hg/mouseStuff/chainSort \
        hg/mouseStuff/chainNet; \
    build_kent /build/kent-455 /opt/kent-455 \
        hg/mouseStuff/chainCleaner \
        hg/mouseStuff/chainScore

# ---------- Runtime Stage ----------
FROM python:3.11-alpine3.22 AS runtime

ARG MODULE_VERSION
LABEL module.version="${MODULE_VERSION}"
RUN echo "Building version ${MODULE_VERSION}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /work

RUN apk add --no-cache \
        bash \
        bzip2 \
        ca-certificates \
        grep \
        gzip \
        libpng \
        openssl \
        perl \
        procps \
        zlib

COPY --from=rust-builder /opt/rust-tools/bin/chaintools /usr/local/bin/chaintools
COPY --from=rust-builder /opt/rust-tools/bin/chromsize /usr/local/bin/chromsize
COPY --from=lastz-builder /opt/lastz/bin/lastz /usr/local/bin/lastz
COPY --from=kent-builder /opt/kent-482/bin/ /usr/local/bin/
COPY --from=kent-builder /opt/kent-455/bin/ /usr/local/bin/

COPY modules/chaincleaner/NetFilterNonNested.perl /usr/local/bin/NetFilterNonNested.perl
COPY modules/repeat_filler/repeat_filler.py /usr/local/bin/repeat_filler.py
COPY modules/make_lastz_chains/bin/partition.py /usr/local/bin/partition.py
COPY modules/make_lastz_chains/bin/psl_bundle.py /usr/local/bin/psl_bundle.py
COPY modules/make_lastz_chains/bin/run_lastz.py /usr/local/bin/run_lastz.py
COPY modules/make_lastz_chains/bin/run_lastz_intermediate_layer.py /usr/local/bin/run_lastz_intermediate_layer.py

RUN chmod 0755 \
        /usr/local/bin/NetFilterNonNested.perl \
        /usr/local/bin/partition.py \
        /usr/local/bin/psl_bundle.py \
        /usr/local/bin/repeat_filler.py \
        /usr/local/bin/run_lastz.py \
        /usr/local/bin/run_lastz_intermediate_layer.py \
    && ln -s /usr/local/bin/NetFilterNonNested.perl /usr/local/bin/NetFilterNonNested \
    && ln -s /usr/local/bin/repeat_filler.py /usr/local/bin/repeat_filler \
    && test -x /bin/bash \
    && ps --version >/dev/null \
    && python --version 2>&1 | grep -q '^Python 3\.11\.' \
    && chaintools --version \
    && chromsize --version \
    && { lastz --version || test "$?" -eq 1; } \
    && repeat_filler --help >/dev/null \
    && partition.py --help >/dev/null \
    && psl_bundle.py --help >/dev/null \
    && run_lastz.py --help >/dev/null \
    && run_lastz_intermediate_layer.py --help >/dev/null \
    && for command in \
        NetFilterNonNested.perl \
        axtChain \
        axtToPsl \
        chainCleaner \
        chainNet \
        chainScore \
        chainSort \
        faToTwoBit \
        pslSortAcc \
        twoBitToFa; \
    do \
        command -v "${command}" >/dev/null; \
    done

CMD ["/bin/bash"]
