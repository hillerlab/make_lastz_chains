#!/usr/bin/env python3
"""Run ONE KegAlign-generated LASTZ partition and convert its AXT+ output to PSL.

In `distributed` mode Nextflow is the orchestrator, so this replaces only the
per-command execution that run_lastz_tarball.py performs inside its own process
pool — none of its multiprocessing/queueing logic is reproduced here.

The LASTZ arguments KegAlign generated are used verbatim. They name their inputs
by paths relative to the package's galaxy/files directory, so those inputs are
symlinked into the task directory instead of being rewritten; LASTZ output then
lands in the task directory rather than inside the staged package.

Self-check (no LASTZ or GPU needed):  run_keg_lastz.py --self-check
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from typing import Any, Sequence

__author__ = "Alejandro Gonzales-Irribarren"
__email__ = "alejandro.gonzales-irribarren@senckenberg.de"
__github__ = "https://github.com/hillerlab/make_lastz_chains"

# run_lastz_tarball.py prepends this to every command it runs.
TRACEBACK_ARG = "--allocate:traceback=1.99G"

# LASTZ writes these to stderr on a segmented (not failed) alignment — upstream
# treats them as success, so we must too or we would fail healthy partitions.
TRUNCATION_RE = re.compile(
    r"truncating alignment (ending|starting) at \(\d+,\d+\);  anchor at \(\d+,\d+\)$"
)
TRUNCATION_MSG = (
    "truncation can be reduced by using --allocate:traceback to increase "
    "traceback memory"
)

# Upstream accepts 1 as well as 0: LASTZ exits 1 when it produced no alignment.
LASTZ_OK_RETURNCODES = (0, 1)

DATA_SUBDIR = os.path.join("galaxy", "files")
COMMANDS_JSON = os.path.join("galaxy", "commands.json")


class KegLastzError(Exception):
    """Report an unusable package, command, or subprocess failure."""


def load_command(package: str, segments: str) -> dict[str, Any]:
    """Return the commands.json record whose --segments= names this partition."""
    path = os.path.join(package, COMMANDS_JSON)
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError as error:
        raise KegLastzError(f"package is missing {COMMANDS_JSON}: {path}") from error

    matches = []
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise KegLastzError(f"bad JSON line in {path}: {line!r}") from error
        if f"--segments={segments}" in record.get("args", []):
            matches.append(record)

    if len(matches) != 1:
        raise KegLastzError(
            f"expected exactly 1 command for --segments={segments}, found {len(matches)}"
        )
    return matches[0]


def build_argv(args: Sequence[str], lastz: str = "lastz") -> list[str]:
    """Rebuild the LASTZ argv, restoring target/query as leading positionals.

    package_output.py stored them as --target=/--query= so they survive JSON;
    run_lastz_tarball.py puts them back at positions 0 and 1.
    """
    target = query = None
    options: list[str] = []
    for arg in args:
        if arg.startswith("--target="):
            target = arg[len("--target=") :]
        elif arg.startswith("--query="):
            query = arg[len("--query=") :]
        else:
            options.append(arg)

    if target is None or query is None:
        raise KegLastzError(f"command is missing --target=/--query=: {list(args)}")

    return [lastz, TRACEBACK_ARG, target, query, *options]


def input_paths(args: Sequence[str]) -> list[str]:
    """Return every package-relative input path the LASTZ arguments reference.

    Sequence arguments look like ``work/ref.2bit[nameparse=darkspace][multiple]
    [subset=ref_block0.name]`` — both the .2bit and the subset list are files.
    """
    paths: list[str] = []
    for arg in args:
        for prefix in ("--target=", "--query="):
            if arg.startswith(prefix):
                spec = arg[len(prefix) :]
                elements = spec.split("[")
                paths.append(elements.pop(0))
                for element in elements:
                    element = element.removesuffix("]")
                    if element.startswith("subset="):
                        paths.append(element[len("subset=") :])
        for prefix in ("--segments=", "--scores="):
            if arg.startswith(prefix):
                paths.append(arg[len(prefix) :])
    return paths


def option_value(args: Sequence[str], name: str) -> str | None:
    """Return the value of ``--name=value`` if present."""
    prefix = f"--{name}="
    for arg in args:
        if arg.startswith(prefix):
            return arg[len(prefix) :]
    return None


def link_inputs(package: str, paths: Sequence[str]) -> None:
    """Symlink package inputs into the task dir under their original relpaths."""
    data_root = os.path.realpath(os.path.join(package, DATA_SUBDIR))
    for rel in paths:
        source = os.path.join(data_root, rel)
        if not os.path.exists(source):
            raise KegLastzError(f"package is missing input file: {DATA_SUBDIR}/{rel}")
        if os.path.lexists(rel):
            continue
        parent = os.path.dirname(rel)
        if parent:
            os.makedirs(parent, exist_ok=True)
        os.symlink(source, rel)


def stderr_is_clean(path: str | None) -> bool:
    """True when LASTZ's stderr file is empty or holds only truncation notices."""
    if path is None:
        return True
    try:
        if os.stat(path, follow_symlinks=False).st_size == 0:
            return True
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not TRUNCATION_RE.match(line) and line != TRUNCATION_MSG:
                    return False
    except OSError:
        return False
    return True


