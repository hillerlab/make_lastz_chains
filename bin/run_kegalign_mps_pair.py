#!/usr/bin/env python3

"""
GPU-only KegAlign worker for ONE (reference bin, query bin) chunk pair.

run_mig.py's default worker (run_kegalign_symlink_sort) starts LASTZ processes
while KegAlign is still on the GPU. This pipeline runs gapped extension later,
on CPU, after the GPU allocation ends — so this replaces that worker via
run_mig.py --kegalign_cmd and stops at the packaged tarball.

run_mig.py invokes it as:

    CUDA_MPS_PIPE_DIRECTORY=... CUDA_VISIBLE_DEVICES=<uuid> \
        run_kegalign_mps_pair.py <--opt_cmd words> <target> <query> --debug \
        --output=<part file> --format=<fmt> --num_gpu 1 --num_threads N \
        --uid <path>

Per pair: isolated pair_NNNN/work/{ref,query}.2bit hard links → runner.py
(KegAlign + diagonal partitioning) → package_output.py → keg_NNNN.tgz, which is
byte-for-byte the same kind of package the single-instance KEGALIGN module
produces, so the CPU stage downstream is unchanged.

Self-check (no GPU, KegAlign or LASTZ needed):  run_kegalign_mps_pair.py --self-check
"""

import argparse
import contextlib
import io
import os
import shutil
import subprocess
import sys
import typing

# How much of a failed pair's log to echo, so run_mig.py can still see a GPU
# out-of-memory error in stderr without the pipe filling up.
TAIL_LINES = 50

# runner.py's diagonal-partition sizing raises this when a pair produced a single
# .segments group. Matched on the message because it surfaces as a traceback.
SINGLE_SEGMENT_GROUP = "must have at least two data points"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(allow_abbrev=False, description=__doc__)

    parser.add_argument("target", help="reference chunk FASTA written by split_input.py")
    parser.add_argument("query", help="query chunk FASTA written by split_input.py")
    parser.add_argument("--uid", required=True, help="file to touch once the GPU part is done")
    parser.add_argument("--num_threads", type=int, default=1, help="CPUs for KegAlign and diagonal partitioning")
    parser.add_argument("--format", default="axt+", help="LASTZ output format recorded in the package")

    # Alignment thresholds are required, not defaulted: every MPS instance must
    # run with the same K/L/H/Y the single-instance backend uses (--opt_cmd).
    parser.add_argument("--hspthresh", type=int, required=True, help="LASTZ K")
    parser.add_argument("--gappedthresh", type=int, required=True, help="LASTZ L")
    parser.add_argument("--inner", type=int, required=True, help="LASTZ H")
    parser.add_argument("--ydrop", type=int, required=True, help="LASTZ Y")

    # run_mig.py bookkeeping, accepted and deliberately ignored:
    #   --output        run_mig concatenates its part files at the end, which
    #                   would merge tarballs into garbage; we name our own keg.
    #   --debug         makes runner.py reuse a stale lastz-commands.txt and
    #                   makes kegalign itself very chatty (run_mig does not
    #                   drain the worker's pipes until it exits, so a loud
    #                   worker deadlocks on a full pipe buffer).
    #   --num_gpu       CUDA_VISIBLE_DEVICES already pins exactly one device.
    #   --segment_size  runner.py estimates the diagonal partition size itself,
    #                   as the single-instance KEGALIGN module also lets it.
    parser.add_argument("--output")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--num_gpu", type=int, default=1)
    parser.add_argument("--segment_size", type=int, default=0)

    return parser.parse_args(argv)


def pair_tag(uid: str) -> str:
    """UID_7 → 0007. run_mig.py numbers pairs; that number names our keg."""
    part = os.path.basename(uid).rsplit("_", 1)[-1]
    return f"{int(part):04d}" if part.isdigit() else part


def run(args: list[str], cwd: str, log_pathname: str, check: bool = True) -> int:
    """Run a child with its output on disk, echoing the tail only on failure.

    run_mig.py collects the worker's stdout/stderr with pipes it does not read
    until the worker exits, so anything chatty here risks filling the pipe
    buffer and hanging. The tail on failure keeps enough for run_mig's own
    cudaErrorCudartUnloading resubmission check to still see GPU memory errors.
    """
    with open(log_pathname, "a") as log:
        print(f"+ {' '.join(args)}", file=log, flush=True)
        process = subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)

    if process.returncode != 0 and check:
        die_with_tail(f"ERROR: {args[0]} exited with {process.returncode} for {cwd}", log_pathname)
    return process.returncode


def die_with_tail(message: str, log_pathname: str) -> typing.NoReturn:
    with open(log_pathname) as log:
        sys.stderr.write("".join(log.readlines()[-TAIL_LINES:]))
    sys.exit(f"{message} (full log: {log_pathname})")


def prepare_pair_dir(pair_dir: str, target: str, query: str) -> str:
    """Create pair_NNNN/work/{ref,query}.2bit and return the log pathname.

    runner.py hardcodes "work/" as KegAlign's data folder, relative to the
    working directory, and KegAlign's LASTZ commands name work/ref.2bit and
    work/query.2bit exactly — so every pair needs its own directory.
    """
    work = os.path.join(pair_dir, "work")
    os.makedirs(work, exist_ok=True)
    for source, name in ((f"{target}.2bit", "ref.2bit"), (f"{query}.2bit", "query.2bit")):
        if not os.path.exists(source):
            sys.exit(f"ERROR: missing {source} — split_input.py must run with --to_2bit")
        link = os.path.join(work, name)
        if not os.path.exists(link):
            # Hard link, not symlink: package_output.py realpath()s the archive
            # name as well as the source, and a symlink resolving outside this
            # directory makes it abort with "path fail". A hard link keeps the
            # path inside pair_dir at zero copy cost. Copy across filesystems.
            try:
                os.link(source, link)
            except OSError:
                shutil.copy2(source, link)
    return os.path.join(pair_dir, "runner.log")


