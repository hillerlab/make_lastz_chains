#!/usr/bin/env python3
"""Run one LASTZ alignment and optionally convert its AXT output to PSL."""

import argparse
import json
import logging
import os
import random
import shlex
import shutil
import string
import subprocess
from subprocess import PIPE
from typing import Sequence


__author__ = "Alejandro Gonzales-Irribarren"
__credits__ = ["Bogdan M. Kirilenko, Nil Tianchen Mu"]
__email__ = "alejandrxgzi@gmail.com"
__github__ = "https://github.com/hillerlab/make_lastz_chains"
__version__ = "0.0.2"


LOGGER = logging.getLogger("run_lastz")

BLASTZ_PREFIX = "lastz_"
FORMAT_ARG = "--format=axt+"
ALLOC_ARG = "--traceback=800.0M"

FileSpec = tuple[str, str | None, int | None, int | None]
PipelineParams = dict[str, object]


class LastzProcessError(Exception):
    """Report a failed LASTZ-related subprocess."""


def configure_logging(verbose: bool) -> None:
    """Enable concise stderr diagnostics when verbose logging is requested."""
    logging.basicConfig(format="%(levelname)s %(name)s: %(message)s")
    LOGGER.setLevel(logging.DEBUG if verbose else logging.WARNING)


def _gen_random_string(length: int) -> str:
    """Return a cryptographically strong random uppercase identifier."""
    return "".join(
        random.SystemRandom().choice(string.ascii_uppercase + string.digits)
        for _ in range(length)
    )


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the explicit single-alignment wrapper command-line interface."""
    app = argparse.ArgumentParser()
    app.add_argument(
        "--reference", required=True, help="Reference sequence file or .lst"
    )
    app.add_argument("--query", required=True, help="Query sequence file or .lst")
    app.add_argument(
        "--params_json", required=True, help="Pipeline configuration JSON file"
    )
    app.add_argument("--output", required=True, help="Output file location")
    app.add_argument(
        "--output_format",
        required=True,
        choices=["psl", "axt"],
        help="Output format: axt or psl",
    )
    app.add_argument(
        "--temp_dir",
        help="Optional parent directory for temporary wrapper workspaces",
    )
    app.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Log wrapper decisions and subprocess commands to stderr",
    )
    app.add_argument(
        "--axt_to_psl",
        default="axtToPsl",
        help="Path to axtToPsl if it is not available on PATH",
    )
    app.add_argument(
        "--reference_chrom_dir",
        default=None,
        help="Optional directory of pre-extracted <chrom>.fa files for the reference genome",
    )
    app.add_argument(
        "--query_chrom_dir",
        default=None,
        help="Optional directory of pre-extracted <chrom>.fa files for the query genome",
    )
    return app.parse_args(argv)


def read_json_file(file_path: str) -> PipelineParams:
    """Read and validate a pipeline-parameter JSON object."""
    with open(file_path) as json_file:
        data = json.load(json_file)
    if not isinstance(data, dict):
        raise ValueError(f"Expected a JSON object in {file_path}")
    return data


def require_string_param(params: PipelineParams, key: str) -> str:
    """Return a required string parameter with a clear validation error."""
    value = params.get(key)
    if not isinstance(value, str):
        raise ValueError(f"Pipeline parameter {key!r} must be a string")
    return value


def get_optional_string_param(params: PipelineParams, key: str) -> str | None:
    """Return an optional string parameter with a clear validation error."""
    value = params.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"Pipeline parameter {key!r} must be a string when provided")
    return value


def get_temp_dir(parent_dir: str | None) -> str:
    """Create and return an owned temporary workspace under a parent directory."""
    if parent_dir and not os.path.isdir(parent_dir):
        raise ValueError(f"Temporary parent directory {parent_dir} is not a directory")
    workspace_parent = parent_dir or "."
    workspace_path = os.path.abspath(
        os.path.join(workspace_parent, f"blastz.{_gen_random_string(8)}")
    )
    os.mkdir(workspace_path)
    LOGGER.debug("Created temporary workspace: %s", workspace_path)
    return workspace_path


def define_if_not(params: PipelineParams, key: str, value: object) -> None:
    """Set a default parameter when the current value is absent or false-like."""
    if not params.get(key):
        params[key] = value


def get_blastz_params(params: PipelineParams) -> str:
    """Translate lastz_* pipeline parameters into LASTZ KEY=value options."""
    options = []
    for key, value in params.items():
        if not key.startswith(BLASTZ_PREFIX):
            continue
        lastz_key = key.replace(BLASTZ_PREFIX, "").upper()
        options.append(f"{lastz_key}={value}")
    return " ".join(options)


def parse_file_spec(filename: str) -> FileSpec:
    """Parse a sequence argument into path, chromosome, start, and end fields."""
    if ":" not in filename:
        return filename, None, None, None
    path_bare = filename.split(":", maxsplit=1)[0]
    try:
        _, seq_id, start_end = os.path.basename(filename).split(":")
        start, end = (int(value) for value in start_end.split("-"))
    except ValueError as error:
        raise ValueError(
            f"Malformed sequence argument {filename!r}: expected <path>:<chrom>:<start>-<end>"
        ) from error
    return path_bare, seq_id, start, end


def _seq_arg(path: str, chrom: str | None, start: int | None, end: int | None) -> str:
    """Build one LASTZ sequence argument while preserving existing range semantics.

    The file/sequence selector is valid for .2bit inputs only. Extracted FASTA
    inputs contain one chromosome, so their ranges apply directly to the file.
    LASTZ range indices are 1-based inclusive, hence ``start + 1``.
    """
    if chrom is None or start is None or end is None:
        return f'"{path}[multiple]"'
    if path.endswith(".2bit"):
        return f'"{path}/{chrom}[{start + 1},{end}][multiple]"'
    return f'"{path}[{start + 1},{end}][multiple]"'


def build_lastz_command(
    reference_specs: FileSpec,
    query_specs: FileSpec,
    blastz_options: str,
) -> str:
    """Build the shell command used for one LASTZ invocation."""
    reference_arg = _seq_arg(*reference_specs)
    query_arg = _seq_arg(*query_specs)
    fields = ("lastz", reference_arg, query_arg, blastz_options, ALLOC_ARG, FORMAT_ARG)
    return " ".join(fields)


def call_lastz(command: str) -> str:
    """Run LASTZ and return decoded AXT output."""
    LOGGER.debug("Running LASTZ subprocess: %s", command)
    try:
        return subprocess.check_output(command, shell=True, stderr=PIPE).decode("utf-8")
    except subprocess.CalledProcessError as error:
        error_message = error.stderr.decode("utf-8")
        raise LastzProcessError(
            f"LASTZ command failed with exit code {error.returncode}: {error_message}"
        ) from error


def make_psl_if_needed(
    raw_output: str,
    output_format: str,
    reference_sizes_path: str,
    query_sizes_path: str,
    axt_to_psl: str,
) -> str:
    """Return AXT output unchanged or convert it to PSL."""
    if output_format == "axt":
        return raw_output

    command = [
        axt_to_psl,
        "/dev/stdin",
        reference_sizes_path,
        query_sizes_path,
        "stdout",
    ]
    LOGGER.debug("Running AXT-to-PSL subprocess: %s", shlex.join(command))
    process = subprocess.Popen(command, stdout=PIPE, stderr=PIPE, stdin=PIPE)
    stdout_bytes, stderr_bytes = process.communicate(input=raw_output.encode())
    stdout = stdout_bytes.decode("utf-8")
    stderr = stderr_bytes.decode("utf-8")
    if process.returncode != 0:
        raise LastzProcessError(f"axtToPsl command failed: {stderr}")
    return stdout


def extract_list_to_fasta(list_path: str, tmp_dir: str) -> str:
    """Collapse a multi-entry .lst file into one temporary FASTA file."""
    with open(list_path) as list_file:
        content = [line.rstrip() for line in list_file]

    fasta_path = os.path.join(tmp_dir, f"{_gen_random_string(8)}_collapsed.fa")
    LOGGER.debug("Saving collapsed FASTA to: %s", fasta_path)
    with open(fasta_path, "w") as fasta_file:
        for elem in content:
            try:
                path, chrom = elem.split(":")[:2]
            except ValueError as error:
                raise ValueError(
                    f"Malformed .lst entry {elem!r} in {list_path}: expected <path>:<chrom>"
                ) from error
            LOGGER.debug("Extracting .lst entry: %s", elem)
            tmp_chrom_fa = os.path.join(tmp_dir, f"{_gen_random_string(8)}_chrom.fa")
            command = ["twoBitToFa", f"-seq={chrom}", path, tmp_chrom_fa]
            LOGGER.debug("Running twoBitToFa subprocess: %s", shlex.join(command))
            result = subprocess.run(command, stderr=PIPE)
            if result.returncode != 0:
                raise RuntimeError(f"twoBitToFa failed: {result.stderr.decode()}")
            with open(tmp_chrom_fa) as chrom_fasta_file:
                fasta_file.write(chrom_fasta_file.read())
            os.unlink(tmp_chrom_fa)
    return fasta_path


def parse_seq_arg(arg: str, tmp_dir: str | None) -> str:
    """Resolve a direct sequence argument or collapse a multi-entry .lst file."""
    if not arg.endswith(".lst"):
        LOGGER.debug("Sequence argument is not a .lst file: %s", arg)
        return arg

    LOGGER.debug("Resolving .lst sequence argument: %s", arg)
    with open(arg) as list_file:
        content = [line.rstrip() for line in list_file]
    if len(content) == 1:
        LOGGER.debug(".lst file contains one element: %s", content[0])
        return content[0]
    if tmp_dir is None:
        raise RuntimeError("A temporary workspace is required to collapse a .lst file")
    return extract_list_to_fasta(arg, tmp_dir)


def check_temp_is_needed(reference: str, query: str) -> bool:
    """Return whether either input requires a temporary .lst workspace."""
    return reference.endswith(".lst") or query.endswith(".lst")


def check_if_output_is_non_empty(lastz_output: str) -> bool:
    """Return whether LASTZ output contains a non-comment record."""
    return any(line and not line.startswith("#") for line in lastz_output.splitlines())


def is_2bit_v1(path: str) -> bool:
    """Return whether a .2bit file uses the v1 64-bit layout."""
    with open(path, "rb") as two_bit_file:
        header = two_bit_file.read(8)
    if header[:4] == b"\x43\x27\x41\x1a":
        version = int.from_bytes(header[4:8], "little")
    elif header[:4] == b"\x1a\x41\x27\x43":
        version = int.from_bytes(header[4:8], "big")
    else:
        raise ValueError(f"Not a .2bit file: {path}")
    return version == 1


def extract_chrom_to_fasta(
    two_bit_path: str,
    chrom: str,
    shared_chrom_dir: str | None = None,
) -> str:
    """Return a cached one-chromosome FASTA extracted from a v1 .2bit file."""
    if shared_chrom_dir:
        shared_path = os.path.join(shared_chrom_dir, f"{chrom}.fa")
        if os.path.exists(shared_path):
            LOGGER.debug("Using shared chromosome FASTA cache: %s", shared_path)
            return shared_path
        LOGGER.debug("Shared chromosome FASTA cache miss: %s", shared_path)

    cache_dir = os.path.abspath("./_v1_chrom_cache")
    os.makedirs(cache_dir, exist_ok=True)
    fasta_path = os.path.join(cache_dir, f"{os.path.basename(two_bit_path)}_{chrom}.fa")
    if os.path.exists(fasta_path):
        LOGGER.debug("Using task-local chromosome FASTA cache: %s", fasta_path)
        return fasta_path

    command = ["twoBitToFa", f"-seq={chrom}", two_bit_path, fasta_path]
    LOGGER.debug("Running twoBitToFa subprocess: %s", shlex.join(command))
    result = subprocess.run(command, stderr=PIPE)
    if result.returncode != 0:
        raise RuntimeError(f"twoBitToFa failed: {result.stderr.decode()}")
    return fasta_path


def main(argv: Sequence[str] | None = None) -> None:
    """Run one LASTZ alignment and append any non-empty output."""
    args = parse_args(argv)
    configure_logging(args.verbose)
    LOGGER.debug("Working directory: %s", os.getcwd())
    LOGGER.debug("Pipeline params JSON: %s", os.path.abspath(args.params_json))

    pipeline_params = read_json_file(args.params_json)
    reference_sizes_path = require_string_param(pipeline_params, "seq_1_len")
    query_sizes_path = require_string_param(pipeline_params, "seq_2_len")
    temp_parent = args.temp_dir or get_optional_string_param(
        pipeline_params, "temp_dir"
    )
    tmp_dir: str | None = None

    try:
        if check_temp_is_needed(args.reference, args.query):
            tmp_dir = get_temp_dir(temp_parent)
        LOGGER.debug("Temporary workspace: %s", tmp_dir)

        reference_specs = parse_file_spec(parse_seq_arg(args.reference, tmp_dir))
        query_specs = parse_file_spec(parse_seq_arg(args.query, tmp_dir))
        LOGGER.debug("Reference specs: %s", reference_specs)
        LOGGER.debug("Query specs: %s", query_specs)

        chrom_dirs = {
            "reference": args.reference_chrom_dir,
            "query": args.query_chrom_dir,
        }
        for label, specs in (("reference", reference_specs), ("query", query_specs)):
            path, chrom, start, end = specs
            if chrom is None or not path.endswith(".2bit") or not is_2bit_v1(path):
                continue
            if tmp_dir is None:
                tmp_dir = get_temp_dir(temp_parent)
            fasta_path = extract_chrom_to_fasta(path, chrom, chrom_dirs[label])
            LOGGER.debug("Resolved v1 %s chromosome to FASTA: %s", label, fasta_path)
            resolved_specs = (fasta_path, chrom, start, end)
            if label == "reference":
                reference_specs = resolved_specs
            else:
                query_specs = resolved_specs

        define_if_not(pipeline_params, "lastz_h", 2000)
        blastz_options = get_blastz_params(pipeline_params)
        LOGGER.debug("LASTZ options: %s", blastz_options)
        lastz_output = call_lastz(
            build_lastz_command(reference_specs, query_specs, blastz_options)
        )

        if check_if_output_is_non_empty(lastz_output):
            output_to_save = make_psl_if_needed(
                lastz_output,
                args.output_format,
                reference_sizes_path,
                query_sizes_path,
                args.axt_to_psl,
            )
            LOGGER.debug("Appending alignment output to: %s", args.output)
            with open(args.output, "a") as output_file:
                output_file.write(output_to_save)
        else:
            LOGGER.debug("LASTZ output contains no alignment records; no file written")
    finally:
        if tmp_dir and os.path.isdir(tmp_dir):
            LOGGER.debug("Removing temporary workspace: %s", tmp_dir)
            shutil.rmtree(tmp_dir)


if __name__ == "__main__":
    main()
