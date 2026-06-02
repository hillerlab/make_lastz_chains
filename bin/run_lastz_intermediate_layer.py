#!/usr/bin/env python3
"""Expand LASTZ BULK partitions and invoke the single-alignment wrapper."""

import argparse
import json
import logging
import os
import shlex
import subprocess
from itertools import product
from typing import Sequence

LOGGER = logging.getLogger("run_lastz_intermediate_layer")

__author__ = "Alejandro Gonzales-Irribarren"
__credits__ = ["Bogdan M. Kirilenko, Nil Tianchen Mu"]
__email__ = "alejandrxgzi@gmail.com"
__github__ = "https://github.com/hillerlab/make_lastz_chains"
__version__ = "0.0.2"

PipelineParams = dict[str, object]


def configure_logging(verbose: bool) -> None:
    """Enable concise stderr diagnostics when verbose logging is requested."""
    logging.basicConfig(format="%(levelname)s %(name)s: %(message)s")
    LOGGER.setLevel(logging.DEBUG if verbose else logging.WARNING)


def read_chrom_sizes(chrom_sizes_path: str) -> dict[str, int]:
    """Read chromosome lengths from a tab-separated chrom.sizes file."""
    chrom_sizes: dict[str, int] = {}
    with open(chrom_sizes_path) as chrom_sizes_file:
        for line_number, line in enumerate(chrom_sizes_file, start=1):
            line_data = line.rstrip().split("\t")
            if len(line_data) != 2:
                raise ValueError(
                    f"Malformed chrom.sizes row {line_number} in {chrom_sizes_path}: "
                    f"expected 2 tab-separated fields, got {len(line_data)}"
                )
            chrom, size = line_data
            try:
                chrom_sizes[chrom] = int(size)
            except ValueError as error:
                raise ValueError(
                    f"Malformed chromosome size on row {line_number} in "
                    f"{chrom_sizes_path}: {size!r}"
                ) from error
    return chrom_sizes


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


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the explicit intermediate-wrapper command-line interface."""
    app = argparse.ArgumentParser()
    app.add_argument(
        "--reference",
        required=True,
        help="Reference: single sequence file or BULK partition",
    )
    app.add_argument(
        "--query", required=True, help="Query: single sequence file or BULK partition"
    )
    app.add_argument(
        "--params_json", required=True, help="Pipeline configuration JSON file"
    )
    app.add_argument("--output", required=True, help="Output file location")
    app.add_argument(
        "--run_lastz_script", required=True, help="Path to the run_lastz.py script"
    )
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
        help="Log expanded partitions and subprocess commands to stderr",
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


def get_intervals_list(to_align_arg: str, chrom_sizes: dict[str, int]) -> list[str]:
    """Expand a BULK partition into ranged chromosome arguments."""
    if not to_align_arg.startswith("BULK"):
        return [to_align_arg]

    arg_parts = to_align_arg.split(":")
    if len(arg_parts) < 3:
        raise ValueError(
            f"Malformed BULK partition {to_align_arg!r}: expected BULK name, .2bit path, "
            "and at least one chromosome"
        )

    two_bit_path = arg_parts[1]
    intervals: list[str] = []
    for chrom in arg_parts[2:]:
        try:
            end = chrom_sizes[chrom]
        except KeyError as error:
            raise ValueError(
                f"Chromosome {chrom!r} from BULK partition {to_align_arg!r} "
                "is missing from chrom.sizes"
            ) from error
        intervals.append(f"{two_bit_path}:{chrom}:0-{end}")
    return intervals


def build_lastz_command(
    args: argparse.Namespace,
    reference_arg: str,
    query_arg: str,
    params_json_path: str,
) -> list[str]:
    """Build one run_lastz.py subprocess command."""
    command = [
        args.run_lastz_script,
        "--reference",
        reference_arg,
        "--query",
        query_arg,
        "--params_json",
        params_json_path,
        "--output",
        args.output,
        "--output_format",
        args.output_format,
        "--axt_to_psl",
        args.axt_to_psl,
    ]
    if args.temp_dir:
        command.extend(["--temp_dir", args.temp_dir])
    if args.reference_chrom_dir:
        command.extend(["--reference_chrom_dir", args.reference_chrom_dir])
    if args.query_chrom_dir:
        command.extend(["--query_chrom_dir", args.query_chrom_dir])
    if args.verbose:
        command.append("--verbose")
    return command


def run_lastz_command(command: list[str]) -> None:
    """Run one child wrapper and fail immediately if it exits non-zero."""
    LOGGER.debug("Running subprocess: %s", shlex.join(command))
    try:
        subprocess.run(command, check=True)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            f"run_lastz.py subprocess failed with exit code {error.returncode}: "
            f"{shlex.join(command)}"
        ) from error


def main(argv: Sequence[str] | None = None) -> None:
    """Expand input partitions and run every reference-query combination."""
    args = parse_args(argv)
    configure_logging(args.verbose)
    params_json_path = os.path.abspath(args.params_json)
    LOGGER.debug("Working directory: %s", os.getcwd())
    LOGGER.debug("Pipeline params JSON: %s", params_json_path)

    pipeline_params = read_json_file(params_json_path)
    reference_chrom_sizes = read_chrom_sizes(
        require_string_param(pipeline_params, "seq_1_len")
    )
    query_chrom_sizes = read_chrom_sizes(
        require_string_param(pipeline_params, "seq_2_len")
    )
    reference_coordinates = get_intervals_list(args.reference, reference_chrom_sizes)
    query_coordinates = get_intervals_list(args.query, query_chrom_sizes)
    LOGGER.debug(
        "Expanded partitions: %d reference interval(s) x %d query interval(s)",
        len(reference_coordinates),
        len(query_coordinates),
    )

    for reference_arg, query_arg in product(reference_coordinates, query_coordinates):
        command = build_lastz_command(args, reference_arg, query_arg, params_json_path)
        run_lastz_command(command)


if __name__ == "__main__":
    main()