def self_check() -> None:
    """Assert the argv contract run_mig.py builds — never typed by a human."""
    # Verbatim shape of run_mig.py's command: --opt_cmd words, then target and
    # query, then its own bookkeeping flags.
    command = (
        "--hspthresh 2400 --gappedthresh 3000 --inner 2000 --ydrop 9400"
        " ref_split/chunk_0 query_split/chunk_1"
        " --debug --output=tmp/part_7.tgz --format=axt+ --num_gpu 1 --num_threads 8"
        " --uid /work/tmp/UID_7"
    )
    args = parse_args(command.split())

    # Reference bin is the target, query bin is the query — never swapped.
    assert args.target == "ref_split/chunk_0", args.target
    assert args.query == "query_split/chunk_1", args.query

    # The four thresholds must survive intact: MPS changes scheduling, not scoring.
    assert (args.hspthresh, args.gappedthresh, args.inner, args.ydrop) == (2400, 3000, 2000, 9400)
    assert args.format == "axt+", args.format
    assert args.num_threads == 8, args.num_threads

    # run_mig.py's pair number names the keg, so kegs cannot collide in one dir.
    assert pair_tag(args.uid) == "0007", pair_tag(args.uid)
    assert pair_tag("/work/tmp/UID_1234") == "1234"

    # --segment_size is appended when run_mig.py is given one: accepted, ignored.
    assert parse_args((command + " --segment_size 5000").split()).segment_size == 5000

    # Losing --opt_cmd must fail loudly, not silently align with KegAlign defaults.
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            parse_args("ref_split/chunk_0 query_split/chunk_1 --uid /work/tmp/UID_7".split())
    except SystemExit:
        pass
    else:
        sys.exit("FAIL: missing --hspthresh/--gappedthresh/--inner/--ydrop was accepted")

    print("run_kegalign_mps_pair self-check OK")


def main() -> None:
    if sys.argv[1:] == ["--self-check"]:
        self_check()
        return

    args = parse_args(sys.argv[1:])

    # runner.py shells out to <tool_directory>/diagonal_partition.py and
    # package_output.py reads <tool_directory>/lastz-cmd.ini; both ship next to
    # the KegAlign executables, as modules/local/kegalign already assumes.
    diagonal_partition = shutil.which("diagonal_partition.py")
    if diagonal_partition is None:
        sys.exit("ERROR: diagonal_partition.py not on PATH — is this the kegalign-full environment?")
    tool_directory = os.path.dirname(diagonal_partition)

    target = os.path.abspath(args.target)
    query = os.path.abspath(args.query)
    tag = pair_tag(args.uid)
    pair_dir = os.path.abspath(f"pair_{tag}")
    keg = os.path.abspath(f"keg_{tag}.tgz")
    log_pathname = prepare_pair_dir(pair_dir, target, query)

    def runner_argv(diagonal_partition: bool) -> list[str]:
        argv = [
            "runner.py",
            "--output-type", "tarball",
            "--output-file", "lastz-commands.txt",
            "--tool_directory", tool_directory,
            "--num-cpu", str(args.num_threads),
        ]
        if diagonal_partition:
            argv.append("--diagonal-partition")
        return argv + [
            target, query,
            "--format", args.format,
            "--hspthresh", str(args.hspthresh),
            "--gappedthresh", str(args.gappedthresh),
            "--inner", str(args.inner),
            "--ydrop", str(args.ydrop),
        ]

    if run(runner_argv(True), pair_dir, log_pathname, check=False) != 0:
        # Upstream runner.py sizes diagonal partitions with statistics.quantiles
        # over the .segments groups, which needs at least two of them. A sparse
        # bin pair (HSPs on one strand only) has one and runner.py dies there.
        # Partitioning only exists to split oversized .segments files, so a pair
        # this small does not need it: redo it unpartitioned — same alignments,
        # just one LASTZ command instead of several.
        with open(log_pathname) as log:
            if SINGLE_SEGMENT_GROUP not in log.read():
                die_with_tail(f"ERROR: runner.py failed for {pair_dir}", log_pathname)
        shutil.rmtree(pair_dir)
        log_pathname = prepare_pair_dir(pair_dir, target, query)
        run(runner_argv(False), pair_dir, log_pathname)

    # The GPU part of this pair is done: free the MPS slot before packaging,
    # which is pure CPU work. run_mig.py still waits for the process itself.
    with open(args.uid, "w"):
        pass

    if os.path.getsize(os.path.join(pair_dir, "lastz-commands.txt")) == 0:
        # Unlike a whole-genome run, a single chunk pair with no HSP above
        # --hspthresh is legitimate. Mark it so the caller's keg count still
        # adds up to reference bins × query bins instead of failing the run.
        with open(f"keg_{tag}.empty", "w"):
            pass
        shutil.rmtree(pair_dir)
        return

    run(
        ["package_output.py", "--tool_directory", tool_directory, "--format_selector", args.format],
        pair_dir,
        log_pathname,
    )

    os.replace(os.path.join(pair_dir, "data_package.tgz"), keg)
    # The .segments files are inside the tarball now; 400 pairs' worth of copies
    # would fill the work directory. Kept on failure, for debugging.
    shutil.rmtree(pair_dir)


if __name__ == "__main__":
    main()
