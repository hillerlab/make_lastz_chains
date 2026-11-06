#!/usr/bin/env bash
# Regenerate committed golden outputs from the CURRENT pipeline (chainCleaner).
# Run before the chainc swap (baseline) and after any intentional image bump.
# Usage: bash assets/tests/ci/make_golden.sh   (from anywhere; uses ${projectDir})
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

export NXF_CONTAINER_IMAGE="${NXF_CONTAINER_IMAGE:-ghcr.io/hillerlab/make_lastz_chains:latest}"
NF="${NEXTFLOW_BIN:-nextflow}"

echo ">> make_golden: e2e full pipeline"
rm -rf assets/tests/work/e2e_results
"$NF" run main.nf -params-file assets/tests/ci/e2e_params.json -c assets/tests/ci/e2e.config -profile docker -w assets/tests/work/nf_work

echo ">> make_golden: clean-step (CBA) pipeline"
rm -rf assets/tests/work/cba_results
"$NF" run main.nf -params-file assets/tests/ci/cba_params.json -c assets/tests/ci/cba.config -profile docker -w assets/tests/work/nf_work

echo ">> snapshotting goldens"
GOLD_E2E=assets/tests/golden/e2e
GOLD_CBA=assets/tests/golden/cba
rm -rf "$GOLD_E2E" "$GOLD_CBA"
mkdir -p "$GOLD_E2E" "$GOLD_CBA"

cp -L assets/tests/work/e2e_results/06_cleaned_chains/*.chain "$GOLD_E2E/cleaned_intermediate.chain"
cp -L assets/tests/work/e2e_results/06_cleaned_chains/*.removed.bed   "$GOLD_E2E/removed_suspects.bed"
zcat assets/tests/work/e2e_results/07_final/*.chain.gz > "$GOLD_E2E/final.chain"

cp -L assets/tests/work/cba_results/06_cleaned_chains/*.chain "$GOLD_CBA/cleaned_intermediate.chain"
cp -L assets/tests/work/cba_results/06_cleaned_chains/*.removed.bed   "$GOLD_CBA/removed_suspects.bed"
zcat assets/tests/work/cba_results/07_final/*.chain.gz > "$GOLD_CBA/final.chain"

echo ">> goldens written:"
ls "$GOLD_E2E" "$GOLD_CBA"
