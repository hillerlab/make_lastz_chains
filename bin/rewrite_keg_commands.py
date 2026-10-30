#!/usr/bin/env python3

"""
Rewrite KegAlign-generated LASTZ commands so the CPU gapped-extension stage
reads per-block FASTA instead of a .2bit file.

Why: the keg's commands name their inputs as
  work/ref.2bit[nameparse=darkspace][multiple][subset=ref_blockN.name]
  work/query.2bit[nameparse=darkspace][subset=query_blockN.name]
For genomes whose .2bit would exceed the v0 32-bit layout (faToTwoBit emits v1
via -long) this breaks: lastz cannot read v1. The block FASTAs built here hold
exactly the sequences each .name subset lists, so the rewritten commands align
the same bases. The kegalign GPU binary itself reads the positional FASTAs, so
skipping the .2bit hop changes nothing upstream of this file.

Usage (inside the KEGALIGN task, after runner.py, before package_output.py):
  rewrite_keg_commands.py --commands lastz-commands.txt \\
      --ref-fasta ref.fa --query-fasta query.fa --data-folder work

Self-check (no KegAlign or LASTZ needed):  rewrite_keg_commands.py --self-check
"""

import argparse
import os
import re
import sys
import typing

TARGET_RE = re.compile(
    r"(?P<folder>\S*?)ref\.2bit\[nameparse=darkspace\]\[multiple\]"
    r"\[subset=(?P<subset>[^\]\s]+\.name)\]"
)
QUERY_RE = re.compile(
    r"(?P<folder>\S*?)query\.2bit\[nameparse=darkspace\]"
    r"\[subset=(?P<subset>[^\]\s]+\.name)\]"
)


def find_subset_file(folder: str, subset: str) -> str:
    """Return the subset .name file the kegalign binary wrote.

    The binary writes it to its working directory, while the command text
    addresses it relative to the .2bit's folder — try both, fail loudly.
    """
    for candidate in (os.path.join(folder, subset), subset):
        if os.path.isfile(candidate):
            return candidate
    sys.exit(f"ERROR: subset file {subset!r} not found in {folder!r} or ./")


def load_fasta(pathname: str) -> dict[str, list[str]]:
    """Read a FASTA into {name: raw record lines}, names darkspace-parsed."""
    records: dict[str, list[str]] = {}
    name: str | None = None
    with open(pathname) as handle:
        for line in handle:
            if line.startswith(">"):
                name = line[1:].split()[0]
                records[name] = [line]
            elif name is None:
                sys.exit(f"ERROR: sequence data before any header in {pathname}")
            else:
                records[name].append(line)
    return records


def subset_names(pathname: str) -> list[str]:
    """Return the sequence names a .name subset file lists, in order."""
    names = []
    with open(pathname) as handle:
        for line in handle:
            line = line.strip()
            if line:
                names.append(line.split()[0])
    return names


def block_fasta_path(folder: str, subset: str) -> str:
    """Derive the block FASTA path from its subset name: ref_block0.name -> ref_block0.fa."""
    return os.path.join(folder, os.path.basename(subset)[: -len(".name")] + ".fa")


def build_block_fasta(
    subset_path: str, fasta: dict[str, list[str]], output_path: str
) -> int:
    """Write the subset's sequences from the genome FASTA; return the count."""
    names = subset_names(subset_path)
    missing = [name for name in names if name not in fasta]
    if missing:
        sys.exit(f"ERROR: {subset_path} names {missing[:3]}... absent from the genome FASTA")
    with open(output_path, "w") as out:
        for name in names:
            out.writelines(fasta[name])
    return len(names)


def rewrite_line(
    line: str,
    ref_fasta: dict[str, list[str]],
    query_fasta: dict[str, list[str]],
    built: dict[str, int],
) -> str:
    """Swap one command's .2bit sequence args for per-block FASTAs, building them once."""

    def swap(match: re.Match, fasta: dict[str, list[str]], multiple: bool) -> str:
        folder, subset = match.group("folder"), match.group("subset")
        output = block_fasta_path(folder, subset)
        if output not in built:
            built[output] = build_block_fasta(
                find_subset_file(folder, subset), fasta, output
            )
        return f"{output}{'[multiple]' if multiple else ''}"

    line, n_target = TARGET_RE.subn(lambda m: swap(m, ref_fasta, True), line)
    line, n_query = QUERY_RE.subn(lambda m: swap(m, query_fasta, False), line)
    if n_target != 1 or n_query != 1:
        sys.exit(f"ERROR: expected exactly 1 ref + 1 query .2bit arg, got {n_target}/{n_query}: {line!r}")
    return line


