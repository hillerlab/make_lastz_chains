"""LASTZ step implementation.

Creates a lastz joblist for NxK chunks created at the partitioning step.
Executes these lastz alignment jobs in parallel.
"""
import os
from itertools import product
from modules.common_funcs import read_list_txt_file
from modules.make_chains_logging import to_log
from parallelization.nextflow_wrapper import NextflowWrapper

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables


def create_lastz_jobs(project_paths: ProjectPaths, executables: StepExecutables):
    to_log("LASTZ: making jobs")
    target_partitions = read_list_txt_file(project_paths.reference_partitions)
    query_partitions = read_list_txt_file(project_paths.query_partitions)
    jobs = []

    for num, (target, query) in enumerate(product(target_partitions, query_partitions), 1):
        output_filename = f"{target.split(':')[-2]}_{query.split(':')[-2]}__{num}.psl"
        output_file = os.path.join(
            project_paths.lastz_output_dir,
            output_filename
        )
        lastz_exec = os.path.abspath(executables.lastz_wrapper)
        job = f"{lastz_exec} {target} {query} {project_paths.project_params_dump} {output_file} --output_format psl "
        jobs.append(job)

    # Now 'jobs' contains all the run_lastz.py commands you need to run
    # You can write these to a file, or execute them directly
    with open(project_paths.lastz_joblist, "w") as f:
        for job in jobs:
            f.write(f"{job}\n")
    to_log(f"LASTZ: saved {len(jobs)} jobs to {project_paths.lastz_joblist}")


def check_results_completeness(project_paths: ProjectPaths):
    lastz_output_filenames = os.listdir(project_paths.lastz_output_dir)
    lastz_output_files = [os.path.join(project_paths.lastz_output_dir, x) for x in lastz_output_filenames]
    results_num = len(lastz_output_filenames)
    to_log(f"Found {results_num} output files from the LASTZ step")
    to_log("Please note that lastz_step.py does not produce output in case LASTZ could not find any alignment")

    if results_num == 0:
        err_msg = "Error! Lastz results are absent."
        raise ValueError(err_msg)
    # other more sophisticated checks?


def do_lastz(params: PipelineParameters,
             project_paths: ProjectPaths,
             executables: StepExecutables):
    create_lastz_jobs(project_paths, executables)
    nextflow_manager = NextflowWrapper()
    nextflow_manager.execute(project_paths.lastz_joblist,
                             Constants.NextflowConstants.LASTZ_CONFIG_PATH,
                             project_paths.lastz_working_dir,
                             wait=True,
                             label="lastz")
    nextflow_manager.check_failed()
    nextflow_manager.cleanup()
    check_results_completeness(project_paths)
