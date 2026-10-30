#!/usr/bin/env python
#
# Vendored verbatim from KegAlign, scripts/mps-mig/split_input.py (MIT)
#   https://github.com/galaxyproject/KegAlign @ ea16d549d2bd3fa49e0e4b27e40bf32708c109f3
#   Copyright (c) 2020 Sneha D. Goenka, Yatish Turakhia, Benedict Paten, Mark Horowitz
#   Copyright (c) 2025 A. Burak Gulhan, Richard Burhans, Robert Harris, Mahmut Kandemir,
#                      Maximilian Haeussler, Anton Nekrutenko
#
# The kegalign-full conda package does not ship scripts/mps-mig, so both scripts
# live here; Nextflow prepends bin/ to PATH inside the container. Keep verbatim —
# re-vendor from upstream rather than patching locally.

"""
Split an input genome file into multiple files with size near goal_bp. Individual chromosomes are not split.

Usage example:
split_input.py --input <input_genome> --out ./blocked_20_chr_hg38 --to_2bit true --goal_bp 200000000 --max_chunks 20
"""

import argparse
import collections
import concurrent.futures
import gzip
import heapq
import math
import os
import re
import resource
import subprocess
import sys
import time
import typing

TEN_MB: typing.Final = 10_000_000
TEN_KB: typing.Final = 10_000

RUSAGE_ATTRS: typing.Final = [
    "ru_utime",
    "ru_stime",
    "ru_maxrss",
    "ru_minflt",
    "ru_majflt",
    "ru_inblock",
    "ru_oublock",
    "ru_nvcsw",
    "ru_nivcsw",
]

FastaSequence = collections.namedtuple(
    "FastaSequence", ["description", "sequence", "length"], defaults=["", "", 0]
)


def debug_start(
    who: int = resource.RUSAGE_SELF, message: str = ""
) -> tuple[resource.struct_rusage, int, int]:
    print(f"DEBUG: {message}", file=sys.stderr, flush=True)
    r_beg = resource.getrusage(who)
    beg = time.monotonic_ns()
    return r_beg, beg, who


def debug_end(
    r_beg: resource.struct_rusage, beg: int, who: int, message: str = ""
) -> None:
    ns = time.monotonic_ns() - beg
    r_end = resource.getrusage(who)
    print(f"DEBUG: {message}: {ns} ns", file=sys.stderr, flush=True)
    for rusage_attr in RUSAGE_ATTRS:
        value = getattr(r_end, rusage_attr) - getattr(r_beg, rusage_attr)
        print(f"DEBUG:   {rusage_attr}: {value}", file=sys.stderr, flush=True)


class FastaFile:
    def __init__(self, pathname: str, debug: bool = False) -> None:
        self.pathname = pathname
        self.sequences: list[FastaSequence] = []
        self._read_fasta()
        self.sequences.sort(key=lambda x: x.length, reverse=True)

    def _read_fasta(self) -> None:
        description = ""
        seqs: list[str] = []

        if args.debug:
            debug_r_beg, debug_beg, debug_who = debug_start(
                resource.RUSAGE_SELF, f"loading fasta {self.pathname}"
            )

        with self._get_open_method() as f:
            for line in f:
                line = line.rstrip()

                if line.startswith(">"):
                    if seqs:
                        sequence = "".join(seqs)
                        self.sequences.append(
                            FastaSequence(description, sequence, len(sequence))
                        )
                        seqs.clear()

                    description = line
                else:
                    seqs.append(line)

            if seqs:
                sequence = "".join(seqs)
                self.sequences.append(
                    FastaSequence(description, sequence, len(sequence))
                )

        if args.debug:
            debug_end(
                debug_r_beg,
                debug_beg,
                debug_who,
                f"loaded fasta {self.pathname}",
            )

    def _get_open_method(self) -> typing.TextIO:
        try:
            with open(self.pathname, "rb") as f:
                if f.read(2) == b"\x1f\x8b":
                    return gzip.open(self.pathname, mode="rt")
        except FileNotFoundError:
            sys.exit(f"ERROR: Unable to read file: {self.pathname}")
        except Exception:
            pass

        return open(self.pathname, mode="rt")

    @property
    def total_bases(self) -> int:
        total = 0
        for fasta_sequence in self.sequences:
            total += fasta_sequence.length

        return total

    def __iter__(self) -> typing.Iterator[FastaSequence]:
        for fasta_sequence in self.sequences:
            yield fasta_sequence

    def to_single_seq(self) -> None:
        description = self.sequences[0].description
        sequence = "".join([seq.sequence for seq in self.sequences])

        self.sequences.clear()
        self.sequences.append(FastaSequence(description, sequence, len(sequence)))

    def discard_sequences_after_and_including(
        self, description: str, debug: bool = False
    ) -> None:
        split_index = -1
        for idx, sequence in enumerate(self.sequences):
            if sequence.description == f">{description}":
                split_index = idx
                break

        if split_index == -1:
            sys.exit(f"ERROR: sequence {description} not found")

        if debug:
            print(
                f"DEBUG: discarding sequences after and including {description}",
                file=sys.stdout,
                flush=True,
            )

        if split_index == 0:
            self.sequences.clear()
        else:
            self.sequences = self.sequences[: split_index - 1]


