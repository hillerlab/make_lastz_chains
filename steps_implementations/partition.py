"""Partition step implementation."""
import os
from collections import defaultdict
from modules.make_chains_logging import to_log
from constants import Constants
from modules.common import read_chrom_sizes
from modules.parameters import PipelineParameters
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.common import GenomicRegion
from modules.error_classes import PipelineFileNotFoundError


def create_partition(chrom_sizes, chunk_size, overlap):
    """High-level partitioning."""
    partition_list = []
    little_scaffolds_to_bulk = []
    scaffold_size_threshold = chunk_size * 0.45

    for chrom, size in chrom_sizes.items():
        if size < scaffold_size_threshold:
            little_scaffolds_to_bulk.append((chrom, size))
            continue
        start = 0
        while start < size:
            end = min(start + chunk_size, size)
            partition_interval = GenomicRegion(chrom, start, end)
            partition_list.append(partition_interval)
            start += chunk_size - overlap  # Move the start point for the next chunk
    return partition_list, little_scaffolds_to_bulk


def create_buckets_for_little_scaffolds(little_scaffolds_to_bulk, chunk_size):
    """Arrange little scaffolds into bigger groups."""
    bulk_num_to_chroms = defaultdict(list)
    bulk_size_threshold = chunk_size * 0.9
    bulk_number = 1
    current_bulk_size = 0

    for chrom, size in little_scaffolds_to_bulk:
        if (current_bulk_size + size) > bulk_size_threshold:
            bulk_number += 1
            current_bulk_size = 0
        bulk_num_to_chroms[bulk_number].append(chrom)
        current_bulk_size += size
    return bulk_num_to_chroms


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
    if genome_label == Constants.TARGET_LABEL:
        partition_file_path = project_paths.reference_partitions
    else:
        partition_file_path = project_paths.query_partitions

    if not os.path.isfile(seq_dir):
        err_msg = f"Error! Could not find genome sequences file {seq_dir}. Please contact developers."
        raise PipelineFileNotFoundError(err_msg)
    # Read chromosome sizes
    chrom_sizes = read_chrom_sizes(seq_len_file)

    # Create output directories
    output_dir = os.path.join(project_paths.project_dir, Constants.TEMP_LASTZ_DIRNAME)
    os.makedirs(output_dir, exist_ok=True)

    # Initialize partition list and small chrom list
    partition_list, little_scaffolds_to_bulk = create_partition(chrom_sizes, chunk_size, overlap)

    # little chromosomes/scaffolds are bulked together to avoid huge amount of jobs
    bulk_num_to_chroms = create_buckets_for_little_scaffolds(little_scaffolds_to_bulk, chunk_size)

    # Save the partition list to a file
    tot_num_buckets = len(partition_list) + len(bulk_num_to_chroms)
    to_log(f"Saving partitions and creating {tot_num_buckets} buckets for lastz output")
    to_log(f"In particular, {len(partition_list)} partitions for bigger chromosomes")
    to_log(f"And {len(bulk_num_to_chroms)} buckets for smaller scaffolds")

    out_f = open(partition_file_path, 'w')
    for part in partition_list:
        out_f.write(f"{part.to_two_bit_address(seq_dir)}\n")
        if genome_label == Constants.TARGET_LABEL:
            # create buckets only for reference
            bucket_dir = os.path.join(project_paths.lastz_output_dir, part.to_bucket_dirname())
            os.makedirs(bucket_dir, exist_ok=True)
    for bulk_number, chroms in bulk_num_to_chroms.items():
        chroms_ids = ":".join(chroms)
        partition_file_line = (
            f"{Constants.PART_BULK_FILENAME_PREFIX}_{bulk_number}:{os.path.abspath(seq_dir)}:{chroms_ids}\n"
        )
        out_f.write(partition_file_line)
        if genome_label == Constants.TARGET_LABEL:
            bucket_dir = os.path.join(project_paths.lastz_output_dir,
                                      f"{Constants.LASTZ_OUT_BULK_PREFIX}_{bulk_number}")
            os.makedirs(bucket_dir, exist_ok=True)
    out_f.close()

    to_log(f"Saving {genome_label} partitions to: {partition_file_path}")
    return partition_list
