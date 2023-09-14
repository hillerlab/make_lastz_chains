#!/usr/bin/env python3
"""Rename chromosomes in a chain file based on a rename table.

Needed in case chromosomes were renamed by the pipeline.
The reason is that some tools used in the pipelines cannot handle
some characters that can appear in the chromosome ID.
If this is the case, the pipeline renames the chromosomes and produces a raname table.
This script can rename chromosomes in a resulting chain file based on
the created rename table.

It is placed in the project directory root under a $genomeID_chrom_rename_table.tsv name.
"""
import argparse
import sys


def parse_rename_table(table_path):
    return None


def parse_args():
    app = argparse.ArgumentParser(description="Rename chromosomes in a chain file.")
    app.add_argument("chain_file", help="Chain file")
    app.add_argument("--rename_table_reference")
    app.add_argument("--rename_table_query")
    if len(sys.argv) < 2:
        app.print_help()
        sys.exit(1)
    args = app.parse_args()

    no_ref_table = args.rename_table_reference is None
    no_que_table = args.rename_table_query is None

    if no_ref_table and no_que_table:
        print("Error! Please provide at least one rename table.")
        print("For the reference or for the query.")
        print("Otherwise, this script cannot do anything.")
        sys.exit(1)
    return args


def main():
    args = parse_args()
    # TODO: implement this script


if __name__ == "__main__":
    main()
