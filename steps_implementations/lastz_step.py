"""LASTZ step implementation.

Creates a lastz joblist for NxK chunks created at the partitioning step.
Executes these lastz alignment jobs in parallel.
"""
import os
import subprocess
from itertools import product
from modules.make_chains_logging import to_log
from constants import Constants
from modules.common_funcs import read_list_txt_file
from parallelization.nextflow_wrapper import NextflowWrapper


def create_lastz_jobs(project_dir, executables):
    to_log("LASTZ: making jobs")
    lastz_working_dir = os.path.join(project_dir, Constants.TEMP_LASTZ_DIRNAME)
    target_partitions_file = os.path.join(lastz_working_dir, f"{Constants.TARGET_LABEL}_partitions.txt")
    query_partitions_file = os.path.join(lastz_working_dir, f"{Constants.QUERY_LABEL}_partitions.txt")
    target_partitions = read_list_txt_file(target_partitions_file)
    query_partitions = read_list_txt_file(query_partitions_file)

    params_file = os.path.abspath(os.path.join(project_dir, Constants.PARAMS_JSON_FILENAME))
    output_dir = os.path.abspath(os.path.join(project_dir, Constants.TEMP_PSL_DIRNAME))
    os.makedirs(output_dir, exist_ok=True)

    jobs = []

    for num, (target, query) in enumerate(product(target_partitions, query_partitions), 1):
        output_filename = f"{target.split(':')[-2]}_{query.split(':')[-2]}__{num}.psl"
        output_file = os.path.join(
            output_dir,
            output_filename
        )
        lastz_exec = os.path.abspath(executables.lastz_wrapper)
        job = f"{lastz_exec} {target} {query} {params_file} {output_file} --output_format psl "
        jobs.append(job)

    # Now 'jobs' contains all the run_lastz.py commands you need to run
    # You can write these to a file, or execute them directly
    joblist_path = os.path.join(lastz_working_dir, Constants.LASTZ_JOBLIST_FILENAME)
    with open(joblist_path, "w") as f:
        for job in jobs:
            f.write(f"{job}\n")
    to_log(f"LASTZ: saved {len(jobs)} jobs to {joblist_path}")
    return joblist_path


def do_lastz(project_dir, params, executables):
    joblist_path = create_lastz_jobs(project_dir, executables)
    lastz_working_dir = os.path.join(project_dir, Constants.TEMP_LASTZ_DIRNAME)
    nextflow_manager = NextflowWrapper()
    nextflow_manager.execute(joblist_path,
                             Constants.NextflowConstants.LASTZ_CONFIG_PATH,
                             lastz_working_dir,
                             wait=True)
    nextflow_manager.cleanup()
