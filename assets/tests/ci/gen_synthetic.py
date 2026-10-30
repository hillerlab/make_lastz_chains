#!/usr/bin/env python3
"""Synthetic benchmark pair: N independent homologous chromosome pairs.

Each ref chromosome is random sequence; its query counterpart is a diverged copy
(substitutions + indels + one inversion), so chromosome i aligns to chromosome i
and not to the others. That keeps total alignment work linear in N instead of the
N^2 blowup you get from replicating one sequence. No repeats, so this understates
the repeat-driven cost real genomes impose on both backends equally.

  gen_synthetic.py <out_dir> <n_chroms> <chrom_bp> [seed]
"""

import os
import random
import sys

BASES = "ACGT"


def write_fasta(pathname, records):
    with open(pathname, "w") as out:
        for name, seq in records:
            print(f">{name}", file=out)
            for i in range(0, len(seq), 60):
                print(seq[i:i + 60], file=out)


def diverge(seq, rng, sub_rate=0.10, indel_rate=0.005):
    out = []
    for base in seq:
        r = rng.random()
        if r < indel_rate:
            continue                                    # deletion
        if r < indel_rate * 2:
            out.append(rng.choice(BASES))               # insertion
        out.append(rng.choice(BASES) if rng.random() < sub_rate else base)
    return "".join(out)


def main():
    out_dir, n_chroms, chrom_bp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    rng = random.Random(seed)
    os.makedirs(out_dir, exist_ok=True)

    ref, qry = [], []
    for i in range(n_chroms):
        seq = "".join(rng.choices(BASES, k=chrom_bp))
        ref.append((f"ref{i:03d}", seq))
        homolog = diverge(seq, rng)
        # invert the middle third of every third chromosome, so the minus strand
        # and chain breaking get exercised too
        if i % 3 == 0:
            a, b = len(homolog) // 3, 2 * len(homolog) // 3
            middle = homolog[a:b].translate(str.maketrans("ACGT", "TGCA"))[::-1]
            homolog = homolog[:a] + middle + homolog[b:]
        qry.append((f"qry{i:03d}", homolog))

    write_fasta(os.path.join(out_dir, "ref.fa"), ref)
    write_fasta(os.path.join(out_dir, "query.fa"), qry)
    total = sum(len(s) for _, s in ref)
    print(f"{n_chroms} chrom pairs, {total / 1e6:.1f} Mb per genome -> {out_dir}")


if __name__ == "__main__":
    main()
