"""Chain merge step."""
import os
import subprocess

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables


def do_chains_merge(params: PipelineParameters,
                    project_paths: ProjectPaths,
                    executables: StepExecutables):
    # Define the find command
    find_cmd = ["find", project_paths.chain_output_dir, "-name", "*chain"]

    # Define the chain_merge_sort command
    merge_sort_cmd = [executables.chain_merge_sort, "-inputList=stdin"]

    # Define the gzip command
    gzip_cmd = ["gzip", "-c"]

    # Execute the find command and capture its output
    find_process = subprocess.Popen(find_cmd, stdout=subprocess.PIPE)

    # Pipe the output of find to chain_merge_sort
    merge_sort_process = subprocess.Popen(merge_sort_cmd, stdin=find_process.stdout, stdout=subprocess.PIPE)

    # Close the stdout of find_process
    find_process.stdout.close()

    # Pipe the output of chain_merge_sort to gzip
    with open(project_paths.merged_chain, "wb") as f:
        gzip_process = subprocess.Popen(gzip_cmd, stdin=merge_sort_process.stdout, stdout=f)

    # Close the stdout of merge_sort_process
    merge_sort_process.stdout.close()

    # Wait for gzip to finish
    gzip_process.communicate()
