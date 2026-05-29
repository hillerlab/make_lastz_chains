#!/usr/bin/env python3
"""Standalone chain-splitting script for nf-core make_lastz_chains pipeline.

Randomly splits a chain file into N roughly equal parts for parallel gap-filling.

Usage:
    split_chains.py --chain merged.chain --num_parts 1000 --output_dir chain_chunks/
"""
import argparse
import os
import random
import sys


def get_chain_ids(chain_file):
    ids = []
    with open(chain_file) as f:
        for line in f:
            if line.startswith("chain"):
                ids.append(int(line.strip().split()[-1]))
    return ids


def assign_ids_to_files(chain_ids, nsplit):
    random.shuffle(chain_ids)
    return {chain_id: i % nsplit for i, chain_id in enumerate(chain_ids)}


def split_chain_file(chain_file, id_to_fh, fhs):
    with open(chain_file) as f:
        for line in f:
            if line.startswith("chain"):
                chain_id = int(line.strip().split()[-1])
                out_fh = fhs[id_to_fh[chain_id]]
                out_fh.write(line)
                for inner_line in f:
                    if inner_line == "\n":
                        break
                    out_fh.write(inner_line)
                out_fh.write("\n")


def parse_args():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--chain", required=True,
                    help="Input chain file (uncompressed)")
    ap.add_argument("--num_parts", type=int, required=True,
                    help="Number of output parts to split into (actual number may be less "
                         "if fewer chains are present)")
    ap.add_argument("--output_dir", required=True,
                    help="Output directory for split chain files "
                         "(files named infill_chain_0, infill_chain_1, …)")
    if len(sys.argv) < 2:
        ap.print_help()
        sys.exit(1)
    return ap.parse_args()


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    chain_ids = get_chain_ids(args.chain)
    print(f"Found {len(chain_ids)} chains", file=sys.stderr)

    if not chain_ids:
        print("No chains found — nothing to split", file=sys.stderr)
        sys.exit(0)

    nsplit = min(args.num_parts, len(chain_ids))
    id_to_fh = assign_ids_to_files(chain_ids, nsplit)
    max_files = max(id_to_fh.values()) + 1

    prefix = os.path.join(args.output_dir, "infill_chain_")
    fhs = [open(f"{prefix}{i}", "w") for i in range(max_files)]
    split_chain_file(args.chain, id_to_fh, fhs)
    for fh in fhs:
        fh.close()

    print(f"Wrote {max_files} split chain files to {args.output_dir}", file=sys.stderr)


if __name__ == "__main__":
    main()
