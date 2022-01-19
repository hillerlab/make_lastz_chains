#!/usr/bin/env python3
"""Execute jobs in parallel.

Suited to replace para in Hillerlab workflows.
Command line arguments match para script for compatibility.
"""
import argparse
import sys
from math import ceil

from py_nf.py_nf import Nextflow
from py_nf.utils import paths_to_abspaths_in_joblist

__author__ = "Bogdan Kirilenko"


def parse_args():
    """Argument parser"""
    app = argparse.ArgumentParser()
    app.add_argument("project_name", help="Project name")
    app.add_argument("joblist", help="Path to txt file with jobs.")
    app.add_argument(
        "--queue",
        "-q",
        help="Queue arument (see para documentation)",
        default="short",
        type=str,
    )
    app.add_argument(
        "--memoryMb",
        help="memoryMb para parameter (see para documentation)",
        default=10000,
        type=int,
    )
    app.add_argument(
        "--numCores",
        help="numCores para parameter (see para documentation)",
        default=1,
        type=int,
    )
    app.add_argument(
        "--maxNumResubmission",
        default=3,
        help="maxNumResubmission para argument (see para documentation)",
        type=int,
    )
    app.add_argument(
        "--executor",
        "-e",
        default="local",
        help="Nextflow executor. On a slurm cluster, please use "
        "slurm. local executor is default",
    )

    if len(sys.argv) < 3:
        app.print_help()
        sys.exit(0)

    args = app.parse_args()
    return args


def read_joblist(joblist_file):
    """Read joblist, we need a list of commands."""
    with open(joblist_file, "r") as f:
        jobs_no_abs_paths = [x.rstrip() for x in f.readlines()]
    if len(jobs_no_abs_paths) == 0:
        sys.stderr.write(f"Error! {joblist_file} is empty, abort.")
        sys.exit(1)
    abs_path_joblist = paths_to_abspaths_in_joblist(jobs_no_abs_paths)
    return abs_path_joblist


def convert_memorymb_param(mem_arg):
    """Convert memoryMb parameter to num of GB."""
    if mem_arg is None:
        return 10, "GB"
    num_gb = ceil(mem_arg / 1000)
    return num_gb, "GB"


def convert_queue_param(time_arg):
    """Convert -queue param to hours."""
    if time_arg == "short":
        return 1
    elif time_arg == "shortmed":
        return 3
    elif time_arg == "medium":
        return 8
    elif time_arg == "day":
        return 24
    elif time_arg == "threedays":
        return 72
    else:
        sys.stderr.write(f"Error! Invalid queue parameter {time_arg}, abort\n")


def main():
    """Entry point."""
    args = parse_args()
    joblist = read_joblist(args.joblist)
    mem_arg, mem_unit_arg = convert_memorymb_param(args.memoryMb)
    hours = convert_queue_param(args.queue)

    nf = Nextflow(
        executor=args.executor,
        project_name=args.project_name,
        max_retries=args.maxNumResubmission,
        memory=mem_arg,
        memory_units=mem_unit_arg,
        time=hours,
        time_units="h",
        cpus=args.numCores,
        queue_size=1000,
        switch_to_local=True,
        retry_increase_mem=True,
        retry_increase_time=True,
        executor_queuesize=2500
    )
    # execute this joblist using Nextflow
    status = nf.execute(joblist)

    # look at return status, there are 2 cases: either 0 or something else
    if status == 0:
        # 0 means that Nextflow pipeline was executed without errors
        # enjoy your results
        pass
    else:
        # sadly, the pipeline failed
        # py_nf doesn't terminate the program in this case to let user
        # to do some cleanup, for example
        # please read nextflow output messages and logs to figure out
        # what exactly happened
        # do_some_cleanup()
        exit(1)


if __name__ == "__main__":
    main()
