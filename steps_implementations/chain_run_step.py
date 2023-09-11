"""Do Chain Run."""
import os
import subprocess
from parallelization.nextflow_wrapper import NextflowWrapper
from constants import Constants


def do_chain_run(project_dir, params, executables):
    # Setup directories
    run_dir = os.path.join(project_dir, Constants.TEMP_AXT_CHAIN_DIRNAME, "run")
    joblist_path = os.path.join(run_dir, "chaining_joblist.txt")
    os.makedirs(run_dir, exist_ok=True)

    # Prepare parameters
    seq1_dir = params.seq_1_dir
    seq2_dir = params.seq_2_dir
    # TODO: deal with matrix
    # matrix = params.lastz_q if params.lastz_q else ""
    matrix = ""
    min_score = params.chain_min_score
    linear_gap = params.chain_linear_gap

    # Prepare output directories and files
    split_psl_dir = os.path.join(run_dir, Constants.SPLIT_PSL_DIRNAME)
    os.makedirs(split_psl_dir, exist_ok=True)
    chain_dir = os.path.join(run_dir, "chain")
    os.makedirs(chain_dir, exist_ok=True)

    # Mocking the bundling of PSL files
    # bundle_psl_for_chaining(input_dir, output_dir, output_file_list, max_bases, gzipped)

    # Mocking the parallel execution
    f = open(joblist_path, "w")

    # Loop through the PSL files and prepare chaining commands
    psl_files = [f for f in os.listdir(split_psl_dir) if f.endswith(".psl")]
    for psl_file in psl_files:
        output_chain_file = os.path.join(chain_dir, f"{psl_file}.chain")

        # Prepare the chaining command as a string
        axt_chain_command = f"{executables.axt_chain} -psl -verbose=0 {matrix} -minScore={min_score} -linearGap={linear_gap} stdin {seq1_dir} {seq2_dir} stdout"

        chain_anti_repeat_command = f"{executables.chain_anti_repeat} {seq1_dir} {seq2_dir} stdin {output_chain_file}"

        # Combine the two commands into a single string using a pipe
        full_command = f"{axt_chain_command} | {chain_anti_repeat_command}"

        f.write(f"{full_command}\n")
    f.close()

    # TODO check joblist validity
    # TODO execute jobs in parallel
