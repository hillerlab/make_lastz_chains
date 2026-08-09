#!/usr/bin/env bash
# End-to-end check that every alignment backend/executor produces equivalent
# science on the bundled synthetic fixture (assets/tests/test_data/, assets/tests/ci/e2e_params.json).
#
#   1. --aligner lastz                                          (CPU)
#   2. --aligner kegalign --kegalign_executor batched            (GPU + one CPU task)
#   3. --aligner kegalign --kegalign_executor distributed        (GPU + one task/partition)
#   4. assert each completed with non-empty PSL and non-empty final chains
#   5. compare robust metrics (aligned bases / coverage / chain count) within tolerance
#   6. batched vs distributed run the identical KegAlign partitions, so their
#      normalised PSL and final chains must match EXACTLY — any difference is a bug
#   7. report the lastz-vs-kegalign normalised chain diff (informational only —
#      the two backends partition differently, so byte identity is not required)
#
# Needs a GPU: KegAlign has no CPU fallback. Skips (exit 0) when none is present,
# so this script is safe to call from a CPU-only CI job.
#
# Usage: bash assets/tests/ci/compare_aligners.sh   (run from anywhere)
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

NF="${NEXTFLOW_BIN:-nextflow}"
# Max relative difference in chain aligned bases between the two backends.
TOLERANCE="${TOLERANCE:-0.20}"
OUT=assets/tests/work/aligner_compare

if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo ">> SKIP: no usable GPU (nvidia-smi absent or failing) — KegAlign cannot run."
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# ── metrics ──────────────────────────────────────────────────────────────────
# PSL: matches=$1  qStart/qEnd=$12/$13  tStart/tEnd=$16/$17
psl_metrics() {
  cat "$@" 2>/dev/null | awk '
    { n++; bases += $1; ref += $17 - $16; qry += $13 - $12 }
    END { printf "%d %d %d %d\n", n+0, bases+0, ref+0, qry+0 }'
}

# chain: header "chain score tName tSize tStrand tStart tEnd qName qSize qStrand qStart qEnd id"
#        block lines start with the aligned block size
chain_metrics() {
  awk '
    /^chain/ { n++; ref += $7 - $6; qry += $12 - $11; next }
    NF && $1 ~ /^[0-9]+$/ { bases += $1 }
    END { printf "%d %d %d %d\n", n+0, bases+0, ref+0, qry+0 }' "$1"
}

# Collapse each chain to one line (header minus its arbitrary id + all blocks),
# then sort: an exact comparison that ignores chain ordering and numbering.
normalise_chain() {
  awk '
    /^#/ { next }   # axtChain writes ##matrix / ##gapPenalties headers first
    /^chain/ { if (rec != "") print rec; rec = ""; for (i = 1; i < NF; i++) rec = rec $i " "; next }
    NF { rec = rec "|" $0 }
    END { if (rec != "") print rec }' "$1" | sort
}

# ── run one backend/executor ─────────────────────────────────────────────────
FAIL=0
run_backend() {
  local label="$1" aligner="$2" executor="$3" profile="$4" results="$OUT/${1}_results"
  echo ">> run: --aligner ${aligner} --kegalign_executor ${executor}  (-profile ${profile})"
  rm -rf "$results"
  "$NF" run main.nf \
      -params-file assets/tests/ci/e2e_params.json \
      -c assets/tests/ci/e2e.config \
      -profile "$profile" \
      --aligner "$aligner" \
      --kegalign_executor "$executor" \
      --outdir "$REPO/$results" \
      -w "assets/tests/work/nf_work_${label}" > "$OUT/${label}.log" 2>&1 \
    || { echo "!! ${label} run FAILED — see $OUT/${label}.log"; FAIL=1; return 1; }

  local psl_files
  psl_files=$(find "$results" -path '*_psl/*.psl' 2>/dev/null)
  if [ -z "$psl_files" ]; then
    echo "!! ${label}: no PSL published"; FAIL=1; return 1
  fi
  # shellcheck disable=SC2086  # word splitting is the point
  if [ "$(cat $psl_files | wc -l)" -eq 0 ]; then
    echo "!! ${label}: PSL is empty"; FAIL=1; return 1
  fi
  # shellcheck disable=SC2086
  psl_metrics $psl_files > "$OUT/${label}.psl_metrics"
  # LC_ALL=C so the ordering is byte-stable regardless of the caller's locale
  # shellcheck disable=SC2086
  cat $psl_files | LC_ALL=C sort > "$OUT/${label}.psl.norm"

  local final
  final=$(find "$results/07_final" -name '*.chain.gz' 2>/dev/null | head -1)
  if [ -z "$final" ]; then
    echo "!! ${label}: no final chain published"; FAIL=1; return 1
  fi
  zcat "$final" > "$OUT/${label}_final.chain"
  if [ ! -s "$OUT/${label}_final.chain" ]; then
    echo "!! ${label}: final chain is empty"; FAIL=1; return 1
  fi
  chain_metrics "$OUT/${label}_final.chain" > "$OUT/${label}.chain_metrics"
  normalise_chain "$OUT/${label}_final.chain" > "$OUT/${label}_final.norm"
  echo "   ${label}: OK"
}

