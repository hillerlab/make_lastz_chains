#!/usr/bin/env python3
"""Find satellite arrays shared by both genomes in hspZ anchors, before lastz extends them.

Very close species can share satellite arrays that their repeat masking missed.
Every anchor in such an array sits on its own tandem diagonal, so one
100 kb x 100 kb block can hold millions of anchors, and lastz then spends
thousands of CPU hours extending them. Two steps:

1. Trigger: a BLOCK x BLOCK bp block (one reference chromosome, one query
   chromosome, one strand) with >= BLOCK_ANCHORS anchors. hg38 x mm39 peaks at
   13,581 anchors per block; three Myotis bat pairs at 1.5-3.4 M. Without a
   trigger, nothing else happens.
2. Regions: anchors per WINDOW bp along each genome, summed over every partner
   chromosome. A window with >= WINDOW_ANCHORS seeds a region; the region grows
   through adjacent windows with >= GROW_ANCHORS, and regions at most MERGE_GAP
   windows apart are joined (default 2: one window between them). Summing over
   partners catches arrays whose anchors are spread too thin for any one block
   (3 of the 17 jobs that overflowed CPU lastz on the bats).

An anchor whose reference start or forward query start lies in a region is
inside an array. --mode filter drops it, close to what soft-masking the regions
before hspZ gives (bats: 33.2 M of 346.8 M anchors kept; hspZ on the masked
genomes found 33.2 M). Minus-strand query positions count from the chromosome
end and are mirrored first.

Input: a directory of hspZ .segments (8 tab columns, 1-based inclusive; the
strand comes from '.plus'/'.minus' in the file name, else column 7).

Output:
  <prefix>.dense_windows.tsv          key/value report (always)
  <prefix>.reference.bed, .query.bed  regions, 0-based half-open (when triggered)
  <out>/<file name>                   kept anchors (--mode filter, when triggered;
                                      a file left empty is not written)
Prints 'yes' (triggered) or 'no' on stdout.
"""

import argparse
import collections
import multiprocessing as mp
import os
import sys

TB_BITS = 20  # block index bits: chromosomes up to ~100 Gbp at 100 kb blocks
WB_BITS = 28  # window index bits: chromosomes up to ~2.6 Tbp at 10 kb windows


def read_sizes(path):
    sizes = {}
    with open(path) as fh:
        for line in fh:
            f = line.split()
            if len(f) >= 2:
                sizes[f[0]] = int(f[1])
    return sizes


def file_strand(name):
    if ".minus" in name:
        return "-"
    if ".plus" in name:
        return "+"
    return None


# Worker state, set once per process by init().
G = {}


def init(state):
    G.update(state)


def anchors(path):
    """(reference chrom, 0-based reference start, query chrom, 0-based forward query start, strand, line)."""
    fixed = file_strand(os.path.basename(path))
    qsizes = G["qsizes"]
    with open(path) as fh:
        for line in fh:
            f = line.split("\t")
            if len(f) < (6 if fixed else 7):
                continue
            q = f[3]
            strand = fixed or f[6].strip()
            if strand == "-":
                qs = qsizes[q] - int(f[5])
            else:
                qs = int(f[4]) - 1
            yield f[0], int(f[1]) - 1, q, qs, strand, line


