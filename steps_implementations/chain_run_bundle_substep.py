#!/usr/bin/env python3
"""Direct translation from bundleChromSplitPSLfiles.perl to Python."""
import os
import sys
import argparse
from modules.common_funcs import read_chrom_sizes


def get_input_files(input_dir):
    return {file: 0 for file in os.listdir(input_dir) if file.endswith('.psl')}


def bundle_files(args, chrom_size, input_files):
    cur_bases = 0
    bundle_psl_file_list = []
    bundle_psl_file_count = 0
    cur_bundle_count = 0
    input_dir = args["input_dir"]

    for chrom in sorted(chrom_size, key=chrom_size.get, reverse=True):
        if args["verbose"]:
            print(f"\nConsider {chrom} {chrom_size[chrom]}")

        if f"{chrom}.psl" not in input_files:
            if args["verbose"]:
                print(f"\t--> file {chrom}.psl does not exist. Next")
            continue

        cur_bases += chrom_size[chrom]
        bundle_psl_file_list.append(f"{input_dir}/{chrom}.psl")
        bundle_psl_file_count += 1
        input_files[f"{chrom}.psl"] = 1

        if args["verbose"]:
            print(f"curBases: {cur_bases}  num files: {bundle_psl_file_count} {bundle_psl_file_list}")

        if cur_bases >= args["max_bases"] or bundle_psl_file_count > 1000:
            execute_bundle(args, bundle_psl_file_list, cur_bundle_count)
            cur_bundle_count += 1
            cur_bases = 0
            bundle_psl_file_list = []
            bundle_psl_file_count = 0

    execute_bundle(args, bundle_psl_file_list, cur_bundle_count) if cur_bases > 0 else None
    return cur_bundle_count


def execute_bundle(args, bundle_psl_file_list, cur_bundle_count):
    output_dir = args["output_dir"]
    output_file_path = f"{output_dir}/bundle.{cur_bundle_count}.psl"
    with open(output_file_path, 'w') as outfile:
        for file_path in bundle_psl_file_list:
            with open(file_path, 'r') as infile:
                outfile.write(infile.read())
    print(f"Written to {output_file_path}")


def check_unbundled_files(args, input_files):
    for chrom, read in input_files.items():
        if read == 0:
            input_dir = args["input_dir"]
            chrom_sizes = args["chrom_sizes"]
            message = (
                f"file {input_dir}/{chrom} was not bundled as the "
                f"chrom could not be found in {chrom_sizes}"
            )
            if args["warning_only"]:
                print(f"WARNING: {message}", file=sys.stderr)
            else:
                sys.exit(f"ERROR: {message}")


def bundle_chrom_split_psl_files(input_dir: str,
                                 chrom_sizes: str,
                                 output_dir: str,
                                 max_bases: int = 30000000,
                                 warning_only: bool = False,
                                 verbose: bool = False):
    """
    Translates the bundleChromSplitPstFiles from Perl to Python.

    Parameters:
    - input_dir (str): The input directory containing PSL files.
    - chrom_sizes (str): The file containing chromosome sizes.
    - output_dir (str): The directory where the output will be saved.
    - maxBases (int, optional): The maximum number of bases. Defaults to 30000000.
    - warningOnly (bool, optional): If True, only warnings will be printed. Defaults to False.
    - verbose (bool, optional): If True, verbose output will be printed. Defaults to False.
    """
    args = {
        "input_dir": input_dir,
        "chrom_sizes": chrom_sizes,
        "output_dir": output_dir,
        "max_bases": max_bases,
        "warning_only": warning_only,
        "verbose": verbose
    }
    os.makedirs(output_dir, exist_ok=True)
    chrom_size = read_chrom_sizes(chrom_sizes)
    input_files = get_input_files(input_dir)
    bundle_files(args, chrom_size, input_files)
    cur_bundle_count = bundle_files(args, chrom_size, input_files)
    check_unbundled_files(args, input_files)
    print(f"DONE. Produced {cur_bundle_count + 1} files")


if __name__ == "__main__":
    pass
