#!/usr/bin/env python3
"""SplitChainIntoRandomParts.perl reimplementation"""
import argparse
import random

DESCRIPTION = "Splits a chain file into n chain split files, randomly picking chain ids."


def parse_args():
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument("-c", "--chain", required=True, help="Chain file to be split")
    parser.add_argument("-p", "--prefix", required=True, help="Prefix for output files")
    parser.add_argument("-n",
                        "--nsplit",
                        required=True,
                        type=int,
                        help="Number of desired files chain is split into")
    return parser.parse_args()


def get_chain_ids(chain_file):
    with open(chain_file, 'r') as f:
        return [int(line.strip().split()[-1]) for line in f if line.startswith("chain")]


def assign_ids_to_files(chain_ids, nsplit):
    random.shuffle(chain_ids)
    return {chain_id: i % nsplit for i, chain_id in enumerate(chain_ids)}


def split_chain_file(chain_file, id_to_fh, fhs):
    with open(chain_file, 'r') as f:
        for line in f:
            if line.startswith("chain"):
                chain_id = int(line.strip().split()[-1])
                out_fh = fhs[id_to_fh[chain_id]]

                out_fh.write(line)
                for inner_line in f:
                    if not inner_line.strip().isdigit():
                        break
                    out_fh.write(inner_line)
                out_fh.write("\n")


def main():
    args = parse_args()

    chain_ids = get_chain_ids(args.chain)
    print(f"Found {len(chain_ids)} chain IDs")

    id_to_fh = assign_ids_to_files(chain_ids, args.nsplit)

    fhs = [open(f"{args.prefix}{i}", 'w') for i in range(args.nsplit)]

    split_chain_file(args.chain, id_to_fh, fhs)

    for fh in fhs:
        fh.close()

    print(f"Wrote output to {args.nsplit} files starting with '{args.prefix}'.")


if __name__ == "__main__":
    main()
