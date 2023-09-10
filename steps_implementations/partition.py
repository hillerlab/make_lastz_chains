"""Partition step implementation."""
import os
from constants import Constants
from modules.common_funcs import read_chrom_sizes


def do_partition_for_genome(genome_label, project_dir, params, executables):
    print(f"# Partitioning for {genome_label}")

    # Determine directories and filenames based on the genome label
    seq_dir = params.seq_1_dir if genome_label == Constants.TARGET_LABEL else params.seq_2_dir
    seq_len_file = params.seq_1_len if genome_label == Constants.TARGET_LABEL else params.seq_2_len
    chunk_size = params.seq_1_chunk if genome_label == Constants.TARGET_LABEL else params.seq_2_chunk
    overlap = params.seq_1_lap if genome_label == Constants.TARGET_LABEL else params.seq_2_lap
    # seq_limit = 0  # Replace with your actual seq limit if any

    # Read chromosome sizes
    chrom_sizes = read_chrom_sizes(seq_len_file)

    # Create output directories
    output_dir = os.path.join(project_dir, Constants.TEMP_LASTZ_DIRNAME)
    os.makedirs(output_dir, exist_ok=True)

    # Initialize partition list and small chrom list
    partition_list = []
    partition_file_path = os.path.join(output_dir, f"{genome_label}_partitions.txt")

    for chrom, size in chrom_sizes.items():
        start = 0
        while start < size:
            end = min(start + chunk_size, size)
            partition = f"{os.path.abspath(seq_dir)}:{chrom}:{start}-{end}"
            partition_list.append(partition)
            start += chunk_size - overlap  # Move the start point for the next chunk

    # Save the partition list to a file
    with open(partition_file_path, 'w') as f:
        for part in partition_list:
            f.write(f"{part}\n")


# Not necessary: just a reference, translated from perl
def reference_old_do_partition_for_genome(genome_label, project_dir, params, executables):
    print(f"# Partitioning for {genome_label}")

    # Determine directories and filenames based on the genome label
    seq_dir = params.seq_1_dir if genome_label == Constants.TARGET_LABEL else params.seq_2_dir
    seq_len_file = params.seq_1_len if genome_label == Constants.TARGET_LABEL else params.seq_2_len
    chunk_size = params.seq_1_chunk if genome_label == Constants.TARGET_LABEL else params.seq_2_chunk
    overlap = params.seq_1_lap if genome_label == Constants.TARGET_LABEL else params.seq_2_lap
    seq_limit = 0  # Replace with your actual seq limit if any

    # Read chromosome sizes
    chrom_sizes = read_chrom_sizes(seq_len_file)

    # Create output directories
    output_dir = os.path.join(project_dir, Constants.TEMP_LASTZ_DIRNAME)
    part_dir = os.path.join(output_dir, f"{genome_label}_parts")

    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(part_dir, exist_ok=True)

    # Initialize partition list and small chrom list
    partition_list = []
    small_chrom_list = []
    glom_size = 0

    # Loop through each chromosome and partition
    for chrom, size in chrom_sizes.items():
        if size > chunk_size + overlap:
            # Large chromosome, split it
            start = 0
            while start < size:
                end = min(start + chunk_size, size)
                partition = f"{seq_dir}:{chrom}:{start}-{end}"
                partition_list.append(partition)

                # Write to a .lst file in the part directory
                lst_file = os.path.join(part_dir, f"part{len(partition_list)}.lst")
                with open(lst_file, 'w') as f:
                    f.write(partition + '\n')

                start += chunk_size - overlap  # Move the start point for the next chunk
        else:
            # Small chromosome, save for later
            if glom_size > 0 and (glom_size + size > chunk_size or (len(small_chrom_list) >= seq_limit and seq_limit > 0)):
                lst_file = os.path.join(part_dir, f"part_small_chroms{len(partition_list)}.lst")
                with open(lst_file, 'w') as f:
                    for partition in small_chrom_list:
                        f.write(partition + '\n')
                small_chrom_list = []
                glom_size = 0

            glom_size += size
            small_chrom_list.append(f"{seq_dir}:{chrom}:0-{size}")

    # Lump smaller chromosomes together into a single .lst file
    if small_chrom_list:
        lst_file = os.path.join(part_dir, f"part_small_chroms{len(partition_list)}.lst")
        with open(lst_file, 'w') as f:
            for partition in small_chrom_list:
                f.write(partition + '\n')

    return partition_list
