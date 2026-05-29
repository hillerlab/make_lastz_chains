#!/usr/bin/env python3
"""Standalone PSL chromosome-bundling script for nf-core make_lastz_chains pipeline.

Groups PSL files (output of pslSortAcc, one per chromosome) into bundles whose
total base count does not exceed --max_bases. This controls the granularity of
the parallel axtChain step.

Usage:
    psl_bundle.py --input_dir sorted_psl/ --chrom_sizes target.chrom.sizes
                  --output_dir split_psl/ [--max_bases 1000000]
"""
import argparse
import os
import sys


MAX_BASES_DEFAULT = 1_000_000


def read_chrom_sizes(path):
    sizes = {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip().split("\t")
            sizes[parts[0]] = int(parts[1])
    return sizes


def get_input_files(input_dir):
    """Return dict of {filename: processed_flag} for .psl files in input_dir."""
    files = {f: 0 for f in os.listdir(input_dir) if f.endswith(".psl")}
    print(f"Found {len(files)} PSL files to bundle", file=sys.stderr)
    return files


def execute_bundle(input_dir, bundle_psl_file_list, output_dir, cur_bundle_count):
    output_path = os.path.join(output_dir, f"bundle.{cur_bundle_count}.psl")
    with open(output_path, "w") as outfile:
        for file_path in bundle_psl_file_list:
            with open(file_path) as infile:
                outfile.write(infile.read())
    print(f"Written bundle {cur_bundle_count} to {output_path}", file=sys.stderr)


def bundle_files(input_dir, chrom_size, input_files, output_dir, max_bases):
    cur_bases = 0
    bundle_file_list = []
    bundle_file_count = 0
    cur_bundle_count = 0

    for chrom in sorted(chrom_size, key=chrom_size.get, reverse=True):
        psl_name = f"{chrom}.psl"
        if psl_name not in input_files:
            print(f"  No PSL file for chrom {chrom} — skipping", file=sys.stderr)
            continue

        cur_bases += chrom_size[chrom]
        bundle_file_list.append(os.path.join(input_dir, psl_name))
        bundle_file_count += 1
        input_files[psl_name] = 1

        if cur_bases >= max_bases or bundle_file_count > 1000:
            execute_bundle(input_dir, bundle_file_list, output_dir, cur_bundle_count)
            cur_bundle_count += 1
            cur_bases = 0
            bundle_file_list = []
            bundle_file_count = 0

    if cur_bases > 0:
        execute_bundle(input_dir, bundle_file_list, output_dir, cur_bundle_count)
        cur_bundle_count += 1

    return cur_bundle_count


def check_unbundled(input_dir, input_files):
    for fname, processed in input_files.items():
        if processed == 0:
            print(f"WARNING: {os.path.join(input_dir, fname)} was not bundled "
                  f"(chrom not found in chrom.sizes)", file=sys.stderr)


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input_dir", required=True,
                    help="Directory containing chromosome-sorted .psl files (output of pslSortAcc)")
    ap.add_argument("--chrom_sizes", required=True,
                    help="Target chrom.sizes file (used to sort chroms by size)")
    ap.add_argument("--output_dir", required=True,
                    help="Output directory for bundle .psl files")
    ap.add_argument("--max_bases", type=int, default=MAX_BASES_DEFAULT,
                    help=f"Maximum bases per bundle (default: {MAX_BASES_DEFAULT})")
    if len(sys.argv) < 2:
        ap.print_help()
        sys.exit(1)
    return ap.parse_args()


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    chrom_size = read_chrom_sizes(args.chrom_sizes)
    input_files = get_input_files(args.input_dir)
    n_bundles = bundle_files(args.input_dir, chrom_size, input_files, args.output_dir, args.max_bases)
    check_unbundled(args.input_dir, input_files)
    print(f"Produced {n_bundles} bundle files in {args.output_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
