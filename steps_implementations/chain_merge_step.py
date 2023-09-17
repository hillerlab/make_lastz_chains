"""Chain merge step."""
import subprocess

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.make_chains_logging import to_log
from modules.error_classes import PipelineSubprocessError
from modules.common import check_expected_file


def do_chains_merge(params: PipelineParameters,
                    project_paths: ProjectPaths,
                    executables: StepExecutables):
    # Define the find command
    find_cmd = ["find", project_paths.chain_output_dir, "-name", "*chain"]

    # Define the chain_merge_sort command
    merge_sort_cmd = [executables.chain_merge_sort,
                      "-inputList=stdin",
                      f"-tempDir={project_paths.kent_temp_dir}"]

    # Define the gzip command
    gzip_cmd = ["gzip", "-c"]

    to_log("Executing the following sequence of piped commands:")
    to_log(find_cmd)
    to_log(merge_sort_cmd)
    to_log(gzip_cmd)

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

    # Wait for processes to complete and check for errors
    find_exit_code = find_process.wait()
    if find_exit_code != 0:
        raise PipelineSubprocessError(f"find_process failed with exit code {find_exit_code}")

    merge_sort_exit_code = merge_sort_process.wait()
    if merge_sort_exit_code != 0:
        raise PipelineSubprocessError(f"merge_sort_process failed with exit code {merge_sort_exit_code}")

    gzip_exit_code = gzip_process.wait()
    if gzip_exit_code != 0:
        raise PipelineSubprocessError(f"gzip_process failed with exit code {gzip_exit_code}")

    check_expected_file(project_paths.merged_chain, "merge_chain")
    to_log(f"Saved merged results to: {project_paths.merged_chain}")
