#!/usr/bin/env python3
"""Make LASTZ chains master script."""
import argparse
import sys
import os
import subprocess
import shutil
from datetime import datetime as dt
from constants import Constants
from modules.project_directory import OutputDirectoryManager
from modules.step_manager import StepManager
from modules.parameters import PipelineParameters
from modules.pipeline_steps import PipelineSteps
from modules.make_chains_logging import setup_logger
from modules.make_chains_logging import to_log
from modules.project_setup_procedures import setup_genome_sequences
from version import __version__

__author__ = "Bogdan Kirilenko, Michael Hiller, Virag Sharma, Ekaterina Osipova"
__maintainer__ = "Bogdan Kirilenko"

SCRIPT_LOCATION = os.path.abspath(os.path.dirname(__file__))


def parse_args():
    app = argparse.ArgumentParser(description=Constants.DESCRIPTION)
    app.add_argument(
        "target_name", help="Target genome identifier, e.g. hg38, human, etc."
    )
    app.add_argument(
        "query_name", help="Query genome identifier, e.g. mm10, mm39, mouse, etc."
    )
    app.add_argument(
        "target_genome", help="Target genome. Accepted formats are: fasta and 2bit."
    )
    app.add_argument(
        "query_genome", help="Query genome. Accepted formats are: fasta and 2bit."
    )
    app.add_argument("--project_dir", "--pd", help="Project directory. By default: pwd")

    app.add_argument(
        "--continue_from_step",
        help="Continue pipeline execution from this step",
        choices=PipelineSteps.ORDER,
        default=None,
    )

    app.add_argument(
        "--force",
        "-f",
        action="store_true",
        dest="force",
        help="Overwrite output directory if exists"
    )

    app.add_argument("--cluster_executor", default="local", help="Nextflow executor parameter")

    # Pipeline parameters group
    pipeline_params = app.add_argument_group('Pipeline Parameters')
    pipeline_params.add_argument("--lastz_y", default=Constants.DEFAULT_LASTZ_Y, type=int)
    pipeline_params.add_argument("--lastz_h", default=Constants.DEFAULT_LASTZ_H, type=int)
    pipeline_params.add_argument("--lastz_l", default=Constants.DEFAULT_LASTZ_L, type=int)
    pipeline_params.add_argument("--lastz_k", default=Constants.DEFAULT_LASTZ_K, type=int)
    pipeline_params.add_argument("--seq1_chunk", default=Constants.DEFAULT_SEQ1_CHUNK, type=int)
    pipeline_params.add_argument("--seq1_lap", default=Constants.DEFAULT_SEQ1_LAP, type=int)
    pipeline_params.add_argument("--seq1_limit", default=Constants.DEFAULT_SEQ1_LIMIT, type=int)
    pipeline_params.add_argument("--seq2_chunk", default=Constants.DEFAULT_SEQ2_CHUNK, type=int)
    pipeline_params.add_argument("--seq2_lap", default=Constants.DEFAULT_SEQ2_LAP, type=int)
    pipeline_params.add_argument("--seq2_limit", default=Constants.DEFAULT_SEQ2_LIMIT, type=int)
    pipeline_params.add_argument("--min_chain_score",
                                 default=Constants.DEFAULT_MIN_CHAIN_SCORE,
                                 type=int)
    # TODO: add "choices" -> must be loose, medium, or smth else
    pipeline_params.add_argument("--chain_linear_gap",
                                 default=Constants.DEFAULT_CHAIN_LINEAR_GAP,
                                 type=str)
    pipeline_params.add_argument("--fill_chain", default=Constants.DEFAULT_FILL_CHAIN_ARG, type=int)
    pipeline_params.add_argument("--fill_unmask", default=Constants.DEFAULT_FILL_UNMASK_ARG, type=int)
    pipeline_params.add_argument("--fill_chain_min_score",
                                 default=Constants.DEFAULT_FILL_CHAIN_MIN_SCORE,
                                 type=int)
    pipeline_params.add_argument("--fill_insert_chain_min_score",
                                 default=Constants.DEFAULT_INSERT_CHAIN_MIN_SCORE,
                                 type=int)
    pipeline_params.add_argument("--fill_gap_max_size_t",
                                 default=Constants.DEFAULT_FILL_GAP_MAX_SIZE_T,
                                 type=int)
    pipeline_params.add_argument("--fill_gap_max_size_q",
                                 default=Constants.DEFAULT_FILL_GAP_MAX_SIZE_Q,
                                 type=int)
    pipeline_params.add_argument("--fill_gap_min_size_t",
                                 default=Constants.DEFAULT_FILL_GAP_MIN_SIZE_T,
                                 type=int)
    pipeline_params.add_argument("--fill_gap_min_size_q",
                                 default=Constants.DEFAULT_FILL_GAP_MIN_SIZE_Q,
                                 type=int)
    pipeline_params.add_argument("--fill_lastz_k", default=Constants.DEFAULT_FILL_LASTZ_K, type=int)
    pipeline_params.add_argument("--fill_lastz_l", default=Constants.DEFAULT_FILL_LASTZ_L, type=int)
    pipeline_params.add_argument("--fill_memory", default=Constants.DEFAULT_FILL_MEMORY, type=int)
    pipeline_params.add_argument("--fill_prepare_memory",
                                 default=Constants.DEFAULT_FILL_PREPARE_MEMORY,
                                 type=int)
    # pipeline_params.add_argument("--chaining_queue", default="medium")
    pipeline_params.add_argument("--chaining_memory", default=Constants.DEFAULT_CHAINING_MEMORY, type=int)
    pipeline_params.add_argument("--clean_chain", default=Constants.DEFAULT_CLEAN_CHAIN_ARG, type=int)
    pipeline_params.add_argument("--chain_clean_memory",
                                 default=Constants.DEFAULT_CHAIN_CLEAN_MEMORY,
                                 type=int)
    pipeline_params.add_argument("--clean_chain_parameters",
                                 default=Constants.DEFAULT_CLEAN_CHAIN_PARAMS)

    if len(sys.argv) < 5:
        app.print_help()
        sys.exit(1)

    args = app.parse_args()
    return args