def main(argv: typing.Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-check", action="store_true", help="run internal asserts")
    parser.add_argument("--commands", help="lastz-commands.txt, rewritten in place")
    parser.add_argument("--ref-fasta", help="reference FASTA runner.py received")
    parser.add_argument("--query-fasta", help="query FASTA runner.py received")
    parser.add_argument("--data-folder", default="work", help="folder the commands address")
    args = parser.parse_args(argv)

    if args.self_check:
        self_check()
        return

    missing = [f"--{n.replace('_', '-')}" for n in ("commands", "ref_fasta", "query_fasta") if not getattr(args, n)]
    if missing:
        sys.exit(f"ERROR: missing required arguments: {', '.join(missing)}")

    ref_fasta = load_fasta(args.ref_fasta)
    query_fasta = load_fasta(args.query_fasta)

    with open(args.commands) as handle:
        lines = handle.read().splitlines()

    built: dict[str, int] = {}
    rewritten = [rewrite_line(line, ref_fasta, query_fasta, built) for line in lines if line.strip()]

    if not rewritten:
        sys.exit(f"ERROR: {args.commands} holds no commands to rewrite")

    with open(args.commands, "w") as handle:
        handle.write("\n".join(rewritten) + "\n")

    total = sum(built.values())
    print(
        f"rewrite_keg_commands: {len(rewritten)} command(s) now read "
        f"{len(built)} block FASTA(s), {total} sequence(s) total",
        file=sys.stderr,
    )


def self_check() -> None:
    """Assert the rewrite against the grammar runner.py emits — no tools needed."""
    import tempfile

    command = (
        "lastz work/ref.2bit[nameparse=darkspace][multiple][subset=ref_block0.name] "
        "work/query.2bit[nameparse=darkspace][subset=query_block1.name] "
        "--format=axt+ --ydrop=9400 --gappedthresh=3000 --strand=minus "
        "--segments=tmp0.block0.r0.minus.segments --output=tmp0.block0.r0.minus.axt+ "
        "2> tmp0.block0.r0.minus.err"
    )

    with tempfile.TemporaryDirectory() as tmp:
        cwd = os.getcwd()
        os.chdir(tmp)
        try:
            os.mkdir("work")
            with open("ref.fa", "w") as handle:
                handle.write(">chr1 desc\nACGT\n>chr2\nTGCA\n")
            with open("query.fa", "w") as handle:
                handle.write(">scaf1\nGGCC\n")
            with open("ref_block0.name", "w") as handle:
                handle.write("chr1\nchr2\n")
            with open("query_block1.name", "w") as handle:
                handle.write("scaf1\n")
            with open("lastz-commands.txt", "w") as handle:
                handle.write(command + "\n")

            main(
                [
                    "--commands", "lastz-commands.txt",
                    "--ref-fasta", "ref.fa",
                    "--query-fasta", "query.fa",
                    "--data-folder", "work",
                ]
            )

            rewritten = open("lastz-commands.txt").read().splitlines()
            assert len(rewritten) == 1, rewritten
            # target keeps [multiple] (as the keg prints it), query never had it
            assert rewritten[0] == (
                "lastz work/ref_block0.fa[multiple] work/query_block1.fa "
                "--format=axt+ --ydrop=9400 --gappedthresh=3000 --strand=minus "
                "--segments=tmp0.block0.r0.minus.segments --output=tmp0.block0.r0.minus.axt+ "
                "2> tmp0.block0.r0.minus.err"
            ), rewritten[0]
            assert open("work/ref_block0.fa").read() == ">chr1 desc\nACGT\n>chr2\nTGCA\n"
            assert open("work/query_block1.fa").read() == ">scaf1\nGGCC\n"

            # A line without the expected pair is an error, not a silent pass-through.
            with open("lastz-commands.txt", "w") as handle:
                handle.write("lastz something/else.fa --format=axt+\n")
            try:
                main(
                    [
                        "--commands", "lastz-commands.txt",
                        "--ref-fasta", "ref.fa",
                        "--query-fasta", "query.fa",
                    ]
                )
            except SystemExit:
                pass
            else:
                sys.exit("FAIL: a command without .2bit args was accepted")

            # A dangling subset reference is an error, not an empty FASTA.
            with open("lastz-commands.txt", "w") as handle:
                handle.write(command.replace("query_block1", "query_block9") + "\n")
            try:
                main(
                    [
                        "--commands", "lastz-commands.txt",
                        "--ref-fasta", "ref.fa",
                        "--query-fasta", "query.fa",
                    ]
                )
            except SystemExit:
                pass
            else:
                sys.exit("FAIL: a missing subset file was accepted")
        finally:
            os.chdir(cwd)

    print("rewrite_keg_commands self-check OK")


if __name__ == "__main__":
    main()
