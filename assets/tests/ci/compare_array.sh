#!/usr/bin/env bash
# --array oracle: one hspZ --query-list batch over two queries must give each
# query exactly the outputs of its own single-query run. hspZ keeps every job
# byte-identical to its standalone run and everything downstream is
# deterministic, so one diff per query catches cross-talk between queries,
# keying, naming and per-query layout at once.
#
# Needs a GPU, like compare_aligners.sh:
#   PROFILE=docker,gpu  (default, NVIDIA)   or   PROFILE=docker,zluda  (AMD)
# Usage: bash assets/tests/ci/compare_array.sh   (run from anywhere)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO"

NF="${NEXTFLOW_BIN:-nextflow}"
P="test_hspz,${PROFILE:-docker,gpu}"
D="$REPO/assets/tests/test_data"
W="$REPO/assets/tests/work/array"
rm -rf "$W"
mkdir -p "$W"

# Two queries with distinct sequence names: the bundled query, and the
# reference itself (named after its file, test_reference, not test_ref).
printf '%s\n' "$D/test_query.fa" "$D/test_reference.fa" > "$W/queries.txt"
printf '{"array": "%s", "query_name": null, "query_genome": null}\n' "$W/queries.txt" > "$W/array.json"

echo ">> run: --array (2 queries, one hspZ batch)"
"$NF" run main.nf -profile "$P" -params-file "$W/array.json" \
    --outdir "$W/array" -w "$W/nf_work" > "$W/array.log" 2>&1 \
  || { echo "!! --array run FAILED — see $W/array.log"; exit 1; }

for q in test_query test_reference; do
  echo ">> run: single query $q"
  "$NF" run main.nf -profile "$P" --query_name "$q" --query_genome "$D/$q.fa" \
      --outdir "$W/$q" -w "$W/nf_work" > "$W/$q.log" 2>&1 \
    || { echo "!! single run $q FAILED — see $W/$q.log"; exit 1; }

  diff -r "$W/array/02_hspz/segments/segments/$q" "$W/$q/02_hspz/segments/segments"
  for f in "06_cleaned_chains/test_ref.$q.filled.chain" "06_cleaned_chains/test_ref.$q.filled.removed.bed"; do
    cmp "$W/array/$q/$f" "$W/$q/$f"
  done
  cmp <(zcat "$W/array/$q/07_final/test_ref.$q.allfilled.chain.gz") \
      <(zcat "$W/$q/07_final/test_ref.$q.allfilled.chain.gz")
  echo "   $q: segments, cleaned chain, removed.bed and final chain IDENTICAL"
done

echo ">> ARRAY ORACLE OK"
