"""Partition step implementation."""
import os
from modules.make_chains_logging import to_log
from constants import Constants
from modules.common_funcs import read_chrom_sizes
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.error_classes import PipelineFileNotFoundError


def do_partition_for_genome(genome_label: str,
                            params: PipelineParameters,
                            project_paths: ProjectPaths,
                            executables: StepExecutables):
    to_log(f"# Partitioning for {genome_label}")

    # Determine directories and filenames based on the genome label
    seq_dir = params.seq_1_dir if genome_label == Constants.TARGET_LABEL else params.seq_2_dir
    seq_len_file = params.seq_1_len if genome_label == Constants.TARGET_LABEL else params.seq_2_len
    chunk_size = params.seq_1_chunk if genome_label == Constants.TARGET_LABEL else params.seq_2_chunk
    overlap = params.seq_1_lap if genome_label == Constants.TARGET_LABEL else params.seq_2_lap
    # seq_limit = 0  # Replace with your actual seq limit if any

    # Read chromosome sizes
    chrom_sizes = read_chrom_sizes(seq_len_file)

    # Create output directories
    output_dir = os.path.join(project_paths.project_dir, Constants.TEMP_LASTZ_DIRNAME)
    os.makedirs(output_dir, exist_ok=True)

    # Initialize partition list and small chrom list
    partition_list = []
    if genome_label == Constants.TARGET_LABEL:
        partition_file_path = project_paths.reference_partitions
    else:
        partition_file_path = project_paths.query_partitions

    for chrom, size in chrom_sizes.items():
        start = 0
        while start < size:
            end = min(start + chunk_size, size)
            partition = f"{os.path.abspath(seq_dir)}:{chrom}:{start}-{end}"
            partition_list.append(partition)
            start += chunk_size - overlap  # Move the start point for the next chunk

    if len(partition_list) == 0:
        raise PipelineFileNotFoundError(f"Could not make any partition for {genome_label}")
    # Save the partition list to a file
    with open(partition_file_path, 'w') as f:
        for part in partition_list:
            f.write(f"{part}\n")
    to_log(f"Saving {genome_label} partitions to: {partition_file_path}")
    return partition_list
