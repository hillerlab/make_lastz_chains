"""Regression tests for the LASTZ wrapper scripts."""

import io
import json
import logging
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager, redirect_stderr
from pathlib import Path
from typing import Iterator
from unittest import mock

BIN_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BIN_DIR))

import run_lastz  # noqa: E402
import run_lastz_intermediate_layer as intermediate  # noqa: E402


@contextmanager
def changed_directory(path: Path) -> Iterator[None]:
    """Temporarily change the current working directory."""
    previous_directory = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous_directory)


def write_pipeline_inputs(directory: Path) -> Path:
    """Write minimal chromosome-size and parameter files for wrapper tests."""
    (directory / "reference.chrom.sizes").write_text("ref_a\t10\nref_b\t20\n")
    (directory / "query.chrom.sizes").write_text("query_a\t30\nquery_b\t40\n")
    params_path = directory / "params.json"
    params_path.write_text(
        json.dumps(
            {
                "seq_1_len": "reference.chrom.sizes",
                "seq_2_len": "query.chrom.sizes",
                "lastz_k": 2400,
            }
        )
    )
    return params_path


class IntermediateLayerTests(unittest.TestCase):
    """Cover BULK expansion and child-wrapper execution."""

    def test_expands_regular_and_bulk_arguments(self) -> None:
        """Expand BULK partitions without changing regular arguments."""
        self.assertEqual(
            intermediate.get_intervals_list("reference.2bit:chr1:0-10", {}),
            ["reference.2bit:chr1:0-10"],
        )
        self.assertEqual(
            intermediate.get_intervals_list(
                "BULK_1:reference.2bit:ref_a:ref_b",
                {"ref_a": 10, "ref_b": 20},
            ),
            ["reference.2bit:ref_a:0-10", "reference.2bit:ref_b:0-20"],
        )

    def test_reports_missing_bulk_chromosome(self) -> None:
        """Reject BULK entries that are absent from chrom.sizes."""
        with self.assertRaisesRegex(ValueError, "missing from chrom.sizes"):
            intermediate.get_intervals_list("BULK_1:reference.2bit:missing", {})

    def test_reports_malformed_chrom_sizes_rows(self) -> None:
        """Reject malformed chromosome-size rows with file context."""
        with tempfile.TemporaryDirectory() as temp_dir:
            sizes_path = Path(temp_dir) / "bad.chrom.sizes"
            sizes_path.write_text("chr1 10\n")
            with self.assertRaisesRegex(ValueError, "expected 2 tab-separated fields"):
                intermediate.read_chrom_sizes(str(sizes_path))

    def test_forwards_absolute_params_and_logs_bulk_commands(self) -> None:
        """Forward absolute params paths and log every expanded subprocess."""
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            params_path = write_pipeline_inputs(directory)
            log_output = io.StringIO()
            handler = logging.StreamHandler(log_output)
            intermediate.LOGGER.addHandler(handler)
            try:
                with (
                    changed_directory(directory),
                    mock.patch.object(intermediate.subprocess, "run") as run,
                ):
                    intermediate.main(
                        [
                            "--reference",
                            "BULK_1:reference.2bit:ref_a:ref_b",
                            "--query",
                            "BULK_2:query.2bit:query_a:query_b",
                            "--params_json",
                            params_path.name,
                            "--output",
                            "out.psl",
                            "--run_lastz_script",
                            "run_lastz.py",
                            "--output_format",
                            "psl",
                            "--reference_chrom_dir",
                            "reference_chroms",
                            "--query_chrom_dir",
                            "query_chroms",
                            "--verbose",
                        ]
                    )
            finally:
                intermediate.LOGGER.removeHandler(handler)

            self.assertEqual(run.call_count, 4)
            for call in run.call_args_list:
                command = call.args[0]
                self.assertEqual(call.kwargs, {"check": True})
                params_index = command.index("--params_json") + 1
                self.assertEqual(command[params_index], str(params_path.resolve()))
                self.assertIn("--reference_chrom_dir", command)
                self.assertIn("--query_chrom_dir", command)
                self.assertIn("--verbose", command)

            logs = log_output.getvalue()
            self.assertIn(
                "Expanded partitions: 2 reference interval(s) x 2 query interval(s)",
                logs,
            )
            self.assertEqual(logs.count("Running subprocess:"), 4)

    def test_does_not_log_commands_without_verbose(self) -> None:
        """Suppress subprocess diagnostics unless --verbose is passed."""
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            params_path = write_pipeline_inputs(directory)
            log_output = io.StringIO()
            handler = logging.StreamHandler(log_output)
            intermediate.LOGGER.addHandler(handler)
            try:
                with (
                    changed_directory(directory),
                    mock.patch.object(intermediate.subprocess, "run"),
                ):
                    intermediate.main(
                        [
                            "--reference",
                            "reference.2bit:ref_a:0-10",
                            "--query",
                            "query.2bit:query_a:0-30",
                            "--params_json",
                            params_path.name,
                            "--output",
                            "out.psl",
                            "--run_lastz_script",
                            "run_lastz.py",
                            "--output_format",
                            "psl",
                        ]
                    )
            finally:
                intermediate.LOGGER.removeHandler(handler)
            self.assertEqual(log_output.getvalue(), "")

    def test_propagates_child_failure(self) -> None:
        """Abort when a child run_lastz.py process exits non-zero."""
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            params_path = write_pipeline_inputs(directory)
            failure = subprocess.CalledProcessError(7, ["run_lastz.py"])
            with (
                changed_directory(directory),
                mock.patch.object(intermediate.subprocess, "run", side_effect=failure),
            ):
                with self.assertRaisesRegex(RuntimeError, "exit code 7"):
                    intermediate.main(
                        [
                            "--reference",
                            "reference.2bit:ref_a:0-10",
                            "--query",
                            "query.2bit:query_a:0-30",
                            "--params_json",
                            params_path.name,
                            "--output",
                            "out.psl",
                            "--run_lastz_script",
                            "run_lastz.py",
                            "--output_format",
                            "psl",
                        ]
                    )

    def test_rejects_positional_interface(self) -> None:
        """Reject the historical positional command-line interface."""
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            intermediate.parse_args(
                ["reference", "query", "params", "output", "script"]
            )


