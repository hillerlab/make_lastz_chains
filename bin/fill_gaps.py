#!/usr/bin/env python3

# Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
# Distributed under the terms of the Apache License, Version 2.0.

"""
Gap records for the hspZ fill engine (--repeat_filler_engine hspz).

RepeatFiller runs lastz + axtChain once per chain gap, and axtChain reloads both
whole chromosomes every time (80-91 ms of a ~87 ms gap on hg38 chr21 x mm39
chr16). This script turns every gap into one record pair instead, so hspZ can
seed all gaps at once and lastz/axtChain can run per shard on small FASTAs.

  extract  merged chain -> gaps.tsv + shards/shard_NNNNN.{t,q}.fa
  splice   merged chain + gaps.tsv + per-shard mini chains -> filled chain

Gap selection, the gap coordinates and the splice arithmetic follow
repeat_filler.py (make_shell_list / insert_chain_content) line for line. Records
are gap-local and plus strand: for a '-' chain the query record is written
reverse-complemented, so local offset 0 is the gap start in the chain's own
frame on both sides and splicing is a plain offset.
"""

import argparse
import gzip
import os
import subprocess
import sys

COMP = str.maketrans("ACGTNacgtn", "TGCANtgcan")


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def fillable_gaps(chain_path, a):
    """Yields (line_no, t_name, t_start, t_end, q_name, q_start, q_end, strand, q_size)
    for every gap RepeatFiller would patch. Coordinates are 0-based half-open in
    the chain's own frame (reverse-complement frame on the query for '-')."""
    with open_text(chain_path) as fh:
        h = None
        for line_no, line in enumerate(fh):
            p = line.split()
            if not p:
                continue
            if p[0] == "chain":
                if p[4] != "+":
                    sys.exit(f"fill_gaps: target strand is not + for chain: {line.strip()}")
                score, t_start, t_end = int(p[1]), int(p[5]), int(p[6])
                q_start, q_end = int(p[10]), int(p[11])
                valid = (score >= a.chain_min_score and t_end - t_start >= 0
                         and q_end - q_start >= 0)
                h = (p[2], p[7], int(p[8]), p[9], valid)
                pos = [t_start, q_start]
                continue
            if h is None or not p[0].isdigit() or len(p) != 3:
                continue
            size, dt, dq = int(p[0]), int(p[1]), int(p[2])
            tb, qb = pos[0] + size, pos[1] + size
            tg, qg = tb + dt, qb + dq
            if (h[4] and a.gap_min_t <= dt <= a.gap_max_t
                    and a.gap_min_q <= dq <= a.gap_max_q):
                yield (line_no, h[0], tb, tg, h[1], qb, qg, h[3], h[2])
            pos = [tg, qg]


def two_bit_regions(two_bit, regions, unmask, workdir, tag):
    """Fetches 0-based half-open (name, start, end) regions, returned in the
    given order. twoBitToFa is asked for them in genome order: it does costly
    per-sequence work whenever the sequence changes, and gaps come in chain
    (score) order. 100k hg38 gap regions take 30.7 s in that order and 1.6 s
    sorted.
    ponytail: every gap sequence is held in memory at once; stream per shard
    if that matters."""
    if not regions:
        return []
    order = sorted(range(len(regions)), key=lambda i: regions[i])
    lst = os.path.join(workdir, f"{tag}.regions")
    with open(lst, "w") as fh:
        for i in order:
            name, start, end = regions[i]
            fh.write(f"{name}:{start}-{end}\n")
    cmd = ["twoBitToFa", f"-seqList={lst}", two_bit, "stdout"]
    if unmask:
        cmd.insert(1, "-noMask")
    # One record per '>'; the sequence is everything after the header line, with
    # the line breaks removed (string methods, not a Python loop over lines).
    recs = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.split(">")
    os.remove(lst)
    if len(recs) - 1 != len(regions):
        sys.exit(f"fill_gaps: twoBitToFa returned {len(recs) - 1} of {len(regions)} {tag} regions")
    seqs = [None] * len(regions)
    for i, rec in zip(order, recs[1:]):     # recs[0] is the empty text before the first '>'
        seqs[i] = rec[rec.index("\n") + 1:].replace("\n", "")
    return seqs


def write_fasta(fh, name, seq):
    fh.write(f">{name}\n")
    for i in range(0, len(seq), 60):
        fh.write(seq[i:i + 60] + "\n")


