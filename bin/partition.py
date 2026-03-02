#!/usr/bin/env python3
"""Standalone genome partitioning script for nf-core make_lastz_chains pipeline.

Reads a chrom.sizes file and produces partition lines for the LASTZ step.
Partition strings use just the filename (not full path) of the .2bit file,
so they resolve correctly when Nextflow stages the file in a work directory.

Output (stdout): one partition string per line, e.g.:
    target.2bit:chr1:0-175000000
    target.2bit:chr1:175000000-200000000
    BULK_1:target.2bit:chr2:chr3:chr4
"""
import argparse
import os
import sys
from collections import defaultdict


# ── Constants (matching constants.py) ──────────────────────────────────────
LASTZ_OUT_BUCKET_PREFIX = "bucket_ref"
LASTZ_OUT_BULK_PREFIX = "bucket_ref_bulk"
PART_BULK_FILENAME_PREFIX = "BULK"
MAX_CHROM_IN_BULK = 100
CHUNK_SIZE_FRACTION_FOR_LITTLE_CHROMOSOMES = 0.75


# ── Core logic (inlined from modules/common.py and steps_implementations/partition.py) ─
def read_chrom_sizes(path):
    sizes = {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip().split("\t")
            sizes[parts[0]] = int(parts[1])
    return sizes


def create_partition(chrom_sizes, chunk_size, overlap):
    """Split chromosomes into overlapping chunks; collect small scaffolds separately."""
    partition_list = []
    little_scaffolds = []
    scaffold_size_threshold = chunk_size * 0.45

    for chrom, size in chrom_sizes.items():
        if size < scaffold_size_threshold:
            little_scaffolds.append((chrom, size))
            continue
        start = 0
        while start < size:
            end = min(start + chunk_size, size)
            partition_list.append((chrom, start, end))
            start += chunk_size - overlap
    return partition_list, little_scaffolds


def create_buckets_for_little_scaffolds(little_scaffolds, chunk_size):
    """Group small scaffolds into bulks to avoid excessive LASTZ jobs."""
    bulk_num_to_chroms = defaultdict(list)
    bulk_size_threshold = chunk_size * CHUNK_SIZE_FRACTION_FOR_LITTLE_CHROMOSOMES
    bulk_number = 1
    current_bulk_size = 0
    chrom_count = 0

    for chrom, size in little_scaffolds:
        if (current_bulk_size + size) > bulk_size_threshold or chrom_count >= MAX_CHROM_IN_BULK:
            bulk_number += 1
            current_bulk_size = 0
            chrom_count = 0
        bulk_num_to_chroms[bulk_number].append(chrom)
        current_bulk_size += size
        chrom_count += 1
    return bulk_num_to_chroms


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--chrom_sizes", required=True,
                    help="Path to the chrom.sizes file (tab-separated: chrom<TAB>size)")
    ap.add_argument("--twobit_name", required=True,
                    help="Basename of the .2bit file (e.g. 'target.2bit'). "
                         "Used verbatim in partition strings — do NOT supply a full path.")
    ap.add_argument("--chunk_size", type=int, required=True,
                    help="Target chunk size in bases (e.g. 175000000 for target, 50000000 for query)")
    ap.add_argument("--overlap", type=int, required=True,
                    help="Overlap between consecutive chunks (e.g. 0 for target, 10000 for query)")
    ap.add_argument("--output", required=True,
                    help="Output partition file path (one partition string per line)")
    if len(sys.argv) < 2:
        ap.print_help()
        sys.exit(1)
    return ap.parse_args()


def main():
    args = parse_args()
    chrom_sizes = read_chrom_sizes(args.chrom_sizes)
    twobit_name = args.twobit_name  # e.g. "target.2bit"

    partition_list, little_scaffolds = create_partition(chrom_sizes, args.chunk_size, args.overlap)
    bulk_map = create_buckets_for_little_scaffolds(little_scaffolds, args.chunk_size)

    n_parts = len(partition_list)
    n_bulks = len(bulk_map)
    print(f"Partitioning: {n_parts} regular partitions + {n_bulks} bulk groups", file=sys.stderr)

    with open(args.output, "w") as out:
        for chrom, start, end in partition_list:
            out.write(f"{twobit_name}:{chrom}:{start}-{end}\n")
        for bulk_number, chroms in sorted(bulk_map.items()):
            chroms_ids = ":".join(chroms)
            out.write(f"{PART_BULK_FILENAME_PREFIX}_{bulk_number}:{twobit_name}:{chroms_ids}\n")

    print(f"Wrote {n_parts + n_bulks} partition entries to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
