#!/usr/bin/env bash
# CI golden comparison: run the pipeline (current code) and diff published
# outputs against committed goldens under assets/tests/golden/.
# Exits non-zero on any diff and writes reports to assets/tests/work/diff_report/.
# Usage: bash assets/tests/ci/compare.sh   (run from anywhere; uses ${projectDir})
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

export NXF_CONTAINER_IMAGE="${NXF_CONTAINER_IMAGE:-ghcr.io/hillerlab/make_lastz_chains:latest}"
NF="${NEXTFLOW_BIN:-nextflow}"

FAIL=0
REPORT=assets/tests/work/diff_report
rm -rf "$REPORT"
mkdir -p "$REPORT"

# ── hspZ / LASTZ_SEGMENTED scoring wiring (no GPU; catches the K=3000 default) ─
echo ">> wiring: hspZ lastz_k and LASTZ_SEGMENTED"
if ! grep -Fq -- '--hspthresh ${lastz_k}' modules/local/hspz/run/main.nf; then
  echo "!! HSPZ must pass --hspthresh \${lastz_k} (hspZ default is 3000; do not use -H, that is BLASTZ inner)"
  FAIL=1
fi
if ! grep -Fq -- '--gappedthresh=${lastz_l}' modules/local/lastz_segmented/main.nf; then
  echo "!! LASTZ_SEGMENTED must use lastz_l for --gappedthresh"
  FAIL=1
fi
if grep -Fq -- '--gappedthresh=${lastz_h}' modules/local/lastz_segmented/main.nf; then
  echo "!! LASTZ_SEGMENTED still uses lastz_h for --gappedthresh"
  FAIL=1
fi
if ! grep -q -- '--strand=' modules/local/lastz_segmented/main.nf; then
  echo "!! LASTZ_SEGMENTED must pass --strand"
  FAIL=1
fi
if [ "$FAIL" -eq 0 ]; then
  echo "   hspZ --hspthresh / LASTZ_SEGMENTED L+strand   OK"
fi

# ── e2e full pipeline ────────────────────────────────────────────────────────
echo ">> compare: e2e full pipeline"
rm -rf assets/tests/work/e2e_results
"$NF" run main.nf -params-file assets/tests/ci/e2e_params.json -c assets/tests/ci/e2e.config -profile docker -w assets/tests/work/nf_work >/dev/null 2>&1 || { echo "!! e2e run FAILED"; FAIL=1; }

if [ -f assets/tests/work/e2e_results/07_final/*.chain.gz ]; then
  zcat assets/tests/work/e2e_results/07_final/*.chain.gz > "$REPORT/e2e_final.chain"
  diff assets/tests/golden/e2e/final.chain "$REPORT/e2e_final.chain" > "$REPORT/e2e_final.diff" 2>&1 \
    && echo "   e2e  final.chain            OK" \
    || { echo "!! e2e  final.chain            DIFF"; FAIL=1; }
  diff assets/tests/golden/e2e/removed_suspects.bed assets/tests/work/e2e_results/06_cleaned_chains/*.removed.bed \
    > "$REPORT/e2e_removed.diff" 2>&1 \
    && echo "   e2e  removed.bed            OK" \
    || { echo "!! e2e  removed.bed            DIFF"; FAIL=1; }
  diff assets/tests/golden/e2e/cleaned_intermediate.chain assets/tests/work/e2e_results/06_cleaned_chains/*.chain \
    > "$REPORT/e2e_cleaned.diff" 2>&1 \
    && echo "   e2e  cleaned.chain          OK" \
    || { echo "!! e2e  cleaned.chain          DIFF"; FAIL=1; }
else
  echo "!! e2e outputs missing"; FAIL=1
fi

# ── clean-step (CBA) ─────────────────────────────────────────────────────────
echo ">> compare: clean-step (CBA) pipeline"
rm -rf assets/tests/work/cba_results
"$NF" run main.nf -params-file assets/tests/ci/cba_params.json -c assets/tests/ci/cba.config -profile docker -w assets/tests/work/nf_work >/dev/null 2>&1 || { echo "!! cba run FAILED"; FAIL=1; }

if [ -f assets/tests/work/cba_results/07_final/*.chain.gz ]; then
  zcat assets/tests/work/cba_results/07_final/*.chain.gz > "$REPORT/cba_final.chain"
  diff assets/tests/golden/cba/final.chain "$REPORT/cba_final.chain" > "$REPORT/cba_final.diff" 2>&1 \
    && echo "   cba  final.chain            OK" \
    || { echo "!! cba  final.chain            DIFF"; FAIL=1; }
  diff assets/tests/golden/cba/removed_suspects.bed assets/tests/work/cba_results/06_cleaned_chains/*.removed.bed \
    > "$REPORT/cba_removed.diff" 2>&1 \
    && echo "   cba  removed.bed            OK" \
    || { echo "!! cba  removed.bed            DIFF"; FAIL=1; }
  diff assets/tests/golden/cba/cleaned_intermediate.chain assets/tests/work/cba_results/06_cleaned_chains/*.chain \
    > "$REPORT/cba_cleaned.diff" 2>&1 \
    && echo "   cba  cleaned.chain          OK" \
    || { echo "!! cba  cleaned.chain          DIFF"; FAIL=1; }
else
  echo "!! cba outputs missing"; FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "!! GOLDEN COMPARISON FAILED — see assets/tests/work/diff_report/"
  exit 1
fi
echo
echo ">> ALL GOLDENS MATCH"
