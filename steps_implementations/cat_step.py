"""Cat step implementation."""
import os
import gzip

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables


def do_cat(params: PipelineParameters,
           project_paths: ProjectPaths,
           executables: StepExecutables):
    # 1. List PSL Files
    psl_files = [f for f in os.listdir(project_paths.psl_output_dir) if f.endswith('.psl')]
    print(psl_files)

    # 2. Concatenate Files
    print("!! TODO: don't forget to make smarter files organisation")
    # TODO: don't forget to make smarter files organisation
    output_file_path = os.path.join(project_paths.cat_out_dirname, "concatenated.psl.gz")
    with gzip.open(output_file_path, 'wt') as out_f:
        for psl_file in psl_files:
            with open(os.path.join(project_paths.psl_output_dir, psl_file), 'r') as in_f:
                for line in in_f:
                    if "#" not in line:
                        out_f.write(line)