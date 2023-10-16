"""Do Chain Run."""
import os
import shutil
import subprocess
from parallelization.nextflow_wrapper import execute_nextflow_step
from steps_implementations.chain_run_bundle_substep import bundle_chrom_split_psl_files
from modules.make_chains_logging import to_log

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.error_classes import PipelineSubprocessError
from modules.common import has_non_empty_file


def psl_bundle(cat_out_dirname, project_paths, executables, params):
    # 1.1 -> sort
    concatenated_files = [os.path.join(cat_out_dirname, x) for x in os.listdir(cat_out_dirname)]
    # seems danger, but on modern systems ARG_MAX is quite large
    # and the number of concatenated files unlikely exceeds a few thousands
    sort_cmd = [executables.psl_sort_acc,
                "nohead",
                project_paths.sorted_psl_dir,
                project_paths.kent_temp_dir,
                *concatenated_files]
    to_log(f"Sorting PSL files, saving the results to {project_paths.sorted_psl_dir}")
    to_log(" ".join(sort_cmd))

    sort_process_result = subprocess.run(sort_cmd, stderr=subprocess.PIPE)
    if sort_process_result.returncode != 0:
        raise PipelineSubprocessError(
            f"The sort command failed with exit code {sort_process_result.returncode}."
            f"Error message: {sort_process_result.stderr.decode('utf-8')}"
        )

    # shutil.rmtree(project_paths.temp_dir_for_psl_sort)

    # 1.2 -> bundle chrom split files
    bundle_chrom_split_psl_files(project_paths.sorted_psl_dir,
                                 params.seq_1_len,
                                 project_paths.split_psl_dir,
                                 Constants.BUNDLE_PSL_MAX_BASES)
    to_log(f"PSL bundle sub-step done")


def make_chains_joblist(project_paths: ProjectPaths,
                        params: PipelineParameters,
                        executables: StepExecutables):
    # Prepare parameters
    seq1_dir = params.seq_1_dir
    seq2_dir = params.seq_2_dir
    # matrix = params.lastz_q if params.lastz_q else ""
    # matrix = ""
    min_score = params.chain_min_score
    linear_gap = params.chain_linear_gap
    bundle_filenames = os.listdir(project_paths.split_psl_dir)
    to_log(f"Building axtChain joblist for {len(bundle_filenames)} bundled psl files")

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
    psl_bundle(project_paths.cat_out_dirname, project_paths, executables, params)

    # Part 2: create chains joblist
    chain_jobs = make_chains_joblist(project_paths, params, executables)

    # Part 3: execute cluster jobs
    to_log(f"Saving {len(chain_jobs)} axtChain jobs to {project_paths.chain_joblist_path}")
    with open(project_paths.chain_joblist_path, "w") as f:
        f.write("\n".join(chain_jobs))
        f.write("\n")

    execute_nextflow_step(
        executables.nextflow,
        params.cluster_executor,
        params.chaining_memory,
        Constants.NextflowConstants.JOB_TIME_REQ,
        Constants.NextflowConstants.CHAIN_RUN_LABEL,
        project_paths.chain_run_dir,
        params.cluster_queue,
        project_paths.chain_joblist_path,
        project_paths.chain_run_dir
    )
    has_non_empty_file(project_paths.chain_output_dir, "chain_run")
    to_log(f"Chain run output files saved to {project_paths.chain_output_dir}")
