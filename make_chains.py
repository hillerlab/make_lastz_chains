#!/usr/bin/env python3
"""Make LASTZ chains master script."""
import argparse
import shutil
import sys
import os
import subprocess
from datetime import datetime as dt
from constants import Constants
from modules.step_executables import StepExecutables
from modules.project_paths import ProjectPaths
from modules.project_directory import OutputDirectoryManager
from modules.step_manager import StepManager
from modules.parameters import PipelineParameters
from modules.pipeline_steps import PipelineSteps
from modules.make_chains_logging import setup_logger
from modules.make_chains_logging import to_log
from modules.project_setup_procedures import setup_genome_sequences
from version import __version__

__author__ = "Bogdan M. Kirilenko, Michael Hiller, Virag Sharma, Ekaterina Osipova"
__maintainer__ = "Bogdan M. Kirilenko"

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
        "--cfs",
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
    app.add_argument("--cluster_queue",
                     default="batch",
                     help="Queue/Partition label to run cluster jobs")
    app.add_argument("--keep_temp",
                     "--kt",
                     dest="keep_temp",
                     action="store_true",
                     help="Do not remove temp files")
    app.add_argument("--params_from_file",
                     default=None,
                     help="Read parameters from a specified config file")
    # Pipeline parameters group
    pipeline_params = app.add_argument_group('Pipeline Parameters')
    pipeline_params.add_argument("--skip_fill_chain", dest="skip_fill_chains", action="store_true")
    pipeline_params.add_argument("--skip_fill_unmask", dest="skip_fill_unmask", action="store_true")
    pipeline_params.add_argument("--skip_clean_chain", dest="skip_clean_chain", action="store_true")

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
    pipeline_params.add_argument("--chain_linear_gap",
                                 default=Constants.DEFAULT_CHAIN_LINEAR_GAP,
                                 choices=["loose, medium"],
                                 type=str)
    pipeline_params.add_argument("--num_fill_jobs", default=Constants.DEFAULT_NUM_FILL_JOBS, type=int)
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
    pipeline_params.add_argument("--chaining_memory",
                                 default=Constants.DEFAULT_CHAINING_MEMORY,
                                 type=int)
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


def save_final_chain(parameters: PipelineParameters, project_paths: ProjectPaths):
    # get final result chain
    if parameters.fill_chain is True:
        last_chain_file = project_paths.filled_chain
        to_log(f"Chains were filled, using {last_chain_file} as the last output file.")
    else:
        last_chain_file = project_paths.merged_chain
        to_log(f"Chains were NOT filled, using {last_chain_file} as the last output file.")
    if not os.path.isfile(last_chain_file):
        raise ValueError(
            f"Critical! Output chain file {last_chain_file} is absent!"
            f"Please check the logs, probably one of the pipeline steps failed."
        )
    # save it to the root project dir
    shutil.move(last_chain_file, project_paths.final_chain)
    to_log(f"Saved final chains file to {project_paths.final_chain}")


def cleanup(parameters: PipelineParameters, project_paths: ProjectPaths):
    """Perform the cleanup."""
    if parameters.keep_temp:
        return  # cleanup is not necessary
    dirs_to_del = [
        project_paths.chain_run_dir,
        project_paths.cat_out_dirname,
        project_paths.lastz_output_dir,
        project_paths.lastz_working_dir,
        project_paths.fill_chain_run_dir
    ]
    to_log("Cleaning up the following directories")
    for dirname in dirs_to_del:
        to_log(f"x {dirname}")
        shutil.rmtree(dirname)

    # remove individual temp files
    os.remove(project_paths.reference_genome)
    os.remove(project_paths.query_genome)
    os.remove(project_paths.reference_partitions)
    os.remove(project_paths.query_partitions)
    os.remove(project_paths.ref_chrom_sizes)
    os.remove(project_paths.query_chrom_sizes)


def run_pipeline(args):
    # setup project dir, parameters and step manager
    start_time = dt.now()
    # TODO: class to hold paths within the project
    step_executables = StepExecutables(SCRIPT_LOCATION)
    project_dir = OutputDirectoryManager(args).project_dir
    parameters = PipelineParameters(args)
    project_paths = ProjectPaths(project_dir, SCRIPT_LOCATION, parameters)
    step_manager = StepManager(project_paths, args)

    setup_logger(project_paths.log_file)
    log_version()
    to_log(f"Making chains for {args.target_genome} and {args.query_genome} files, saving results to {project_dir}")
    to_log(f"Pipeline started at {start_time}")

    parameters.dump_to_json(project_dir)

    # initiate input files
    setup_genome_sequences(args.target_genome,
                           args.target_name,
                           Constants.TARGET_LABEL,
                           project_paths,
                           step_executables)
    setup_genome_sequences(args.query_genome,
                           args.query_name,
                           Constants.QUERY_LABEL,
                           project_paths,
                           step_executables)

    # now execute steps
    step_manager.execute_steps(parameters, step_executables, project_paths)
    # check result?
    save_final_chain(parameters, project_paths)
    cleanup(parameters, project_paths)
    tot_runtime = dt.now() - start_time
    # TODO: skip chains with negative scores or < min_score
    to_log(f"make_lastz_chains run done in {tot_runtime}")


def main():
    args = parse_args()
    run_pipeline(args)


if __name__ == "__main__":
    main()
