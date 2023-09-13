"""Do Chain Run."""
import os
import shutil
import subprocess
from parallelization.nextflow_wrapper import NextflowWrapper
from steps_implementations.chain_run_bundle_substep import bundle_chrom_split_psl_files


from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables


def psl_bundle(cat_out_dirname, project_paths, psl_sort_acc, params):
    # 1.1 -> sort
    # TODO: potentially danger part here: can exceed the bash limit for number of arguments
    concatenated_files = [os.path.join(cat_out_dirname, x) for x in os.listdir(cat_out_dirname)]
    file_list_arg = " ".join(concatenated_files)

    sort_cmd = [psl_sort_acc,
                "nohead",
                project_paths.sorted_psl_dir,
                project_paths.psl_sort_temp_dir,
                file_list_arg]
    subprocess.call(sort_cmd)
    shutil.rmtree(project_paths.psl_sort_temp_dir)
    # 1.2 -> bundle chrom split files
    bundle_chrom_split_psl_files(project_paths.sorted_psl_dir,
                                 params.seq_1_len,
                                 project_paths.split_psl_dir,
                                 Constants.BUNDLE_PSL_MAX_BASES)


def make_chains_joblist(project_paths: ProjectPaths,
                        params: PipelineParameters,
                        executables: StepExecutables):
    # Prepare parameters
    seq1_dir = params.seq_1_dir
    seq2_dir = params.seq_2_dir
    # TODO: deal with matrix
    # matrix = params.lastz_q if params.lastz_q else ""
    # matrix = ""
    min_score = params.chain_min_score
    linear_gap = params.chain_linear_gap
    bundle_filenames = os.listdir(project_paths.split_psl_dir)

    cluster_jobs = []
    for bundle_filename in bundle_filenames:
        in_path = os.path.join(project_paths.split_psl_dir, bundle_filename)
        out_path = os.path.join(project_paths.chain_output_dir, f"{bundle_filename}.chain")
        cmd = [executables.axt_chain,
               "-psl",
               "-verbose=0",
               f"-minScore={min_score}",
               f"-linearGap={linear_gap}",
               in_path,
               seq1_dir,
               seq2_dir,
               "stdout",
               "|",
               executables.chain_anti_repeat,
               seq1_dir,
               seq2_dir,
               "stdin",
               out_path]
        cluster_jobs.append(" ".join(cmd))
    return cluster_jobs


def do_chain_run(params: PipelineParameters,
                 project_paths: ProjectPaths,
                 executables: StepExecutables):
    # Part 1: make bundles
    psl_bundle(project_paths.cat_out_dirname, project_paths, executables.psl_sort_acc, params)

    # Part 2: create chains joblist
    chain_jobs = make_chains_joblist(project_paths, params, executables)

    # Part 3: execute cluster jobs
    with open(project_paths.chain_joblist_path, "w") as f:
        f.write("\n".join(chain_jobs))

    nextflow_manager = NextflowWrapper()
    nextflow_manager.execute(project_paths.chain_joblist_path,
                             Constants.NextflowConstants.LASTZ_CONFIG_PATH,
                             project_paths.chain_run_dir,
                             wait=True)
    nextflow_manager.cleanup()
