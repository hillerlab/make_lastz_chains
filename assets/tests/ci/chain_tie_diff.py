#!/usr/bin/env python3
"""compare_fill.sh helper: are two filled chain files the same up to fill ties?

RepeatFiller pipes each gap's mini chains through chainSort, whose qsort is not
stable, so between two mini chains of EXACTLY equal score its pick is arbitrary
(seen on hg38 chr21 x mm39 chr16: one gap, the same target block aligned to two
tandem copies 3,810 bp apart). A tie swap keeps every chain and every block
size, and moves only the gaps around the inserted blocks.

Exit 0 and print 'EXACT' or 'TIE <n>' (n chains differ only that way);
exit 1 and print the first chain that differs in any other way.
Usage: chain_tie_diff.py A.chain.gz B.chain.gz
"""
import gzip
import sys


def chains(path):
    out, key = {}, None
    with gzip.open(path, "rt") as fh:
        for line in fh:
            p = line.split()
            if not p or p[0].startswith("#"):
                continue
            if p[0] == "chain":
                key = (p[2], p[5], p[6], p[7], p[9], p[10], p[11])
                out[key] = []
            else:
                out[key].append(tuple(int(x) for x in p))
    return out


a, b = chains(sys.argv[1]), chains(sys.argv[2])
if a.keys() != b.keys():
    only = sorted(a.keys() ^ b.keys())[0]
    print(f"DIFF chain set differs, e.g. {only}")
    sys.exit(1)
ties = 0
for k in a:
    if a[k] == b[k]:
        continue
    if [blk[0] for blk in a[k]] != [blk[0] for blk in b[k]]:
        print(f"DIFF blocks differ in chain {k}")
        sys.exit(1)
    ties += 1
print(f"TIE {ties}" if ties else "EXACT")
