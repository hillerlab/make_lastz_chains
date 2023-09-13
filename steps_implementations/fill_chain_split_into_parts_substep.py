"""Split chain into random parts module."""
import random


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
                    if inner_line == "\n":
                        break
                    out_fh.write(inner_line)
                out_fh.write("\n")


def randomly_split_chains(chain, nsplit, prefix):
    chain_ids = get_chain_ids(chain)
    print(f"Found {len(chain_ids)} chain IDs")

    id_to_fh = assign_ids_to_files(chain_ids, nsplit)
    max_num_filex = max(id_to_fh.values()) + 1

    fhs = [open(f"{prefix}{i}", 'w') for i in range(max_num_filex)]
    split_chain_file(chain, id_to_fh, fhs)

    for fh in fhs:
        fh.close()

    print(f"Wrote output to {max_num_filex} files starting with '{prefix}'.")


if __name__ == "__main__":
    pass
