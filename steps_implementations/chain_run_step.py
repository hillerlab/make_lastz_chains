"""Do Chain Run."""
import os
import shutil
import subprocess
from parallelization.nextflow_wrapper import NextflowWrapper
from constants import Constants
from steps_implementations.chain_run_bundle_substep import bundle_chrom_split_psl_files


def do_chain_run(project_dir, params, executables):
    # Setup directories
    cat_out_dirname = os.path.join(project_dir, Constants.TEMP_CAT_DIRNAME)
    chain_run_dir = os.path.join(project_dir, Constants.TEMP_AXT_CHAIN_DIRNAME)
    os.makedirs(chain_run_dir, exist_ok=True)

    # TODO: proper decomposition
    # first step -> bundles
    # 1 input dirname for bundle

    # mock_out_file = os.path.join(chain_run_dir, "mock")  # for compatibility: like pstParts.lst
    psl_sort_temp_dir = os.path.join(chain_run_dir, "psl_sort_temp_dir")
    os.makedirs(psl_sort_temp_dir, exist_ok=True)

    max_bases = Constants.BUNDLE_PSL_MAX_BASES

    # 1.1 -> sort
    concatenated_files = [os.path.join(cat_out_dirname, x) for x in os.listdir(cat_out_dirname)]
    file_list_arg = " ".join(concatenated_files)
    sorted_psl_dir = os.path.join(chain_run_dir, "sorted_psl")
    os.makedirs(sorted_psl_dir, exist_ok=True)
    sort_cmd = [executables.psl_sort_acc, "nohead", sorted_psl_dir, psl_sort_temp_dir, file_list_arg]
    subprocess.call(sort_cmd)
    shutil.rmtree(psl_sort_temp_dir)

    # 1.2 -> bundle chrom split files
    split_psl_dir = os.path.join(chain_run_dir, "split_psl")
    os.makedirs(split_psl_dir, exist_ok=True)
    bundle_chrom_split_psl_files(sorted_psl_dir, params.seq_1_len, split_psl_dir, max_bases)

    # Part 2: create chains joblist
    # Prepare parameters
    seq1_dir = params.seq_1_dir
    seq2_dir = params.seq_2_dir
    # TODO: deal with matrix
    # matrix = params.lastz_q if params.lastz_q else ""
    matrix = ""
    min_score = params.chain_min_score
    linear_gap = params.chain_linear_gap
    # Prepare output directories and files
    chain_out_dir = os.path.join(chain_run_dir, "chain")
    os.makedirs(chain_out_dir, exist_ok=True)

    # Part 3: execute cluster jobs
    # ...

    # Mocking the bundling of PSL files
    # bundle_psl_for_chaining(input_dir, output_dir, output_file_list, max_bases, gzipped)
    # print(bundled_output_dir)
    #
    # return
    # Mocking the parallel execution
    # f = open(joblist_path, "w")
    #
    # # Loop through the PSL files and prepare chaining commands
    # psl_files = [f for f in os.listdir(split_psl_dir) if f.endswith(".psl")]
    # for psl_file in psl_files:
    #     output_chain_file = os.path.join(chain_dir, f"{psl_file}.chain")
    #
    #     # Prepare the chaining command as a string
    #     axt_chain_command = f"{executables.axt_chain} -psl -verbose=0 {matrix} -minScore={min_score} -linearGap={linear_gap} stdin {seq1_dir} {seq2_dir} stdout"
    #
    #     chain_anti_repeat_command = f"{executables.chain_anti_repeat} {seq1_dir} {seq2_dir} stdin {output_chain_file}"
    #
    #     # Combine the two commands into a single string using a pipe
    #     full_command = f"{axt_chain_command} | {chain_anti_repeat_command}"
    #
    #     f.write(f"{full_command}\n")
    # f.close()
    # TODO check joblist validity
    # TODO execute jobs in parallel
