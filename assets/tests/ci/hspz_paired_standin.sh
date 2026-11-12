#!/usr/bin/env bash
# CPU stand-in for `hspZ run --paired`, used only by compare_fill.sh through
# fill_standin.config (mounted as hspZ in the pipeline image, which has lastz).
#
# It writes, per record pair and in pair order, the anchors lastz itself would
# extend: `lastz t q K=<--hspthresh> --strand=plus --writesegments`. Fed through
# the hspz fill engine (LASTZ_FILL extends from anchors, axtChain, splice), that
# must reproduce the lastz engine (REPEAT_FILLER) byte for byte — it isolates
# the engine's plumbing from hspZ's own seeding.
set -euo pipefail
case "${1:-}" in
  --version) echo "hspZ 0.0.6-standin"; exit 0 ;;
  run) shift ;;
  *) echo "hspz_paired_standin: only 'run --paired' is implemented" >&2; exit 1 ;;
esac
paired=0 t= q= out= k=
while [ $# -gt 0 ]; do
  case "$1" in
    --paired) paired=1 ;;
    -r|--reference) t=$2; shift ;;
    -q|--query) q=$2; shift ;;
    -o|--output) out=$2; shift ;;
    -H|--hspthresh) k=$2; shift ;;
    -S|--strand) [ "$2" = plus ] || { echo "stand-in: plus strand only" >&2; exit 1; }; shift ;;
    --time) ;;
    *) echo "hspz_paired_standin: unsupported argument $1" >&2; exit 1 ;;
  esac
  shift
done
[ "$paired" = 1 ] && [ -n "$t" ] && [ -n "$q" ] && [ -n "$out" ] && [ -n "$k" ] \
  || { echo "stand-in: need --paired -r -q -o --hspthresh" >&2; exit 1; }

mkdir -p "$out" "$out/pairs"
for side in t q; do
  fa=$t; [ $side = q ] && fa=$q
  awk -v d="$out/pairs" -v s=$side '/^>/ { if (f) close(f); n++; f = sprintf("%s/%09d.%s.fa", d, n, s) } { print > f }' "$fa"
done
: > "$out/paired.segments"
for tf in "$out"/pairs/*.t.fa; do
  i=${tf%.t.fa}
  lastz "$tf" "$i.q.fa" K="$k" --strand=plus --writesegments="$i.seg" > /dev/null
  grep -v '^#' "$i.seg" >> "$out/paired.segments" || true
done
rm -rf "$out/pairs"
