#!/usr/bin/env python3
"""Intermediate layer to run LASTZ wrapper.

Needed to process the case if many little scaffolds are to be aligned
withing one cluster job."""
import argparse
import subprocess
import sys
import json
from itertools import product


def read_chrom_sizes(chrom_sizes_path):
    """Read chrom.sizes file"""
    chrom_sizes = {}
    f = open(chrom_sizes_path, "r")
    for line in f:
        line_data = line.rstrip().split("\t")
        chrom = line_data[0]
        chrom_size = int(line_data[1])
        chrom_sizes[chrom] = chrom_size
    f.close()
    return chrom_sizes


def read_json_file(file_path):
    with open(file_path, 'r') as f:
        return json.load(f)  # TODO: move to commons


def parse_args():
    """Parse arguments.

    Recapitulates run_lastz.py parameters."""
    app = argparse.ArgumentParser()
    app.add_argument("target", help="Target: single sequence file or .lst")
    app.add_argument("query", help="Query: single sequence file or .lst")
    app.add_argument("params_json", help="pipeline configuration file")
    app.add_argument("output", help="Output file location")
    app.add_argument("run_lastz_script", help="Path to the run_lastz script")

    app.add_argument("--output_format", choices=["psl", "axt"], help="Output format axt|psl")
    app.add_argument("--temp_dir",
                     help="Temp directory to save intermediate fasta files (if needed)\n"
                          "/tmp/ is default, however, params_json key TMPDIR can provide a value"
                          "the command line argument has a higher priority than DEF file"
                    )
    app.add_argument("--verbose",
                     "-v",
                     action="store_true",
                     dest="verbose",
                     help="Show verbosity messages")
    app.add_argument("--axt_to_psl",
                     default="axtToPsl",
                     help="If axtToPst is not in the path, use this"
                          "argument to provide path to this binary, if needed"
                     )

    if len(sys.argv) < 5:
        app.print_help()
        sys.exit(0)
    args = app.parse_args()
    return args


def get_intervals_list(to_ali_arg, chrom_sizes):
    ret = []
    if not to_ali_arg.startswith("BULK"):
        return [to_ali_arg]
    arg_split = to_ali_arg.split(":")
    two_bit_path = arg_split[1]
    chroms_to_be_aligned_in_bulk = arg_split[2:]
    for chrom in chroms_to_be_aligned_in_bulk:
        _start = 0
        _end = chrom_sizes[chrom]
        upd_arg = f"{two_bit_path}:{chrom}:{_start}-{_end}"
        ret.append(upd_arg)
    return ret


def main():
    args = parse_args()
    pipeline_params = read_json_file(args.params_json)
    seq_1_sizes_path = pipeline_params["seq_1_len"]
    seq_2_sizes_path = pipeline_params["seq_2_len"]
    target_chrom_sizes = read_chrom_sizes(seq_1_sizes_path)
    query_chrom_sizes = read_chrom_sizes(seq_2_sizes_path)

    target_coordinates = get_intervals_list(args.target, target_chrom_sizes)
    query_coordinates = get_intervals_list(args.query, query_chrom_sizes)

    for target_arg, query_arg in product(target_coordinates, query_coordinates):
        lastz_cmd = [
            args.run_lastz_script,
            target_arg,
            query_arg,
            args.params_json,
            args.output,
            "--output_format",
            args.output_format,
        ]
        if args.temp_dir:
            lastz_cmd.append(f"--temp_dir")
            lastz_cmd.append(args.temp_dir)
        if args.axt_to_psl:
            lastz_cmd.append(f"--axt_to_psl")
            lastz_cmd.append(args.axt_to_psl)
        print(" ".join(lastz_cmd))
        subprocess.call(lastz_cmd)


if __name__ == "__main__":
    main()