def run_lastz(argv: Sequence[str], command: dict[str, Any]) -> None:
    """Run one LASTZ command honouring its recorded stdin/stdout/stderr."""
    streams = {}
    for name, mode in (("stdin", "r"), ("stdout", "w"), ("stderr", "w")):
        path = command.get(name)
        streams[name] = open(path, mode) if path is not None else None

    try:
        process = subprocess.run(
            list(argv),
            stdin=streams["stdin"],
            stdout=streams["stdout"],
            stderr=streams["stderr"],
        )
    finally:
        for handle in streams.values():
            if handle is not None:
                handle.close()

    if process.returncode not in LASTZ_OK_RETURNCODES:
        raise KegLastzError(
            f"lastz exited {process.returncode}: {shlex.join(argv)}"
        )
    if not stderr_is_clean(command.get("stderr")):
        raise KegLastzError(
            f"lastz reported errors in {command['stderr']}: {shlex.join(argv)}"
        )


def axt_to_psl(
    axt: str,
    reference_sizes: str,
    query_sizes: str,
    output: str,
    axt_to_psl_bin: str = "axtToPsl",
) -> None:
    """Convert one AXT+ file to PSL — same conversion the LASTZ backend uses."""
    argv = [axt_to_psl_bin, axt, reference_sizes, query_sizes, output]
    process = subprocess.run(argv, capture_output=True, text=True)
    if process.returncode != 0:
        raise KegLastzError(f"axtToPsl failed: {process.stderr.strip()}")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    app = argparse.ArgumentParser(description=__doc__)
    app.add_argument("--self-check", action="store_true", help="run internal asserts")
    app.add_argument("--package", help="extracted KegAlign package directory")
    app.add_argument("--segments", help="the partition's .segments filename")
    app.add_argument("--reference-sizes", help="reference chrom.sizes")
    app.add_argument("--query-sizes", help="query chrom.sizes")
    app.add_argument("--output", help="output PSL pathname")
    app.add_argument("--lastz", default="lastz")
    app.add_argument("--axt-to-psl", default="axtToPsl")
    return app.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> None:
    args = parse_args(argv)
    if args.self_check:
        self_check()
        return

    required = ["package", "segments", "reference_sizes", "query_sizes", "output"]
    missing = [f"--{name.replace('_', '-')}" for name in required if not getattr(args, name)]
    if missing:
        raise KegLastzError(f"missing required arguments: {', '.join(missing)}")

    # Resolve before anything else writes relative paths.
    reference_sizes = os.path.realpath(args.reference_sizes)
    query_sizes = os.path.realpath(args.query_sizes)
    output = os.path.realpath(args.output)

    command = load_command(args.package, args.segments)
    link_inputs(args.package, input_paths(command["args"]))

    axt = option_value(command["args"], "output")
    if axt is None:
        raise KegLastzError(f"command has no --output=: {command['args']}")
    fmt = option_value(command["args"], "format")
    if fmt is None or not fmt.startswith("axt"):
        raise KegLastzError(f"expected an axt LASTZ format, got {fmt!r}")

    run_lastz(build_argv(command["args"], args.lastz), command)
    axt_to_psl(axt, reference_sizes, query_sizes, output, args.axt_to_psl)


