"""Cat step implementation."""
import os
import gzip
from constants import Constants


def do_cat(project_dir, params, executables):
    # TODO: probably we need to save separate files for each pair of chroms?
    psl_output_dir = os.path.join(project_dir, Constants.TEMP_PSL_DIRNAME)
    cat_out_dirname = os.path.join(project_dir, Constants.TEMP_CAT_DIRNAME)
    os.makedirs(cat_out_dirname, exist_ok=True)

    # 1. List PSL Files
    psl_files = [f for f in os.listdir(psl_output_dir) if f.endswith('.psl')]
    print(psl_files)

    # 2. Concatenate Files
    output_file_path = os.path.join(cat_out_dirname, "concatenated.psl.gz")
    with gzip.open(output_file_path, 'wt') as out_f:
        for psl_file in psl_files:
            with open(os.path.join(psl_output_dir, psl_file), 'r') as in_f:
                for line in in_f:
                    if "#" not in line:
                        out_f.write(line)
