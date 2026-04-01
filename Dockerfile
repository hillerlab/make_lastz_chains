# ─────────────────────────────────────────────────────────────────────────────
# make_lastz_chains container
#
# Includes:
#   - Full UCSC Kent binary distribution (linux.x86_64, latest release)
#   - NetFilterNonNested.perl (commit fbdd299 — same version pinned by Dr. Hiller)
#   - LASTZ aligner (v1.04.22)
#   - Python 3 + py2bit (supports 64-bit .2bit files, fixes issue #56)
#
# Build:
#   docker build -t make_lastz_chains:latest .
#
# Convert to Apptainer SIF:
#   apptainer build make_lastz_chains.sif docker-daemon://make_lastz_chains:latest
# ─────────────────────────────────────────────────────────────────────────────

FROM ubuntu:22.04

LABEL maintainer="Nil Tianchen Mu <nilmu@asu.edu>"
LABEL description="make_lastz_chains pipeline dependencies"

ENV DEBIAN_FRONTEND=noninteractive

# ── System dependencies ───────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        rsync \
        wget \
        ca-certificates \
        gcc \
        make \
        perl \
        openssl \
        python3 \
        python3-pip \
        libssl-dev \
        zlib1g \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Full UCSC Kent binary distribution ───────────────────────────────────────
# Pulls the complete linux.x86_64 release from UCSC.
# This includes all tools required by the pipeline and any dependencies between
# Kent tools, avoiding issues with missing binaries.
RUN rsync -azvP --timeout=120 \
        rsync://hgdownload.soe.ucsc.edu/genome/admin/exe/linux.x86_64/ \
        /usr/local/bin/ \
    && chmod -R +x /usr/local/bin/

# ── NetFilterNonNested.perl (required by chainCleaner) ────────────────────────
# Pinned to commit fbdd299 — the same version present in the make_lastz_chains
# repo. Must use raw.githubusercontent.com (not the /blob/ HTML page URL).
RUN wget -q \
    https://raw.githubusercontent.com/ucscGenomeBrowser/kent/fbdd299/src/hg/mouseStuff/chainCleaner/NetFilterNonNested.perl \
    -O /usr/local/bin/NetFilterNonNested.perl \
    && chmod +x /usr/local/bin/NetFilterNonNested.perl

# ── LASTZ ─────────────────────────────────────────────────────────────────────
# Building from source (v1.04.22).
RUN wget -q https://github.com/lastz/lastz/archive/refs/tags/1.04.22.tar.gz \
        -O /tmp/lastz.tar.gz \
    && tar -xzf /tmp/lastz.tar.gz -C /tmp \
    && make -C /tmp/lastz-1.04.22 \
    && cp /tmp/lastz-1.04.22/src/lastz /usr/local/bin/lastz \
    && chmod +x /usr/local/bin/lastz \
    && rm -rf /tmp/lastz.tar.gz /tmp/lastz-1.04.22

# ── Python dependencies ───────────────────────────────────────────────────────
# py2bit supports both standard (v0) and 64-bit (v1, faToTwoBit -long) .2bit files.
# This fixes issue #56 (large genomes >4 GB).
RUN pip3 install --no-cache-dir py2bit

# ── Sanity check ─────────────────────────────────────────────────────────────
RUN lastz --version && \
    faToTwoBit 2>&1 | head -1 && \
    chainCleaner 2>&1 | head -1 && \
    perl /usr/local/bin/NetFilterNonNested.perl 2>&1 | head -1 || true

WORKDIR /data
