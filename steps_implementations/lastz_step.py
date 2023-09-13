"""LASTZ step implementation.

Creates a lastz joblist for NxK chunks created at the partitioning step.
Executes these lastz alignment jobs in parallel.
"""
import os
import subprocess
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


def do_lastz(params: PipelineParameters,
             project_paths: ProjectPaths,
             executables: StepExecutables):
    create_lastz_jobs(project_paths, executables)
    nextflow_manager = NextflowWrapper()
    nextflow_manager.execute(project_paths.lastz_joblist,
                             Constants.NextflowConstants.LASTZ_CONFIG_PATH,
                             project_paths.lastz_working_dir,
                             wait=True)
    nextflow_manager.cleanup()
