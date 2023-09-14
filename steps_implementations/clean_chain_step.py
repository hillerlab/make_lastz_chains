"""Clean chains step."""
import os.path
import shutil
import subprocess
from modules.make_chains_logging import to_log
from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables


def do_chains_clean(params: PipelineParameters,
                    project_paths: ProjectPaths,
                    executables: StepExecutables):
    # select input chain files, depending on whether fill chains step was executed or not
    if params.fill_chain is True:
        to_log(f"Chains were filled: using {project_paths.filled_chain} as input")
        input_chain = project_paths.filled_chain
    else:
        to_log(f"Fill chains step was skipped: using {project_paths.merged_chain} as input")
        input_chain = project_paths.merged_chain

    if not os.path.isfile(input_chain):
        raise RuntimeError(f"Cannot find {input_chain}")

    shutil.move(input_chain, project_paths.before_cleaning_chain)
    to_log(f"Chain to be cleaned saved to: {project_paths.before_cleaning_chain}")
    # TODO: I don't really like this original decision, to be revised
    _output_chain = input_chain.removesuffix(".gz")
    _clean_chain_args = params.clean_chain_parameters.split()
    # dirty hack to override chainNet not found error
    _temp_env = os.environ.copy()
    _temp_env["PATH"] = f"{project_paths.chain_clean_micro_env}:" + _temp_env["PATH"]

    chain_cleaner_cmd = [
        executables.chain_cleaner,
        project_paths.before_cleaning_chain,
        params.seq_1_dir,
        params.seq_2_dir,
        _output_chain,
        project_paths.clean_removed_suspects,
        f"-linearGap={params.chain_linear_gap}",
        f"-tSizes={params.seq_1_len}",
        f"-qSizes={params.seq_2_len}",
        *_clean_chain_args,
    ]

    to_log(" ".join(chain_cleaner_cmd))
    with open(project_paths.chain_cleaner_log, 'w') as f:
        rc = subprocess.call(chain_cleaner_cmd, stdout=f, stderr=subprocess.STDOUT, env=_temp_env)
        # TODO: deal with Couldn't open /proc/self/stat , No such file or directory
        # error on MacOS. If this error -> ignore, but crash in case of anything else.
        # if rc != 0:
        # ERROR: chainNet (kent source code) is not a binary in $PATH.
        # Either install the kent source code or provide the nets as input.
        # ERROR: NetFilterNonNested.perl(comes with the chainCleaner source code)
        # is not a binary in $PATH.Either install it or provide the nets as input.
        # raise RuntimeError(f"Command {chain_cleaner_cmd} crashed")
    to_log(f"Chain clean results saved to: {_output_chain}")

    gzip_cmd = ["gzip", _output_chain]
    subprocess.call(gzip_cmd)
    to_log("Chain clean DONE")
