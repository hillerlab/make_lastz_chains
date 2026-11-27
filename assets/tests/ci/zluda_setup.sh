#!/usr/bin/env bash
# Build the local tool directory the `zluda` profile expects, so the KegAlign GPU
# stage can run natively against a ZLUDA build on an AMD GPU while every other
# stage keeps using the pipeline container.
#
# Why a tool directory at all: the GPU stage cannot run inside the CUDA
# kegalign-full container on AMD, and the pipeline image is Alpine/musl, so its
# faToTwoBit / lastz cannot be executed directly on a glibc host. This script
# extracts them once and wraps each in an explicit musl-loader call, adds the
# KegAlign helper scripts, and writes a `kegalign` shim carrying the ZLUDA recipe
# (LD_PRELOAD must reach only the GPU binary, never the musl tools).
#
#   bash assets/tests/ci/zluda_setup.sh
#   nextflow run main.nf -profile docker,gpu,zluda --aligner kegalign ...
#
# Override with environment variables:
#   ZLUDA_TOOLS     where to build it        (default ~/.cache/make_lastz_chains/zluda)
#   KEGALIGN_BIN    ZLUDA-capable kegalign   (default /tmp/kegalign/build/kegalign)
#   KEGALIGN_SRC    KegAlign checkout        (default /tmp/kegalign)
#   ZLUDA_LIB       ZLUDA libcuda directory  (default ~/opt/zluda)
#   KEGALIGN_LIB    libs the kegalign build links (boost, tbb)
#                                            (default ~/opt/cudaconda/lib)
#   ZLUDA_SHIM      HIP stream-fix LD_PRELOAD shim, "" to disable
#                                            (default ~/opt/zluda-fix/hipfix.so)
#   MLC_IMAGE       image to take tools from (default ghcr.io/hillerlab/make_lastz_chains:latest)
#   WITH_MPS_STUBS  1 to also write NVIDIA-only stubs (see the note at the end)
set -euo pipefail

TOOLS=${ZLUDA_TOOLS:-$HOME/.cache/make_lastz_chains/zluda}
KEGALIGN_BIN=${KEGALIGN_BIN:-/tmp/kegalign/build/kegalign}
KEGALIGN_SRC=${KEGALIGN_SRC:-/tmp/kegalign}
ZLUDA_LIB=${ZLUDA_LIB:-$HOME/opt/zluda}
KEGALIGN_LIB=${KEGALIGN_LIB:-$HOME/opt/cudaconda/lib}
ZLUDA_SHIM=${ZLUDA_SHIM-$HOME/opt/zluda-fix/hipfix.so}
MLC_IMAGE=${MLC_IMAGE:-ghcr.io/hillerlab/make_lastz_chains:latest}

for required in "$KEGALIGN_BIN" "$KEGALIGN_SRC/scripts/runner.py" "$ZLUDA_LIB"; do
  [ -e "$required" ] || { echo "!! missing: $required (see the variables above)" >&2; exit 1; }
done
command -v docker > /dev/null || { echo "!! docker is needed once, to extract the pipeline tools" >&2; exit 1; }

rm -rf "$TOOLS"
mkdir -p "$TOOLS/bin" "$TOOLS/rootfs"

echo ">> extracting tools from $MLC_IMAGE"
cid=$(docker create "$MLC_IMAGE")
trap 'docker rm "$cid" > /dev/null 2>&1 || true' EXIT
# Explicit destinations: /lib and /usr/lib share a basename.
docker cp "$cid:/usr/local" "$TOOLS/rootfs/local"   > /dev/null
docker cp "$cid:/lib"       "$TOOLS/rootfs/lib"     > /dev/null
docker cp "$cid:/usr/lib"   "$TOOLS/rootfs/usr_lib" > /dev/null

# The image is musl-based: run each binary through its own loader rather than the
# host's, which has no /lib/ld-musl-x86_64.so.1.
LOADER=$TOOLS/rootfs/lib/ld-musl-x86_64.so.1
LIBPATH=$TOOLS/rootfs/lib:$TOOLS/rootfs/usr_lib:$TOOLS/rootfs/local/lib
[ -x "$LOADER" ] || { echo "!! no musl loader in $MLC_IMAGE — is it still Alpine-based?" >&2; exit 1; }

