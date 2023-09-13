"""Fill chains step."""
import subprocess
import os
from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.make_chains_logging import to_log
from steps_implementations.fill_chain_split_into_parts_substep import randomly_split_chains


def create_repeat_filler_joblist(params: PipelineParameters,
                                 project_paths: ProjectPaths,
                                 executables: StepExecutables):
    infill_chain_filenames = os.listdir(project_paths.fill_chain_jobs_dir)
    lastz_parameters = f"\"K={params.fill_lastz_k} L={params.fill_lastz_l}\""
    repeat_filler_params = [
        f"--chainMinScore {params.chain_min_score}",
        f"--gapMaxSizeT {params.fill_gap_max_size_t}",
        f"--gapMaxSizeQ {params.fill_gap_max_size_q}",
        f"--scoreThreshold {params.fill_insert_chain_min_score}",
        f"--gapMinSizeT {params.fill_gap_min_size_t}",
        f"--gapMinSizeQ {params.fill_gap_min_size_q}"
    ]
    if params.fill_unmask:
        repeat_filler_params.append("--unmask")

    f = open(project_paths.repeat_filler_joblist, "w")
    for filename in infill_chain_filenames:
        chainf = os.path.join(project_paths.fill_chain_jobs_dir, filename)
        chainf_out = os.path.join(project_paths.fill_chain_filled_dir, filename)
        repeat_filler_command_parts = [
            executables.repeat_filler,
            f"--workdir {project_paths.fill_chain_run_dir}",
            f"--chainExtractID {executables.chain_extract_id}",
            f"--lastz {executables.lastz}",
            f"--axtChain {executables.axt_chain}",
            f"--chainSort {executables.chain_sort}",
            f"-c {chainf}",
            f"-T2 {params.seq_1_dir}",
            f"-Q2 {params.seq_2_dir}",
            *repeat_filler_params,
            f"--lastzParameters {lastz_parameters}",
            "|",
            executables.chain_score,
            f"-linearGap={params.chain_linear_gap}",
            # $scoreChainParameters,
            "stdin",
            params.seq_1_dir,
            params.seq_2_dir,
            "stdout",
            "|",
            executables.chain_sort,
            "stdin",
            chainf_out
        ]
        repeat_filler_command = " ".join(repeat_filler_command_parts)
        f.write(f"{repeat_filler_command}\n")
    f.close()

    to_log(f"Saved {len(infill_chain_filenames)} chain fill jobs to {project_paths.repeat_filler_joblist}")


def do_chains_fill(params: PipelineParameters,
                   project_paths: ProjectPaths,
                   executables: StepExecutables):
    # create jobs
    # print $fh "$splitChain_into_randomParts -c $runDir/all.chain -n $numFillJobs -p $jobsDir/infillChain_\n";
    # print $fh "for f in $jobsDir/infillChain_*\n";
    # print $fh "do\n";
    # print $fh "\techo $runFillSc

    # 1. job preparation script
    infill_template = f"{project_paths.fill_chain_jobs_dir}/infill_chain_"

    # Need to unzip the zipped merged chain first...
    temp_in_chain = os.path.join(project_paths.fill_chain_run_dir, "all.chain")  # TODO: add to paths
    gunzip_cmd = [
        "gunzip",
        "-c",
        project_paths.merged_chain
    ]
    to_log(f"gunzip -c {project_paths.merged_chain} > {temp_in_chain}")
    with open(temp_in_chain, "wb") as f:
        subprocess.run(gunzip_cmd, stdout=f)

    randomly_split_chains(temp_in_chain, params.num_fill_jobs, infill_template)

    # 2. create and execute fill joblist
    create_repeat_filler_joblist(params, project_paths, executables)
    raise NotImplementedError

