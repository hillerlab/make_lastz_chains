#!/usr/bin/env bash
# Fill engine oracle: --repeat_filler_engine hspz against the lastz engine
# (REPEAT_FILLER), on one merged chain, through `--from fill_chains`.
#
#   1. EXACT    the hspz engine with a CPU stand-in for hspZ (lastz's own
#               anchors, fill_standin.config) must reproduce the lastz engine's
#               05_filled_chains byte for byte. This proves the gap records, the
#               reverse-complemented '-' queries, lastz [multiple] --segments,
#               axtChain on the shard FASTAs and the splice. One exception is
#               accepted and counted: where a gap has two mini chains of exactly
#               equal score, RepeatFiller's chainSort (unstable qsort) picks one
#               arbitrarily, so the chain keeps its blocks but they may sit at
#               the other copy (chain_tie_diff.py: TIE n).
#   2. TOLERANCE the hspz engine with the real hspZ image: the aligned bases the
#               fill adds must be within FILL_TOLERANCE (default 0.05) of the
#               lastz engine's. Skipped with REAL=0 (needs a GPU or ZLUDA).
#
# Usage:
#   CHAIN=<merged *.all.chain.gz> REF=<ref .2bit> QRY=<query .2bit> \
#     [REF_NAME=hg38 QRY_NAME=mm39 NEXTFLOW_BIN=nextflow PROFILE=docker,zluda \
#      REAL=1 FILL_TOLERANCE=0.05 WORK=<dir> NF_ARGS='-c site.config'] \
#     bash assets/tests/ci/compare_fill.sh
#
# Last run (2026-11-04, hg38 chr21 x mm39 chr16 pre-fill chain, 8,671 gaps):
# EXACT 'TIE 1' (one gap with two equal-score mini chains); TOLERANCE OK,
# fill added 531,416 vs 530,813 bp (+0.11%).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
CHAIN=${CHAIN:?set CHAIN to a merged *.all.chain.gz}
REF=${REF:?set REF to the reference .2bit}
QRY=${QRY:?set QRY to the query .2bit}
REF_NAME=${REF_NAME:-hg38}
QRY_NAME=${QRY_NAME:-mm39}
NF=${NEXTFLOW_BIN:-nextflow}
PROFILE=${PROFILE:-docker,zluda}
REAL=${REAL:-1}
TOL=${FILL_TOLERANCE:-0.05}
WORK=${WORK:-$REPO/assets/tests/work/compare_fill}
mkdir -p "$WORK"

run() { # run <name> <engine> [extra args]
  local name=$1 engine=$2 d="$WORK/$1"; shift 2
  rm -rf "$d"; mkdir -p "$d"
  (cd "$d" && "$NF" -log "$d/nf.log" run "$REPO/main.nf" -profile "$PROFILE" \
     -params-file "$REPO/params.json" --from fill_chains --merged_chain_path "$CHAIN" \
     --reference_name "$REF_NAME" --query_name "$QRY_NAME" \
     --reference_genome "$REF" --query_genome "$QRY" \
     --repeat_filler_engine "$engine" --num_fill_jobs 16 \
     -w "$d/work" --outdir "$d/results" ${NF_ARGS:-} "$@" > "$d/console.txt" 2>&1) \
    || { echo "!! $name failed:"; grep -A12 'ERROR' "$d/console.txt" | head -20; exit 1; }
}
filled() { ls "$WORK/$1"/results/05_filled_chains/*.filled.all.chain.gz; }
aligned() { zcat -f "$1" | awk '$1 ~ /^[0-9]+$/ { s += $1 } END { print s + 0 }'; }

run lastz lastz
run standin hspz -c "$REPO/assets/tests/ci/fill_standin.config"
fail=0
if v=$(python3 -I "$REPO/assets/tests/ci/chain_tie_diff.py" "$(filled lastz)" "$(filled standin)"); then
  echo "EXACT     hspz engine + lastz anchors vs lastz engine (05_filled_chains): $v"
else
  echo "EXACT     FAIL: hspz engine + lastz anchors vs lastz engine: $v"
  fail=1
fi

if [ "$REAL" = 1 ]; then
  run hspz hspz
  base=$(aligned "$CHAIN"); a=$(aligned "$(filled lastz)"); b=$(aligned "$(filled hspz)")
  read -r verdict line < <(awk -v base="$base" -v a="$a" -v b="$b" -v tol="$TOL" 'BEGIN {
    da = a - base; db = b - base; rel = (da > 0) ? (db - da) / da : 0
    v = (rel <= tol && rel >= -tol) ? "OK" : "FAIL"
    printf "%s fill added %d bp (lastz engine) vs %d bp (hspz engine): %+.2f%% (tolerance %.0f%%); aligned %d vs %d\n",
           v, da, db, 100 * rel, 100 * tol, a, b }')
  echo "TOLERANCE $verdict $line"
  [ "$verdict" = OK ] || fail=1
fi
exit $fail