run_backend lastz       lastz    batched     docker
run_backend batched     kegalign batched     docker,gpu
run_backend distributed kegalign distributed docker,gpu

if [ "$FAIL" -ne 0 ]; then
  echo; echo "!! ALIGNER COMPARISON FAILED (a run did not produce usable output)"
  exit 1
fi

# ── batched vs distributed must be EXACTLY equal ──────────────────────────────
# Both executors run the identical KegAlign-generated LASTZ commands, so any
# scientific difference is a bug, not a tolerance question.
echo
if diff -q "$OUT/batched.psl.norm" "$OUT/distributed.psl.norm" >/dev/null 2>&1; then
  echo ">> executors: normalised PSL IDENTICAL (batched == distributed)"
else
  diff "$OUT/batched.psl.norm" "$OUT/distributed.psl.norm" > "$OUT/executors.psl.diff" 2>&1
  echo "!! executors: normalised PSL DIFFERS — see $OUT/executors.psl.diff"
  echo "   Both executors run the same KegAlign partitions; this is a bug."
  FAIL=1
fi
if diff -q "$OUT/batched_final.norm" "$OUT/distributed_final.norm" >/dev/null 2>&1; then
  echo ">> executors: normalised final chains IDENTICAL (batched == distributed)"
else
  diff "$OUT/batched_final.norm" "$OUT/distributed_final.norm" > "$OUT/executors.chain.diff" 2>&1
  echo "!! executors: normalised final chains DIFFER — see $OUT/executors.chain.diff"
  FAIL=1
fi
if [ "$FAIL" -ne 0 ]; then
  echo; echo "!! EXECUTOR EQUIVALENCE FAILED"
  exit 1
fi

# ── report + tolerance check ─────────────────────────────────────────────────
read -r l_psl_n l_psl_bases l_psl_ref l_psl_qry < "$OUT/lastz.psl_metrics"
read -r k_psl_n k_psl_bases k_psl_ref k_psl_qry < "$OUT/batched.psl_metrics"
read -r l_ch_n l_ch_bases l_ch_ref l_ch_qry < "$OUT/lastz.chain_metrics"
read -r k_ch_n k_ch_bases k_ch_ref k_ch_qry < "$OUT/batched.chain_metrics"

printf '\n%-26s %14s %14s %9s\n' metric lastz kegalign 'rel diff'
report_row() {
  awk -v n="$1" -v a="$2" -v b="$3" \
    'BEGIN { d = (a > 0) ? (b - a) / a : (b == 0 ? 0 : 1); printf "%-26s %14d %14d %+8.1f%%\n", n, a, b, d * 100 }'
}
report_row 'psl records'         "$l_psl_n"     "$k_psl_n"
report_row 'psl aligned bases'   "$l_psl_bases" "$k_psl_bases"
report_row 'psl reference bases' "$l_psl_ref"   "$k_psl_ref"
report_row 'psl query bases'     "$l_psl_qry"   "$k_psl_qry"
report_row 'chain count'         "$l_ch_n"      "$k_ch_n"
report_row 'chain aligned bases' "$l_ch_bases"  "$k_ch_bases"
report_row 'chain reference span' "$l_ch_ref"   "$k_ch_ref"
report_row 'chain query span'    "$l_ch_qry"    "$k_ch_qry"

echo
if diff -q "$OUT/lastz_final.norm" "$OUT/batched_final.norm" >/dev/null 2>&1; then
  echo ">> normalised final chains are IDENTICAL between backends"
else
  diff "$OUT/lastz_final.norm" "$OUT/batched_final.norm" > "$OUT/final_chain.norm.diff" 2>&1
  echo ">> normalised final chains differ (informational — see $OUT/final_chain.norm.diff)"
  echo "   KegAlign partitions differently from LASTZ; byte identity is not claimed."
fi

echo
awk -v a="$l_ch_bases" -v b="$k_ch_bases" -v tol="$TOLERANCE" 'BEGIN {
  if (a <= 0) { print "!! lastz produced zero aligned chain bases"; exit 1 }
  d = (b - a) / a; if (d < 0) d = -d
  if (d > tol) {
    printf "!! chain aligned bases differ by %.1f%% (tolerance %.1f%%)\n", d * 100, tol * 100
    exit 1
  }
  printf ">> chain aligned bases agree within %.1f%% (tolerance %.1f%%)\n", d * 100, tol * 100
}' || exit 1

echo ">> ALL BACKENDS AND EXECUTORS OK"
