"""Common functions that can be potentially necessary for all modules."""
import os.path
from dataclasses import dataclass

from modules.make_chains_logging import to_log
from constants import Constants
from modules.error_classes import PipelineFileNotFoundError


@dataclass
class GenomicRegion:
    chrom: str
    start: int
    end: int

    def to_two_bit_address(self, seq_dir):
        return f"{os.path.abspath(seq_dir)}:{self.chrom}:{self.start}-{self.end}"

    def to_bucket_dirname(self):
        return f"{Constants.LASTZ_OUT_BUCKET_PREFIX}_{self.chrom}_in_{self.start}_{self.end}"


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


def has_non_empty_file(directory, label):
    for filename in os.listdir(directory):
        filepath = os.path.join(directory, filename)
        if os.path.isfile(filepath) and os.path.getsize(filepath) > 0:
            return
    err_msg = (
        f"Error! No non-empty files found at {directory}. "
        f"The failed operation label is: {label}"
    )
    raise PipelineFileNotFoundError(err_msg)


def check_expected_file(path, label):
    if os.path.isfile(path):
        return
    err_msg = (
        f"Error! An expected file {path} was not found. "
        f"The failed operation label is: {label}"
    )
    raise PipelineFileNotFoundError(err_msg)
