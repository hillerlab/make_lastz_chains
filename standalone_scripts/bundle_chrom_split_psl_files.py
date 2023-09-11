#!/usr/bin/env python3
"""Direct translation from bundleChromSplitPSLfiles.perl to Python."""
import os
import sys
import argparse
from modules.common_funcs import read_chrom_sizes


def parse_args():
    parser = argparse.ArgumentParser(description='bundleChromSplitPstFiles translation from Perl')
    parser.add_argument('input_dir', type=str, help='Input directory')
    parser.add_argument('chrom_sizes', type=str, help='Chrom sizes file')
    parser.add_argument('output_dir', type=str, help='Output directory')
    parser.add_argument('--maxBases', type=int, default=30000000, help='Max bases')
    parser.add_argument('--warningOnly', action='store_true', help='Warning only')
    parser.add_argument('--verbose', '-v', action='store_true', help='Verbose')
    return parser.parse_args()


def get_input_files(input_dir):
    return {file: 0 for file in os.listdir(input_dir) if file.endswith('.psl')}


def bundle_files(args, chrom_size, input_files):
    cur_bases = 0
    bundle_psl_file_list = []
    bundle_psl_file_count = 0
    cur_bundle_count = 0

    for chrom in sorted(chrom_size, key=chrom_size.get, reverse=True):
        if args.verbose:
            print(f"\nConsider {chrom} {chrom_size[chrom]}")

        if f"{chrom}.psl" not in input_files:
            if args.verbose:
                print(f"\t--> file {chrom}.psl does not exist. Next")
            continue

        cur_bases += chrom_size[chrom]
        bundle_psl_file_list.append(f"{args.input_dir}/{chrom}.psl")
        bundle_psl_file_count += 1
        input_files[f"{chrom}.psl"] = 1

        if args.verbose:
            print(f"curBases: {cur_bases}  num files: {bundle_psl_file_count} {bundle_psl_file_list}")

        if cur_bases >= args.maxBases or bundle_psl_file_count > 1000:
            execute_bundle(args, bundle_psl_file_list, cur_bundle_count)
            cur_bundle_count += 1
            cur_bases = 0
            bundle_psl_file_list = []
            bundle_psl_file_count = 0

    execute_bundle(args, bundle_psl_file_list, cur_bundle_count) if cur_bases > 0 else None
    return cur_bundle_count


def execute_bundle(args, bundle_psl_file_list, cur_bundle_count):
    output_file_path = f"{args.output_dir}/bundle.{cur_bundle_count}.psl"
    with open(output_file_path, 'w') as outfile:
        for file_path in bundle_psl_file_list:
            with open(file_path, 'r') as infile:
                outfile.write(infile.read())
    print(f"Written to {output_file_path}")


def check_unbundled_files(args, input_files):
    for chrom, read in input_files.items():
        if read == 0:
            message = (
                f"file {args.input_dir}/{chrom} was not bundled as the "
                f"chrom could not be found in {args.chrom_sizes}"
            )
            if args.warningOnly:
                print(f"WARNING: {message}", file=sys.stderr)
            else:
                sys.exit(f"ERROR: {message}")


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)
    chrom_size = read_chrom_sizes(args.chrom_sizes)
    input_files = get_input_files(args.input_dir)
    bundle_files(args, chrom_size, input_files)
    cur_bundle_count = bundle_files(args, chrom_size, input_files)
    check_unbundled_files(args, input_files)
    print(f"DONE. Produced {cur_bundle_count + 1} files")


if __name__ == "__main__":
    main()
