"""Chain merge step."""
import os
import subprocess
from modules.parameters import PipelineParameters
from constants import Constants


def do_chains_merge(project_dir, params, executables):
    chain_run_dir = os.path.join(project_dir, Constants.TEMP_AXT_CHAIN_DIRNAME)
    chain_out_dir = os.path.join(chain_run_dir, Constants.CHAIN_RUN_OUT_DIRNAME)
    merged_chain_filename = f"{params.target_name}.{params.query_name}.all.chain.gz"
    merged_chain_path = os.path.join(chain_run_dir, merged_chain_filename)

    # Define the find command
    find_cmd = ["find", chain_out_dir, "-name", "*chain"]

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
    with open(merged_chain_path, "wb") as f:
        gzip_process = subprocess.Popen(gzip_cmd, stdin=merge_sort_process.stdout, stdout=f)

    # Close the stdout of merge_sort_process
    merge_sort_process.stdout.close()

    # Wait for gzip to finish
    gzip_process.communicate()
