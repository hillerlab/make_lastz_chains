"""Bundle Psl for Chaining step."""
import os
import subprocess
from constants import Constants


def sort_psl_file(input_file, output_file, psl_sort_acc_executable):
    # Using subprocess to call the external psl_sort_acc executable
    sort_command = f"{psl_sort_acc_executable} {input_file} > {output_file}"
    subprocess.run(sort_command, shell=True, check=True)


def bundle_psl_file(input_file, output_dir, max_bases, bundle_chrom_split_psl_files_executable):
    # Using subprocess to call the external bundle_chrom_split_psl_files executable
    bundle_command = f"{bundle_chrom_split_psl_files_executable} {input_file} {output_dir} --maxBases {max_bases}"
    subprocess.run(bundle_command, shell=True, check=True)


def do_bundle_psl(project_dir, params, executables):
    cat_out_dirname = os.path.join(project_dir, Constants.TEMP_CAT_DIRNAME)
    concatenated_file_path = os.path.join(cat_out_dirname, "concatenated.psl.gz")

    # Step 1: Sort the concatenated PSL file
    sorted_file_path = os.path.join(cat_out_dirname, "sorted.psl.gz")
    sort_psl_file(concatenated_file_path,
                  sorted_file_path,
                  executables.psl_sort_acc)

    # Step 2: Bundle the sorted PSL file into chunks
    bundled_output_dir = os.path.join(project_dir, "BUNDLED_DIR")
    os.makedirs(bundled_output_dir, exist_ok=True)
    bundle_psl_file(sorted_file_path,
                    bundled_output_dir,
                    max_bases=Constants.BUNDLE_PSL_MAX_BASES,
                    bundle_chrom_split_psl_files_executable=executables.bundle_chrom_split_psl_files)

