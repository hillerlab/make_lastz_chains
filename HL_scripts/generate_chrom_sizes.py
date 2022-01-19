#!/usr/bin/env python3
"""Generate chrom.sizes file."""
from twobitreader import TwoBitFile
from twobitreader import TwoBitFileError
import sys
import os
import argparse


__author__ = "Bogdan Kirilenko, 2022"


def parse_args():
    app = argparse.ArgumentParser()
    app.add_argument("input", help="Input file, 2bit or fasta")
    app.add_argument("output", help="Where to save chromosome sizes")
    if len(sys.argv) < 3:
        app.print_help()
        sys.exit(0)
    args = app.parse_args()
    if not os.path.isfile(args.input):
        raise ValueError(f"Argument {args.input} is not a file")
    return args


def parse_twobit(in_file):
    """Parse twobit file if it's twobit file."""
    try:
        two_bit_reader = TwoBitFile(in_file)
        twobit_seq_to_size = two_bit_reader.sequence_sizes()
        return twobit_seq_to_size
    except TwoBitFileError:
        # not a twobit file, try open as fasta
        return None


def parse_fasta(in_file):
    """In file is fasta, parse it."""
    current_seq = None
    current_len = 0
    ret = {}

    f = open(in_file, "r")
    for line in f:
        if line.startswith("#"):
            continue
        if line.startswith(">"):
            # sequence identifier
            seq_id = line.lstrip(">").rstrip()
            current_seq = seq_id
            current_len = 0
            ret[current_seq] = 0
        else:
            seq_len = len(line.rstrip())
            ret[current_seq] += seq_len
    f.close()
    return ret


def main():
    args = parse_args()
    # read what we have as input
    seq_lens = parse_twobit(args.input)
    if seq_lens is None:
        seq_lens = parse_fasta(args.input)
    # save out
    f = open(args.output, 'w')
    for k, v in seq_lens.items():
        f.write(f"{k}\t{v}\n")
    f.close()


if __name__ == '__main__':
    main()
