#!/usr/bin/env python3
"""Python replacement for chainExtractID

Chain index is just a BST saved into a separate file.
Using this index file for any chain ID we can extract:
1) Start byte of this chain in the chain file
2) Length of this chain in the file.
And then simply extract it.

Arguments fit standard chainExtractID for compatibility with
existing scripts.
"""
import argparse
import sys
import os
import ctypes

SLIB_NAME = "chain_bst_lib.so"


def chain_extract_id(index_file, chain_id, chain_file=None):
    """Extract chain text using index file."""
    # within TOGA should be fine:
    chain_file = chain_file if chain_file else index_file.replace(".bst", ".chain")
    if not os.path.isfile(chain_file):
        # need this check anyways
        sys.exit(f"chain_extract_id error: cannot find {chain_file} file")
    # connect shared library
    # .so must be there: in the modules/ dir
    script_location = os.path.dirname(__file__)
    slib_location = os.path.join(script_location, SLIB_NAME)
    sh_lib = ctypes.CDLL(slib_location)
    sh_lib.get_s_byte.argtypes = [
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_uint64),
        ctypes.POINTER(ctypes.c_uint64),
    ]
    sh_lib.get_s_byte.restype = ctypes.c_uint64

    # call library: find chain start byte and offset
    c_index_path = ctypes.c_char_p(index_file.encode())
    c_chain_id = ctypes.c_uint64(int(chain_id))
    c_sb = ctypes.c_uint64(0)  # write results in c_sb and c_of
    c_of = ctypes.c_uint64(0)  # provide them byref -> like pointers

    _ = sh_lib.get_s_byte(
        c_index_path, c_chain_id, ctypes.byref(c_sb), ctypes.byref(c_of)
    )

    if c_sb.value == c_of.value == 0:
        # if they are 0: nothing found then, raise Error
        sys.stderr.write(f"Error, chain {chain_id} ")
        sys.stderr.write("not found\n")
        sys.exit(1)

    # we got start byte and offset, extract chain from the file
    f = open(chain_file, "rb")
    f.seek(c_sb.value)  # jump to start_byte_position
    chain = f.read(c_of.value).decode("utf-8")  # read OFFSET bytes
    f.close()
    return chain


def parse_args():
    """Command line arguments parser."""
    app = argparse.ArgumentParser()
    app.add_argument("chainIndex", help="ChainIndex.bb - chain file index produced by chainIndexID.py")
    app.add_argument("chainFile", help="Actual chain file")
    app.add_argument("out", help="Output")
    app.add_argument("-idList", help="Comma-separated list of chain identifiers")

    if len(sys.argv) < 5:
        app.print_help()
        sys.exit(0)
    # TODO: other arguments?
    args = app.parse_args()
    return args
    

def main():
    args = parse_args()
    # TODO: check that numeric?
    chain_ids = [int(x) for x in args.idList.split(",") if x != ""]
    for chain_id in chain_ids:
        chain_str = chain_extract_id(args.chainIndex, chain_id, chain_file=args.chainFile)
        sys.stdout.write(chain_str)


if __name__ == "__main__":
    main()