def convert_to_2bit(root_dir: str) -> None:
    commands = []

    for dirpath, dirnames, filenames in os.walk(root_dir):
        for filename in filenames:
            match = re.match(r"chunk_\d+$", filename)
            if match:
                pathname = os.path.join(root_dir, filename)
                new_pathname = f"{pathname}.2bit"
                command = f"faToTwoBit {pathname} {new_pathname}"
                commands.append(command)

    cpus_available = len(os.sched_getaffinity(0))
    num_commands = len(commands)
    if cpus_available > num_commands:
        cpus_available = num_commands

    if args.debug:
        print(
            f"DEBUG: converting to 2bit {cpus_available} CPUs",
            file=sys.stderr,
            flush=True,
        )

    with concurrent.futures.ProcessPoolExecutor(max_workers=cpus_available) as executor:
        for _ in executor.map(twobit_wrapper, commands):
            pass


def twobit_wrapper(command: str) -> None:
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, shell=True
    )
    stdout, stderr = process.communicate()
    if stdout:
        print(f"{stdout}", file=sys.stdout)
    if stderr:
        print(f"{stderr}", file=sys.stderr)


def split_chr(
    target_fasta: FastaFile,
    output_dir: str,
    num_chunks: int,
    write_to_output_dir: bool = True,
    debug: bool = False,
) -> list[int]:
    # Longest-processing-time-first Algorithm
    # sequence length is used as a proxy for processing-time
    chunk_size_list = []

    pq: list[tuple[int, int]] = []
    for i in range(num_chunks):
        heapq.heappush(pq, (0, i))  # bin size and bin id

    files: dict[int, list[int]] = {}
    for i in range(num_chunks):
        files[i] = []

    i = 0
    for sequence in target_fasta:
        # get smallest file
        size, bin_no = heapq.heappop(pq)
        size += sequence.length
        heapq.heappush(pq, (size, bin_no))
        files[bin_no].append(i)
        i += 1

    seen_inds = []  # for sanity checking

    for bin_no, chr_indexes in files.items():
        bin_size = 0

        for ind in chr_indexes:
            assert ind not in seen_inds  # sanity check
            seen_inds.append(ind)
            bin_size += target_fasta.sequences[ind].length

        if debug:
            print(
                f"DEBUG: chunk_{bin_no} num bp {bin_size}", file=sys.stderr, flush=True
            )

        chunk_size_list.append(bin_size)
        block_file_name = os.path.join(output_dir, f"chunk_{bin_no}")

        if write_to_output_dir:
            with open(block_file_name, "w") as out_file:
                for ind in chr_indexes:
                    sequence = target_fasta.sequences[ind]
                    print(f"{sequence.description}", file=out_file)
                    print(f"{sequence.sequence}", file=out_file)

    if debug:
        print(
            f"packed {len(target_fasta.sequences)} sequences into {num_chunks} bins",
            file=sys.stderr,
            flush=True,
        )

    assert len(seen_inds) == len(target_fasta.sequences)
    assert len(chunk_size_list) == num_chunks
    return chunk_size_list


