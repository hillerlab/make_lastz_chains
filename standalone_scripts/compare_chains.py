#!/usr/bin/env python3
"""Compare two final chain files and characterize chains present in baseline
but missing from candidate.

Diagnostic for V0 vs V1 parity testing (see CHANGES_nfcore_refactor.md →
"V0/V1 parity validation"). Reads chain header lines only — no chain-block
content is needed for the comparison.

Reports:
  - matched / missing counts
  - score distribution of missing chains vs all-baseline (percentiles)
  - fraction of missing chains that straddle a target-partition boundary
  - top-N highest-scoring missing chains, with coordinates for spot-checking

Two chains are considered "matched" when their target and query intervals
overlap (with an optional coordinate tolerance) on the same (tName, qName,
tStrand, qStrand) bucket. Score is not used for matching because lastz's
.2bit vs FASTA readers can produce slightly different scores for what is
nominally the same alignment.

Usage:
    python3 compare_chains.py <baseline.chain[.gz]> <candidate.chain[.gz]>
        [--tol 100]
        [--target-chunk 175000000] [--target-overlap 0]
        [--boundary-window 10000]
        [--top 20]
"""
import argparse
import gzip
import sys
from collections import defaultdict


def parse_chain_headers(path):
    """Yield one dict per `chain ...` header line in a .chain or .chain.gz file."""
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt") as f:
        for line in f:
            if not line.startswith("chain "):
                continue
            p = line.split()
            # chain score tName tSize tStrand tStart tEnd qName qSize qStrand qStart qEnd id
            yield {
                "score": int(p[1]),
                "tName": p[2], "tSize": int(p[3]), "tStrand": p[4],
                "tStart": int(p[5]), "tEnd": int(p[6]),
                "qName": p[7], "qSize": int(p[8]), "qStrand": p[9],
                "qStart": int(p[10]), "qEnd": int(p[11]),
                "id": p[12],
            }


def overlaps(a0, a1, b0, b1):
    return max(a0, b0) < min(a1, b1)


def find_match(bucket, t0, t1, q0, q1, tol):
    for ent in bucket:
        if overlaps(t0 - tol, t1 + tol, ent["tStart"], ent["tEnd"]) and \
           overlaps(q0 - tol, q1 + tol, ent["qStart"], ent["qEnd"]):
            return ent
    return None


def near_boundary(start, end, chunk, overlap, window):
    """True if any partition boundary lies within ±window of [start, end].

    Partition strides start every (chunk - overlap) bases on the target genome,
    matching the logic in bin/partition.py.
    """
    stride = chunk - overlap
    return (start - window) // stride != (end + window) // stride


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("baseline", help="Reference chain file (expected superset)")
    ap.add_argument("candidate", help="Chain file to check against baseline")
    ap.add_argument("--tol", type=int, default=100,
                    help="Coordinate slack when matching (bp). Default 100.")
    ap.add_argument("--target-chunk", type=int, default=175_000_000,
                    help="Target partition chunk size (must match params.seq1_chunk).")
    ap.add_argument("--target-overlap", type=int, default=0,
                    help="Target partition overlap (must match params.seq1_lap).")
    ap.add_argument("--boundary-window", type=int, default=10_000,
                    help="A chain is 'near a boundary' if a boundary lies within "
                         "this many bp of its target interval.")
    ap.add_argument("--top", type=int, default=20,
                    help="Print this many top-scoring missing chains.")
    args = ap.parse_args()

    print(f"Loading baseline: {args.baseline}", file=sys.stderr)
    baseline = list(parse_chain_headers(args.baseline))
    print(f"  {len(baseline)} chains", file=sys.stderr)

    print(f"Loading candidate: {args.candidate}", file=sys.stderr)
    cand_idx = defaultdict(list)
    n_cand = 0
    for c in parse_chain_headers(args.candidate):
        cand_idx[(c["tName"], c["qName"], c["tStrand"], c["qStrand"])].append(c)
        n_cand += 1
    print(f"  {n_cand} chains", file=sys.stderr)

    matched, missing = 0, []
    for b in baseline:
        bucket = cand_idx.get(
            (b["tName"], b["qName"], b["tStrand"], b["qStrand"]), []
        )
        if find_match(bucket, b["tStart"], b["tEnd"],
                      b["qStart"], b["qEnd"], args.tol):
            matched += 1
        else:
            missing.append(b)

    n_miss = len(missing)
    pct = 100.0 * n_miss / max(1, len(baseline))
    print("\n=== Summary ===")
    print(f"  Baseline:  {len(baseline)}")
    print(f"  Candidate: {n_cand}")
    print(f"  Matched:   {matched}")
    print(f"  Missing:   {n_miss} ({pct:.2f}%)")
    if n_miss == 0:
        return

    scores = sorted(m["score"] for m in missing)
    all_scores = sorted(b["score"] for b in baseline)

    def pct_of(arr, p):
        i = min(len(arr) - 1, max(0, int(p / 100 * len(arr))))
        return arr[i]

    print("\n=== Score distribution: missing vs. all-baseline ===")
    print(f"  {'pct':>4}  {'missing':>10}  {'baseline':>10}")
    for p in (10, 25, 50, 75, 90, 95, 99):
        print(f"  {p:>4}  {pct_of(scores, p):>10}  {pct_of(all_scores, p):>10}")
    print(f"  {'max':>4}  {scores[-1]:>10}  {all_scores[-1]:>10}")

    near = sum(
        1 for m in missing
        if near_boundary(m["tStart"], m["tEnd"],
                         args.target_chunk, args.target_overlap,
                         args.boundary_window)
    )
    print(f"\n=== Target-partition-boundary proximity (±{args.boundary_window} bp) ===")
    print(f"  Missing chains near a boundary: {near} / {n_miss} "
          f"({100.0 * near / n_miss:.1f}%)")

    print(f"\n=== Top {args.top} highest-scoring missing chains ===")
    cols = ["score", "tName", "tStrand", "tStart", "tEnd",
            "qName", "qStrand", "qStart", "qEnd", "id"]
    print("\t".join(cols))
    for m in sorted(missing, key=lambda x: -x["score"])[:args.top]:
        print("\t".join(str(m[k]) for k in cols))


if __name__ == "__main__":
    main()
