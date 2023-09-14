"""Common functions that can be potentially necessary for all modules."""
import os.path
from modules.make_chains_logging import to_log
from modules.error_classes import PipelineFileNotFound


def read_chrom_sizes(chrom_sizes_path):
    """Read chrom.sizes file"""
    chrom_sizes = {}
    f = open(chrom_sizes_path, "r")
    for line in f:
        line_data = line.rstrip().split("\t")
        chrom = line_data[0]
        chrom_size = int(line_data[1])
        chrom_sizes[chrom] = chrom_size
    f.close()
    return chrom_sizes


def read_list_txt_file(txt_file):
    """Just read a txt file as a list of strings."""
    with open(txt_file, "r") as f:
        return [x.rstrip() for x in f]


def check_expected_file(path, label):
    if os.path.isfile(path):
        return
    err_msg = (
        f"Error! An expected file {path} was not found. "
        f"The failed operation label is: {label}"
    )
    raise PipelineFileNotFound(err_msg)
