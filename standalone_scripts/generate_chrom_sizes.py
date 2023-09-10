#!/usr/bin/env python3
"""Generate chrom.sizes file."""
import sys
import os
import argparse
from collections import Counter
from twobitreader import TwoBitFile
from twobitreader import TwoBitFileError

__author__ = "Bogdan M. Kirilenko"


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


def get_seq_lens_from_twobit(in_file):
    """Parse twobit file if it's twobit file."""
    try:
        two_bit_reader = TwoBitFile(in_file)
        twobit_seq_to_size = two_bit_reader.sequence_sizes()
        return twobit_seq_to_size
    except TwoBitFileError:
        # not a twobit file, try open as fasta
        return None


def count_seq_lens_in_fasta(in_file):
    """In file is fasta, count sequence lengths here."""
    ret = Counter()
    current_seq = None

    with open(in_file, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("#"):
                continue
            if line.startswith(">"):
                current_seq = line[1:]
            else:
                ret[current_seq] += len(line)

    return ret


def main():
    args = parse_args()
    # read what we have as input
    seq_lens = get_seq_lens_from_twobit(args.input)
    if seq_lens is None:
        seq_lens = count_seq_lens_in_fasta(args.input)
    # save out
    f = open(args.output, 'w')
    for k, v in seq_lens.items():
        f.write(f"{k}\t{v}\n")
    f.close()


if __name__ == '__main__':
    main()
