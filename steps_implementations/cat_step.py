"""Cat step implementation."""
import os
import gzip
import shutil

from constants import Constants
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.make_chains_logging import to_log
from modules.common import has_non_empty_file
from modules.error_classes import PipelineFileNotFoundError


def do_cat(params: PipelineParameters,
           project_paths: ProjectPaths,
           executables: StepExecutables):
    tot_combined_files = 0
    concatenated_paths = []
    # 1. List PSL buckets
    lastz_output_buckets = [x for x in os.listdir(project_paths.lastz_output_dir)
                            if x.startswith(Constants.LASTZ_OUT_BUCKET_PREFIX)]
    num_lastz_buckets = len(lastz_output_buckets)
    if num_lastz_buckets == 0:
        raise PipelineFileNotFoundError("Found no lastz output buckets!")
    to_log(f"Concatenating LASTZ output from {len(lastz_output_buckets)} buckets")
    # 2. Combine each bucket separately
    for num, bucket in enumerate(lastz_output_buckets):
        bucket_location = os.path.join(project_paths.lastz_output_dir, bucket)
        output_filename = os.path.join(project_paths.cat_out_dirname, f"concat_{num}.psl.gz")
        filenames_to_concat = os.listdir(bucket_location)
        len_out_files = len(filenames_to_concat)
        if len_out_files == 0:
            to_log(f"* skip bucket {bucket}: nothing to concat")
            shutil.rmtree(bucket_location)
            continue
        tot_combined_files += len_out_files
        psl_files = [os.path.join(bucket_location, psl) for psl in filenames_to_concat]
        concatenated_paths.append(output_filename)
        # concatenate files into the bucket
        with gzip.open(output_filename, 'wt') as out_f:
            for psl_file in psl_files:
                with open(psl_file, "r") as in_f:
                    for line in in_f:
                        if "#" in line:
                            continue
                        out_f.write(line)
        # concatenation end
        to_log(f"* concatenated bucket {bucket} to {output_filename}")

    has_non_empty_file(project_paths.cat_out_dirname, "cat_step")
    num_concated_files = len(concatenated_paths)
    to_log(f"Concatenated {tot_combined_files} files in total into {num_concated_files} files")
