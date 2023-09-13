"""Fill chains step."""
import subprocess
import os
from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.make_chains_logging import to_log
from steps_implementations.fill_chain_split_into_parts_substep import split_chains

def do_chains_fill(params: PipelineParameters,
                   project_paths: ProjectPaths,
                   executables: StepExecutables):
    # create jobs
    # print $fh "$splitChain_into_randomParts -c $runDir/all.chain -n $numFillJobs -p $jobsDir/infillChain_\n";
    # print $fh "for f in $jobsDir/infillChain_*\n";
    # print $fh "do\n";
    # print $fh "\techo $runFillSc

    lastz_parameters = [f"K={params.fill_lastz_k}", f"L={params.fill_lastz_l}"]
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

    split_chains(temp_in_chain, params.num_fill_jobs, infill_template)
    raise NotImplementedError