def parallel_wrapper(pass_list: tuple[str, str, int, bool, bool]) -> list[int]:
    _pass_list = (FastaFile(pass_list[0]), pass_list[1], pass_list[2], pass_list[3])
    return split_chr(*_pass_list)


def mse(data: list[int], base: int) -> float:
    mse = [(base - i) ** 2 for i in data]
    return sum(mse) / len(mse)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--input",
        type=str,
        required=True,
        help="Input sequence in fasta or fasta.gz format",
    )
    parser.add_argument("--out", type=str, required=True, help="Output directory")
    parser.add_argument(
        "--to_2bit", action="store_true", help="Convert partitioned inputs into .2bit format"
    )

    parser.add_argument(
        "--max_chunks",
        default=20,
        type=int,
        help="Maximum number of chunks to split input into. If --goal_bp is not provided, this is the exact number of bins to partition input into",
    )
    # TODO: could get rid of max_chunks parameter by checking whether local
    # minima is enountered when calculating mse, when goal_bp is provided

    parser.add_argument(
        "--goal_bp",
        default=0,
        type=int,
        help="Goal basepairs count for each partition. Number of partitions calculated using MSE. Check up to --max_chunks number of bins",
    )
    parser.add_argument("--debug", action="store_true", help="Print debug information")

    if len(sys.argv) <= 1:
        parser.print_help()
        sys.exit(0)

    args = parser.parse_args()

    target_file = args.input
    # target_fasta = FastaFile(target_file, debug=args.debug)

    target_block_dir = args.out

    if not os.path.exists(args.input):
        print(f"Input file {args.input} does not exist.")
        exit(1)

    os.makedirs(target_block_dir, exist_ok=True)

    if args.goal_bp:
        bin_count = args.max_chunks
        goal_bp = args.goal_bp
        best_bin_count = -1
        best_bin_loss = math.inf
        # NOTE: FastaFile object is not serializable and using it in pass list
        # prevents parallel execution. As a workaround, pass the input file path
        # and initialize FastFile object in parallel_wrapper
        # TODO: find a better way to do this
        pass_list = [
            (target_file, "", i, False, False) for i in range(1, bin_count + 1)
        ]

        cpus_available = len(os.sched_getaffinity(0))
        if cpus_available > bin_count:
            cpus_available = bin_count

        if args.debug:
            print(
                f"DEBUG: spliting using {cpus_available} CPUs",
                file=sys.stderr,
                flush=True,
            )

        with concurrent.futures.ProcessPoolExecutor(
            max_workers=cpus_available
        ) as executor:
            for bins in executor.map(parallel_wrapper, pass_list):
                i = len(bins)
                loss = mse(bins, goal_bp)

                if args.debug:
                    print(
                        f"DEBUG: * bin count {i}, mse {int(loss)}, bins {bins}",
                        file=sys.stderr,
                        flush=True,
                    )

                if loss < best_bin_loss:
                    best_bin_count = i
                    best_bin_loss = loss

        bin_count = best_bin_count
    else:
        bin_count = args.max_chunks
    if args.debug:

        if args.goal_bp:
            print(
                print(f"bin_count = {bin_count}, loss={best_bin_loss}"),
                file=sys.stderr,
                flush=True,
            )
        else:
            print(
                f"DEBUG: bin_count = {bin_count}",
                file=sys.stderr,
                flush=True,
            )

    # TODO: this is a bit inefficient, since this was already calculated
    # in parallel_wrapper (if goal_bp provided), but was not written to
    # output directory
    target_fasta = FastaFile(target_file, debug=args.debug)
    split_chr(target_fasta, target_block_dir, bin_count)

    if args.to_2bit:
        # Convert to 2bit format
        convert_to_2bit(target_block_dir)