wrapped=0
for tool in "$TOOLS"/rootfs/local/bin/*; do
  [ -x "$tool" ] && head -c4 "$tool" | grep -q ELF || continue
  name=$(basename "$tool")
  printf '#!/bin/sh\nexec %s --library-path %s %s "$@"\n' "$LOADER" "$LIBPATH" "$tool" > "$TOOLS/bin/$name"
  chmod +x "$TOOLS/bin/$name"
  wrapped=$((wrapped + 1))
done
echo ">> wrapped $wrapped musl binaries (faToTwoBit, lastz, axtToPsl, ...)"

# KegAlign's helper scripts, and lastz-cmd.ini beside them: runner.py and
# package_output.py locate their tool directory as dirname(diagonal_partition.py).
for helper in runner.py package_output.py diagonal_partition.py run_lastz_tarball.py lastz-cmd.ini; do
  ln -sf "$KEGALIGN_SRC/scripts/$helper" "$TOOLS/bin/$helper"
done
# split_input.py / run_mig.py ship in this repo's bin/, which Nextflow adds itself.
ln -sf "$(command -v python3)" "$TOOLS/bin/python"

cat > "$TOOLS/bin/kegalign" <<EOF
#!/bin/sh
# ZLUDA recipe, scoped to the GPU binary: LD_PRELOAD must not reach the
# musl-linked UCSC tools that run in the same task.
${ZLUDA_SHIM:+export LD_PRELOAD=$ZLUDA_SHIM}
export LD_LIBRARY_PATH=$ZLUDA_LIB:$KEGALIGN_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec $KEGALIGN_BIN "\$@"
EOF
chmod +x "$TOOLS/bin/kegalign"

# package_output.py needs bashlex, and Nextflow exports PYTHONNOUSERSITE=1, so a
# pip --user install would be invisible to the task.
echo ">> installing bashlex into $TOOLS/pylib"
python3 -m pip install --quiet --target "$TOOLS/pylib" bashlex

if [ "${WITH_MPS_STUBS:-0}" = "1" ]; then
  mkdir -p "$TOOLS/mps-stub" "$TOOLS/pylib-mps"
  cat > "$TOOLS/mps-stub/nvidia-smi" <<'EOF'
#!/bin/sh
case "$*" in
  *memory.total*) echo "${STUB_VRAM_MIB:-4096}" ;;
  *uuid*)         echo 0 ;;
  -L)             echo "GPU 0: ZLUDA device (UUID: GPU-zluda-0)" ;;
  *)              echo "nvidia-smi stub (ZLUDA/AMD)" ;;
esac
EOF
  cat > "$TOOLS/mps-stub/nvidia-cuda-mps-control" <<'EOF'
#!/bin/sh
case "$*" in *-d*) exit 0 ;; esac
cat > /dev/null 2>&1 || true
EOF
  cat > "$TOOLS/pylib-mps/pynvml.py" <<'EOF'
"""NVML does not exist on AMD/ZLUDA; run_mig.py only calls init/shutdown."""
class NVMLError(Exception):
    pass
def nvmlInit():
    pass
def nvmlShutdown():
    pass
EOF
  chmod +x "$TOOLS/mps-stub"/*
fi

echo ">> done: $TOOLS"
# Smoke test. Both tools exit non-zero when asked for usage, hence the || true.
{ "$TOOLS/bin/kegalign" --help 2>&1 || true; } | grep -im1 version | sed 's/^/   kegalign: /'
{ "$TOOLS/bin/faToTwoBit"  2>&1 || true; } | sed -n '1s|^|   |p'
echo
echo "   nextflow run main.nf -profile docker,gpu,zluda --aligner kegalign ..."
if [ "${WITH_MPS_STUBS:-0}" = "1" ]; then
  echo
  echo "   MPS stubs written to $TOOLS/mps-stub (kept OFF the profile's PATH on purpose)."
  echo "   NVIDIA MPS does not exist on AMD: these only let you exercise the"
  echo "   --kegalign_mps_workers plumbing (splitting, scheduling, kegs, guard)."
  echo "   They make the GPU preflight pass on a host that has no MPS, so never"
  echo "   enable them when validating real MPS behaviour:"
  echo "     -profile docker,gpu,zluda,zluda_mps_stub"
fi