def self_check() -> None:
    """Assert the command reconstruction matches run_lastz_tarball.py's."""
    args = [
        "--format=axt+",
        "--output=tmp0.block0.r0.plus.split1.axt+",
        "--segments=tmp0.block0.r0.plus.split1.segments",
        "--strand=plus",
        "--gappedthresh=3000",
        "--inner=2000",
        "--ydrop=9400",
        "--scores=data/scores.txt",
        "--target=work/ref.2bit[nameparse=darkspace][multiple][subset=ref_block0.name]",
        "--query=work/query.2bit[nameparse=darkspace][subset=query_block1.name]",
    ]

    argv = build_argv(args)
    assert argv[0] == "lastz", argv
    assert argv[1] == TRACEBACK_ARG, argv
    # target then query, as positionals, ahead of every option
    assert argv[2].startswith("work/ref.2bit["), argv
    assert argv[3].startswith("work/query.2bit["), argv
    assert all(a.startswith("--") for a in argv[4:]), argv
    assert "--target=work/ref.2bit[nameparse=darkspace][multiple][subset=ref_block0.name]" not in argv
    assert "--format=axt+" in argv and "--inner=2000" in argv, argv

    # every referenced input file is discovered, including the subset lists
    # hidden inside the sequence specs
    assert sorted(input_paths(args)) == sorted(
        [
            "work/ref.2bit",
            "ref_block0.name",
            "work/query.2bit",
            "query_block1.name",
            "tmp0.block0.r0.plus.split1.segments",
            "data/scores.txt",
        ]
    ), input_paths(args)

    assert option_value(args, "output") == "tmp0.block0.r0.plus.split1.axt+"
    assert option_value(args, "format") == "axt+"
    assert option_value(args, "nope") is None

    # a command with no scores/subset must still resolve
    bare = ["--format=axt+", "--output=o.axt+", "--segments=s.segments",
            "--target=work/ref.2bit[multiple]", "--query=work/query.2bit"]
    assert sorted(input_paths(bare)) == sorted(
        ["work/ref.2bit", "work/query.2bit", "s.segments"]
    ), input_paths(bare)

    # truncation-only stderr is success; anything else is failure
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        empty = os.path.join(tmp, "empty.err")
        open(empty, "w").close()
        assert stderr_is_clean(empty)
        assert stderr_is_clean(None)

        ok = os.path.join(tmp, "trunc.err")
        with open(ok, "w") as handle:
            handle.write(
                "truncating alignment ending at (123,456);  anchor at (12,34)\n"
            )
            handle.write(TRUNCATION_MSG + "\n")
        assert stderr_is_clean(ok)

        bad = os.path.join(tmp, "bad.err")
        with open(bad, "w") as handle:
            handle.write("FAILURE: out of memory\n")
        assert not stderr_is_clean(bad)

    # a missing / ambiguous partition must be an error, not a silent no-op
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "galaxy"))
        with open(os.path.join(tmp, COMMANDS_JSON), "w") as handle:
            handle.write(json.dumps({"args": ["--segments=a.segments"]}) + "\n")
            handle.write(json.dumps({"args": ["--segments=b.segments"]}) + "\n")
            handle.write(json.dumps({"args": ["--segments=b.segments"]}) + "\n")
        assert load_command(tmp, "a.segments")["args"] == ["--segments=a.segments"]
        for segments in ("missing.segments", "b.segments"):
            try:
                load_command(tmp, segments)
            except KegLastzError:
                pass
            else:
                raise AssertionError(f"expected KegLastzError for {segments}")

    print("run_keg_lastz self-check OK")


if __name__ == "__main__":
    try:
        main()
    except KegLastzError as error:
        sys.exit(f"run_keg_lastz: {error}")