class StepExecutables:
    def __init__(self):
        self.partition_script = self.__find_script("partitionSequence.pl")
        self.lastz_wrapper = self.__find_script("run_lastz.py")
        self.split_chain_into_random_parts = self.__find_script("split_chain_into_random_parts.pl")
        self.hl_kent_binaries_path = os.path.join(SCRIPT_LOCATION, Constants.KENT_BINARIES_DIRNAME)
        self.fa_to_two_bit = self.__find_binary(Constants.ToolNames.FA_TO_TWO_BIT)
        self.two_bit_to_fa = self.__find_binary(Constants.ToolNames.TWO_BIT_TO_FA)
        self.psl_sort_acc = self.__find_binary(Constants.ToolNames.PSL_SORT_ACC)
        self.axt_chain = self.__find_binary(Constants.ToolNames.AXT_CHAIN)
        self.chain_anti_repeat = self.__find_binary(Constants.ToolNames.CHAIN_ANTI_REPEAT)

    @staticmethod
    def __find_script(script_name):
        rel_path = os.path.join(SCRIPT_LOCATION, "standalone_scripts", script_name)
        abs_path = os.path.abspath(rel_path)
        if not os.path.isfile(abs_path):
            raise ValueError(f"Error! Cannot locate script: {script_name}")
        return abs_path

    def __find_binary(self, binary_name):
        binary_path = shutil.which(binary_name)

        if binary_path is None:
            # Try to find it in the HL_kent_binaries directory
            binary_path = os.path.join(self.hl_kent_binaries_path, binary_name)

            if not os.path.exists(binary_path):
                raise ValueError(
                    f"Error! Cannot locate binary: {binary_name} - not "
                    f"in $PATH and not in {self.hl_kent_binaries_path}"
                )
        return binary_path


def log_version():
    """Get git hash and current branch if possible."""
    cmd_hash = "git rev-parse HEAD"
    cmd_branch = "git rev-parse --abbrev-ref HEAD"
    try:
        git_hash = subprocess.check_output(
            cmd_hash, shell=True, cwd=SCRIPT_LOCATION
        ).decode("utf-8").strip()
        git_branch = subprocess.check_output(
            cmd_branch, shell=True, cwd=SCRIPT_LOCATION
        ).decode("utf-8").strip()
    except subprocess.CalledProcessError:
        git_hash = "unknown"
        git_branch = "unknown"
    version = f"Version {__version__}\nCommit: {git_hash}\nBranch: {git_branch}\n"
    to_log("# Make Lastz Chains #")
    to_log(version)
    return version


def run_pipeline(args):
    # setup project dir, parameters and step manager
    start_time = dt.now()
    project_dir = OutputDirectoryManager(args).project_dir
    step_manager = StepManager(project_dir, args)
    parameters = PipelineParameters(args)
    log_file = os.path.join(project_dir, "run.log")
    setup_logger(log_file)
    log_version()
    to_log(f"Making chains for {args.target_genome} and {args.query_genome} files, saving results to {project_dir}")
    to_log(f"Pipeline started at {start_time}")

    parameters.dump_to_json(project_dir)
    step_executables = StepExecutables()
    # initiate input files
    target_chrom_rename_table = setup_genome_sequences(args.target_genome,
                                                       args.target_name,
                                                       Constants.TARGET_LABEL,
                                                       project_dir,
                                                       step_executables)
    query_chrom_rename_table = setup_genome_sequences(args.query_genome,
                                                      args.query_name,
                                                      Constants.QUERY_LABEL,
                                                      project_dir,
                                                      step_executables)
    # now execute steps
    step_manager.execute_steps(project_dir, parameters, step_executables)

    # check result?
    # TODO: implement sanity checks
    tot_runtime = dt.now() - start_time
    to_log(f"make_lastz_chains completed in {tot_runtime}")


def main():
    args = parse_args()
    run_pipeline(args)


if __name__ == "__main__":
    main()
