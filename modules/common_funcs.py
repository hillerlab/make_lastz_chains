"""Common functions that can be potentially necessary for all modules."""


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
