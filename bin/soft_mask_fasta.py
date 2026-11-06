#!/usr/bin/env python3
"""Soft-mask BED intervals in a FASTA stream (stdin -> stdout).

Bases inside an interval are lowercased; every other base keeps its case, so the
genome's own soft-masking survives (the union, like `twoBitMask -add`).

Usage: twoBitToFa -seq=chr1 genome.2bit stdout | soft_mask_fasta.py mask.bed > chr1.fa
"""

import collections
import sys


def read_intervals(path: str) -> dict[str, list[tuple[int, int]]]:
    """BED (0-based, half-open) intervals per sequence name."""
    intervals: dict[str, list[tuple[int, int]]] = collections.defaultdict(list)
    with open(path) as bed:
        for line in bed:
            fields = line.split()
            if len(fields) >= 3:
                intervals[fields[0]].append((int(fields[1]), int(fields[2])))
    return intervals


def write_record(name: str, parts: list[str], intervals, out) -> None:
    """Lowercase one record's intervals and write it wrapped at 60 columns."""
    seq = bytearray("".join(parts), "ascii")
    for start, end in intervals.get(name, ()):
        seq[start:end] = seq[start:end].lower()
    out.write(f">{name}\n")
    text = seq.decode("ascii")
    for i in range(0, len(text), 60):
        out.write(text[i : i + 60] + "\n")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    intervals = read_intervals(sys.argv[1])
    name, parts = None, []
    for line in sys.stdin:
        if line.startswith(">"):
            if name is not None:
                write_record(name, parts, intervals, sys.stdout)
            name, parts = line[1:].split()[0], []
        else:
            parts.append(line.strip())
    if name is not None:
        write_record(name, parts, intervals, sys.stdout)


if __name__ == "__main__":
    main()