def extract(a):
    gaps = list(fillable_gaps(a.chain, a))
    n = len(gaps)
    shards = max(1, min(a.shards, n))
    os.makedirs(os.path.join(a.out, "shards"), exist_ok=True)
    t_seqs = two_bit_regions(a.t2bit, [(g[1], g[2], g[3]) for g in gaps], a.unmask, a.out, "t")
    # Query regions on the forward strand; '-' chains are reverse-complemented below.
    q_regions = [(g[4], g[8] - g[6], g[8] - g[5]) if g[7] == "-" else (g[4], g[5], g[6])
                 for g in gaps]
    q_seqs = two_bit_regions(a.q2bit, q_regions, a.unmask, a.out, "q")

    width = len(str(max(n - 1, 0)))
    with open(os.path.join(a.out, "gaps.tsv"), "w") as tsv:
        for k in range(shards):
            lo, hi = k * n // shards, (k + 1) * n // shards
            stem = os.path.join(a.out, "shards", f"shard_{k:05d}")
            with open(f"{stem}.t.fa", "w") as tf, open(f"{stem}.q.fa", "w") as qf:
                for i in range(lo, hi):
                    g = gaps[i]
                    gid = f"{k:05d}_{i:0{width}d}"
                    qs = q_seqs[i].translate(COMP)[::-1] if g[7] == "-" else q_seqs[i]
                    if len(t_seqs[i]) != g[3] - g[2] or len(qs) != g[6] - g[5]:
                        sys.exit(f"fill_gaps: gap {gid} region length mismatch")
                    write_fasta(tf, gid, t_seqs[i])
                    write_fasta(qf, gid, qs)
                    tsv.write(f"{gid}\t{g[0]}\t{g[3] - g[2]}\t{g[6] - g[5]}\n")
    print(f"fill_gaps extract: {n} gaps in {shards} shards", file=sys.stderr)


def best_mini_chains(paths):
    """First chain per gap id: axtChain writes each file sorted by score, so the
    first one is the best (RepeatFiller's take_first_chain_from_list)."""
    best = {}
    for path in paths:
        with open(path) as fh:
            cur = None
            for line in fh:
                p = line.split()
                if not p or p[0].startswith("#"):
                    continue
                if p[0] == "chain":
                    t_name, q_name = p[2], p[7]
                    if t_name != q_name or p[4] != "+" or p[9] != "+":
                        sys.exit(f"fill_gaps: mini chain crosses gaps or strands: {line.strip()}")
                    cur = None if t_name in best else [p, []]
                    if cur:
                        best[t_name] = cur
                elif cur is not None:
                    cur[1].append(line.strip())
    return best


def splice(a):
    gaps = {}
    with open(a.gaps) as fh:
        for line in fh:
            gid, line_no, t_len, q_len = line.split()
            gaps[int(line_no)] = (gid, int(t_len), int(q_len))
    best = best_mini_chains(a.mini)
    known = {g[0] for g in gaps.values()}
    stray = set(best) - known
    if stray:
        sys.exit(f"fill_gaps: {len(stray)} mini chain(s) name no known gap, e.g. {sorted(stray)[0]}")

    filled = 0
    with open_text(a.chain) as fh, open(a.out, "w") as out:
        for line_no, line in enumerate(fh):
            g = gaps.get(line_no)
            hit = best.get(g[0]) if g else None
            if hit is None or int(hit[0][1]) < a.min_score:
                out.write(line)
                continue
            head, blocks = hit
            t_len, q_len = g[1], g[2]
            t_start, t_end = int(head[5]), int(head[6])
            q_start, q_end = int(head[10]), int(head[11])
            if not (0 <= t_start <= t_end <= t_len and 0 <= q_start <= q_end <= q_len):
                sys.exit(f"fill_gaps: mini chain for {g[0]} lies outside its gap record")
            block_len = line.split()[0]
            spliced = [f"{block_len}\t{t_start}\t{q_start}"]
            spliced += blocks[:-1]
            spliced.append(f"{blocks[-1]}\t{t_len - t_end}\t{q_len - q_end}")
            out.write("".join(f"{b}\n" for b in spliced))
            filled += 1
    print(f"fill_gaps splice: {filled} of {len(gaps)} gaps filled", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract")
    ex.add_argument("--chain", required=True)
    ex.add_argument("--t2bit", required=True)
    ex.add_argument("--q2bit", required=True)
    ex.add_argument("--chain-min-score", type=int, required=True)
    ex.add_argument("--gap-min-t", type=int, required=True)
    ex.add_argument("--gap-max-t", type=int, required=True)
    ex.add_argument("--gap-min-q", type=int, required=True)
    ex.add_argument("--gap-max-q", type=int, required=True)
    ex.add_argument("--shards", type=int, required=True)
    ex.add_argument("--unmask", action="store_true")
    ex.add_argument("--out", default=".")
    sp = sub.add_parser("splice")
    sp.add_argument("--chain", required=True)
    sp.add_argument("--gaps", required=True)
    sp.add_argument("--min-score", type=int, required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("mini", nargs="*")
    a = ap.parse_args()
    extract(a) if a.cmd == "extract" else splice(a)


if __name__ == "__main__":
    main()
