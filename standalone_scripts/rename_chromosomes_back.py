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


def _make_chrom_rename_dict(table):
    """Create new chrom name: old chrom name dict."""
    ret = {}
    if table is None:
        # empty dict is also good
        return ret
    f = open(table, "r")
    for line in f:
        ld = line.rstrip().split("\t")
        old_name = ld[0]
        new_name = ld[1]
        ret[new_name] = old_name
    f.close()
    return ret


def rename_chroms_in_chain(not_renamed_chain, t_chrom_dct, q_chrom_dct):
    """Rename chromosomes to original names in the output chains file."""
    in_f = open(not_renamed_chain, "r")
    for line in in_f:
        if not line.startswith("chain"):
            # not a header
            sys.stdout.write(line)
            continue
        # this is a chain header
        header_fields = line.rstrip().split()
        # according to chain file specification fields 2 and 7 contain
        # target and query chromosome/scaffold names
        # 0 field - just the word chain
        t_name = header_fields[2]
        q_name = header_fields[7]

        t_upd = t_chrom_dct.get(t_name)
        q_upd = q_chrom_dct.get(q_name)

        if t_upd is None and q_upd is None:
            # those chromosomes were not renamed, keep line as is
            sys.stdout.write(line)
            continue

        if t_upd:
            header_fields[2] = t_upd
        if q_upd:
            header_fields[7] = q_upd
        upd_header = " ".join(header_fields)
        sys.stdout.write(f"{upd_header}\n")

    in_f.close()


def main():
    args = parse_args()
    t_chrom_dct = _make_chrom_rename_dict(args.rename_table_reference)
    q_chrom_dct = _make_chrom_rename_dict(args.rename_table_query)
    rename_chroms_in_chain(args.chain_file, t_chrom_dct, q_chrom_dct)


if __name__ == "__main__":
    main()
