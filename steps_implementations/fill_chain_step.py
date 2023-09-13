"""Fill chains step."""

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables


def do_chains_fill(params: PipelineParameters,
                   project_paths: ProjectPaths,
                   executables: StepExecutables):
    # create jobs
    # print $fh "$splitChain_into_randomParts -c $runDir/all.chain -n $numFillJobs -p $jobsDir/infillChain_\n";
    # print $fh "for f in $jobsDir/infillChain_*\n";
    # print $fh "do\n";
    # print $fh "\techo $runFillSc
    print("Not implemented!")