def count(paths):
    """Pass 1: anchors per block (packed int key) and per window on each genome."""
    ri, qi, nq = G["ri"], G["qi"], G["nq"]
    bs, ws = G["block"], G["window"]
    blocks, rwin, qwin = collections.Counter(), collections.Counter(), collections.Counter()
    n = 0
    for p in paths:
        for t, ts, q, qs, strand, _ in anchors(p):
            a, b = ri[t], qi[q]
            n += 1
            key = ((a * nq + b) * 2 + (strand == "-")) << (2 * TB_BITS)
            blocks[key | ((ts // bs) << TB_BITS) | (qs // bs)] += 1
            rwin[(a << WB_BITS) | (ts // ws)] += 1
            qwin[(b << WB_BITS) | (qs // ws)] += 1
    return n, blocks, rwin, qwin


def sift(paths):
    """Pass 2: anchors inside the regions; with an output dir, write the others."""
    rflag, qflag, ws, out = G["rflag"], G["qflag"], G["window"], G["out"]
    empty = frozenset()
    n = dropped = written = 0
    for p in paths:
        fh_out = None
        for t, ts, q, qs, _strand, line in anchors(p):
            n += 1
            if ts // ws in rflag.get(t, empty) or qs // ws in qflag.get(q, empty):
                dropped += 1
                continue
            if out:
                if fh_out is None:
                    fh_out = open(os.path.join(out, os.path.basename(p)), "w")
                    written += 1
                fh_out.write(line)
        if fh_out is not None:
            fh_out.close()
    return n, dropped, written


def batches(paths, k):
    """k lists of files with similar total size (largest first, round-robin)."""
    ordered = sorted(paths, key=os.path.getsize, reverse=True)
    return [b for b in (ordered[i::k] for i in range(k)) if b]


def regions(windows, names, sizes, a):
    """Seed/grow/merge windows into BED intervals: {chrom: [(start, end)]}."""
    by = collections.defaultdict(dict)
    mask = (1 << WB_BITS) - 1
    for key, n in windows.items():
        by[key >> WB_BITS][key & mask] = n
    out = {}
    for c, d in by.items():
        hot = set()
        for b, n in d.items():
            if n >= a.window_anchors:
                hot.add(b)
                for step in (-1, 1):
                    x = b + step
                    while x not in hot and d.get(x, 0) >= a.grow_anchors:
                        hot.add(x)
                        x += step
        ivs = []
        for b in sorted(hot):
            if ivs and b - ivs[-1][1] <= a.merge_gap:
                ivs[-1][1] = b
            else:
                ivs.append([b, b])
        if ivs:
            name = names[c]
            out[name] = [(s * a.window, min((e + 1) * a.window, sizes[name])) for s, e in ivs]
    return out


def write_bed(path, ivs):
    with open(path, "w") as fh:
        for c in sorted(ivs):
            for s, e in ivs[c]:
                fh.write(f"{c}\t{s}\t{e}\n")


def flags(ivs, window):
    return {c: frozenset(b for s, e in v for b in range(s // window, (e - 1) // window + 1)) for c, v in ivs.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("segments", help="directory of .segments files")
    ap.add_argument("--mode", choices=["report", "filter", "fail"], default="report")
    ap.add_argument("--reference-sizes", required=True)
    ap.add_argument("--query-sizes", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--out", default="kept", help="directory for the kept anchors (--mode filter)")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--block", type=int, default=100_000, help="trigger block side, bp")
    ap.add_argument("--block-anchors", type=int, default=100_000, help="anchors in one block that trigger")
    ap.add_argument("--window", type=int, default=10_000, help="region window, bp")
    ap.add_argument("--window-anchors", type=int, default=100_000, help="anchors in a window that seed a region")
    ap.add_argument("--grow-anchors", type=int, default=10_000, help="anchors in a window that extend a region")
    ap.add_argument("--merge-gap", type=int, default=2, help="join regions at most this many windows apart")
    a = ap.parse_args()

    rsizes, qsizes = read_sizes(a.reference_sizes), read_sizes(a.query_sizes)
    rnames, qnames = list(rsizes), list(qsizes)
    paths = sorted(
        os.path.join(root, f) for root, _, files in os.walk(a.segments) for f in files if f.endswith(".segments")
    )
    state = {
        "ri": {c: i for i, c in enumerate(rnames)},
        "qi": {c: i for i, c in enumerate(qnames)},
        "nq": len(qnames),
        "qsizes": qsizes,
        "block": a.block,
        "window": a.window,
    }
    threads = max(1, a.threads)
    work = batches(paths, threads * 4)

    # Pass 1: counts.
    n = 0
    blocks, rwin, qwin = collections.Counter(), collections.Counter(), collections.Counter()
    with mp.Pool(threads, initializer=init, initargs=(state,)) as pool:
        for k, b, r, q in pool.imap_unordered(count, work):
            n += k
            blocks.update(b)
            rwin.update(r)
            qwin.update(q)

    best_key, best = max(blocks.items(), key=lambda kv: kv[1], default=(None, 0))
    dense = sum(1 for v in blocks.values() if v >= a.block_anchors)
    triggered = best >= a.block_anchors
    del blocks

    report = [
        ("mode", a.mode),
        ("segments_files", len(paths)),
        ("anchors", n),
        ("block_bp", a.block),
        ("block_anchors_threshold", a.block_anchors),
    ]
    if best_key is not None:
        tb_mask = (1 << TB_BITS) - 1
        qb, tb, rest = best_key & tb_mask, (best_key >> TB_BITS) & tb_mask, best_key >> (2 * TB_BITS)
        strand = "-" if rest & 1 else "+"
        t, q = rnames[(rest >> 1) // len(qnames)], qnames[(rest >> 1) % len(qnames)]
        where = f"{t}:{tb * a.block}-{(tb + 1) * a.block} x {q}:{qb * a.block}-{(qb + 1) * a.block} ({strand})"
        report.append(("densest_block", where))
    report += [("densest_block_anchors", best), ("dense_blocks", dense), ("triggered", "yes" if triggered else "no")]

    if triggered:
        rivs = regions(rwin, rnames, rsizes, a)
        qivs = regions(qwin, qnames, qsizes, a)
        write_bed(f"{a.prefix}.reference.bed", rivs)
        write_bed(f"{a.prefix}.query.bed", qivs)
        out = a.out if a.mode == "filter" else None
        if out:
            os.makedirs(out, exist_ok=True)
        state.update(rflag=flags(rivs, a.window), qflag=flags(qivs, a.window), out=out)
        del rwin, qwin

        # Pass 2: the anchors inside the regions (and, filtering, the rest written out).
        m = dropped = written = 0
        with mp.Pool(threads, initializer=init, initargs=(state,)) as pool:
            for k, d, w in pool.imap_unordered(sift, work):
                m, dropped, written = m + k, dropped + d, written + w
        if m != n:
            sys.exit(f"dense_windows.py: pass 2 read {m} anchors, pass 1 read {n}")

        rbp = sum(e - s for v in rivs.values() for s, e in v)
        qbp = sum(e - s for v in qivs.values() for s, e in v)
        report += [
            ("reference_regions", sum(map(len, rivs.values()))),
            ("reference_regions_bp", rbp),
            ("query_regions", sum(map(len, qivs.values()))),
            ("query_regions_bp", qbp),
            ("anchors_in_regions", dropped),
            ("anchors_in_regions_pct", f"{100 * dropped / max(n, 1):.2f}"),
        ]
        if out:
            report += [("anchors_kept", n - dropped), ("files_kept", written)]

    with open(f"{a.prefix}.dense_windows.tsv", "w") as fh:
        for k, v in report:
            fh.write(f"{k}\t{v}\n")
    for k, v in report:
        print(f"{k}\t{v}", file=sys.stderr)
    print("yes" if triggered else "no")


if __name__ == "__main__":
    main()
