#!/usr/bin/env python3
"""Replacement for splitChain_into_randomParts.pl

I don't write in Perl so rewriting the script in Python
is more time and resources efficient than just rewriting
the original script.
"""
import argparse
import os
import sys
import random

__author__ = "Bogdan Kirilenko, perl version: Nikolai Hecker"

DESCRIPTION = """Splits a chain file into n chain split files,
randomly picking chain ids.\nExample usage:\n
$0 -c hg38.speTri2.all.chain -n 100 -p splitChains_hg38_speTri2_\n\n";
Given very large chains this script might be somewhat heavy
on memory for storing millions of chainIDs.\n";
"""


def parse_args():
    app = argparse.ArgumentParser(description=DESCRIPTION)
    app.add_argument("--chain", "-c", help="Chain file to be split")
    app.add_argument("--prefix", "-p", help="Prefix for output files")
    app.add_argument("--nsplit",
                     "-n", 
                     help="Number desired files chain is split into")
    if len(sys.argv) < 4:
        app.print_help()
        sys.exit(0)
    args = app.parse_args()
    if any(x is None for x in (args.chain, args.prefix, args.nsplit)):
        # !! I recapitulated the perl script argument parset procedure
        # for compatibility, of course it would be better to explictly
        # set these arguments as mandatory
        app.print_help()
        sys.exit(0)
    return args


def split_in_n_lists(lst, n):
    """Split a list into n list of more or less equal length."""
    if n <= 0:  # must never happen
        sys.stderr.write("Error! Method split_in_n_lists called with n == 0\n")
        sys.exit(1)
    lst_len = len(lst)
    if n >= lst_len:
        # pigeonhole principle in work
        return [[x] for x in lst]
    ret = []  # list of lists
    sublist_len = lst_len / float(n)
    last = 0.0
    while last < len(lst):
        sublist = lst[int(last) : int(last + sublist_len)]
        ret.append(sublist)
        last += sublist_len
    return ret


def read_chain_ids(chain_file):
    """Just grab a list of chain IDs in the present file."""
    ret = []
    f = open(chain_file, 'r')
    for line in f:
        if not line.startswith('chain'):
            continue
        ld = line.rstrip().split(" ")
        ret.append(int(ld[-1]))
    f.close()
    return ret


def main():
    """Entry point."""
    args = parse_args()
    chain_ids = read_chain_ids(args.chain)


if __name__ == "__main__":
    main()