class RunLastzTests(unittest.TestCase):
    """Cover single-alignment wrapper helpers and cleanup."""

    def test_builds_existing_sequence_argument_forms(self) -> None:
        """Preserve ranged and whole-file LASTZ argument construction."""
        self.assertEqual(
            run_lastz._seq_arg("ref.fa", None, None, None), '"ref.fa[multiple]"'
        )
        self.assertEqual(
            run_lastz._seq_arg("ref.2bit", "chr1", 0, 10),
            '"ref.2bit/chr1[1,10][multiple]"',
        )
        self.assertEqual(
            run_lastz._seq_arg("ref.fa", "chr1", 0, 10),
            '"ref.fa[1,10][multiple]"',
        )

    def test_reports_malformed_sequence_spec(self) -> None:
        """Reject malformed ranged sequence arguments with context."""
        with self.assertRaisesRegex(ValueError, "Malformed sequence argument"):
            run_lastz.parse_file_spec("reference.2bit:chr1:not-a-range")

    def test_removes_owned_temp_workspace_but_preserves_parent(self) -> None:
        """Delete generated workspaces without deleting a caller-owned parent."""
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            temp_parent = directory / "temp_parent"
            temp_parent.mkdir()
            sentinel = temp_parent / "keep.txt"
            sentinel.write_text("keep")
            (directory / "reference.lst").write_text("reference.fa\n")
            params_path = write_pipeline_inputs(directory)

            with (
                changed_directory(directory),
                mock.patch.object(run_lastz, "call_lastz", return_value=""),
            ):
                run_lastz.main(
                    [
                        "--reference",
                        "reference.lst",
                        "--query",
                        "query.fa",
                        "--params_json",
                        params_path.name,
                        "--output",
                        "out.axt",
                        "--output_format",
                        "axt",
                        "--temp_dir",
                        str(temp_parent),
                    ]
                )

            self.assertTrue(sentinel.exists())
            self.assertEqual(list(temp_parent.iterdir()), [sentinel])

    def test_rejects_positional_interface(self) -> None:
        """Reject the historical positional command-line interface."""
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run_lastz.parse_args(["reference", "query", "params", "output"])


if __name__ == "__main__":
    unittest.main()
