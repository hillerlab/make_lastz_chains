"""Collection of procedures to set up the pipeline input."""
import sys
import os
import subprocess
from twobitreader import TwoBitFile
from twobitreader import TwoBitFileError
from modules.make_chains_logging import to_log
from constants import Constants
from modules.project_paths import ProjectPaths
from modules.step_executables import StepExecutables
from modules.make_chains_logging import to_log


def check_if_twobit(genome_seq_file):
    try:
        two_bit_reader = TwoBitFile(genome_seq_file)
        del two_bit_reader
        return True
    except TwoBitFileError:
        # not a twobit, likely a fasta
        return False


def check_and_fix_chrom_names(chrom_names, path):
    """Given list of chrom names, fix those with dots and spaces in names."""
    ret = {}  # old chrom name: new chrom name
    upd_chromosome_names_qc = []  # to check whether all new chrom names are uniq
    for chrom_name in chrom_names:
        if " " in chrom_name or "\t" in chrom_name:
            # error, spaces and tabs are not allowed in chromosome names
            to_log(f"Error! File: {path} - detected space-or-tab-containing sequence:")
            to_log(f"{chrom_name}")
            to_log("Please exclude or fix sequences with spaces and tabs.\nAbort")
            sys.exit(1)
        dots_in_header = "." in chrom_name
        # spaces_in_header = " " in chrom_name
        # if dots_in_header is False and spaces_in_header is False:
        #     continue
        if dots_in_header is False:
            # no . in chrom name: nothing to change
            continue
        # this chrom name is going to be updated
        # split by dot and space
        # upd_chrom_name = _fix_dot_space_chrom_name(chrom_name)
        upd_chrom_name = chrom_name.split(".")[0]
        ret[chrom_name] = upd_chrom_name
        upd_chromosome_names_qc.append(upd_chrom_name)

    if len(upd_chromosome_names_qc) != len(set(upd_chromosome_names_qc)):
        to_log(f"# Error! Some chromosome names in {path} contain dots and spaces")
        to_log(f"Could not fix names automatically: the process produces non-unique")
        to_log(f"chromosome names. Pls see README.md for details.")
        to_log("Abort.")
        sys.exit(1)
    return ret


def check_chrom_names_in_fasta(fa_path):
    """Check whether chrom names contain dots or spaces in fasta."""
    with open(fa_path, "r") as f:
        chrom_names = [line.lstrip(">").rstrip() for line in f if line.startswith(">")]
    old_to_new_chrom_name = check_and_fix_chrom_names(chrom_names, fa_path)
    return old_to_new_chrom_name


def call_two_bit_to_fa_subprocess(cmd, genome_seq_file):
    try:
        subprocess.call(cmd, shell=True)
        # if failed: then it's likely not a fasta
    except subprocess.CalledProcessError:
        err_msg = (
            f"Error! Could not execute {cmd}\n"
            f"Please check whether {genome_seq_file} is "
            f"a valid fasta or 2bit file.\n"
            f"Also, make sure twoBitToFa is callable.\n"
        )
        to_log(err_msg)
        sys.exit(1)


def rename_chrom_names_fasta(genome_seq_file, tmp_dir, genome_id, invalid_chrom_names):
    """Rename chrom names in fasta, save it to tmp dir, create rename table."""
    # specify output fasta and table paths, open in and out fasta
    renamed_fasta_path = os.path.join(tmp_dir, f"{genome_id}_renamed_chrom.fa")
    rename_table = os.path.join(tmp_dir, f"{genome_id}_chrom_rename_table.tsv")
    out_f = open(renamed_fasta_path, "w")
    in_f = open(genome_seq_file, "r")
    # create new fasta with renamed chroms
    for line in in_f:
        if not line.startswith(">"):
            # seq line -> save without changes
            out_f.write(line)
            continue
        # header line, probably need to rename
        chrom_name_old = line.lstrip(">").rstrip()
        new_name = invalid_chrom_names.get(chrom_name_old)
        if new_name is None:
            # no need to rename: this chrom name is intact
            out_f.write(line)
        else:
            # write renamed chrom name
            out_f.write(f">{new_name}\n")
    out_f.close()
    in_f.close()

    # write rename table
    f = open(rename_table, "w")
    for k, v in invalid_chrom_names.items():
        f.write(f"{k}\t{v}\n")
    f.close()
    return renamed_fasta_path, rename_table


def setup_genome_sequences(genome_seq_file: str,
                           genome_id: str,
                           label: str,
                           project_paths: ProjectPaths,
                           executables: StepExecutables):
    """Setup genome sequence input.

    DoBlastzChainNet procedure requires the 2bit-formatted sequence
    so create 2bit if the genome sequence is fasta-formatted.
    Also, the procedure requires chrom.sizes file, which also needs
    to be satisfied."""
    # check whether genome sequence is twobit or fasta
    # afterward, check whether there are valid chrom names
    # the pipeline cannot process chromosome names containing dots and spaces
    # Pls see the GitHub issue about this:
    # https://github.com/hillerlab/make_lastz_chains/issues/3
    is_two_bit = check_if_twobit(genome_seq_file)
    chrom_rename_table_path = None

    # genome seq path -> final destination of 2bit used for further pipeline steps
    if is_two_bit:
        # two bit -> if chrom names are intact, just use this file without
        # creating any intermediate files
        # otherwise, create intermediate fasta with fixed chrom names
        two_bit_reader = TwoBitFile(genome_seq_file)
        two_bit_chrom_names = list(two_bit_reader.sequence_sizes().keys())
        invalid_chrom_names = check_and_fix_chrom_names(
            two_bit_chrom_names, genome_seq_file
        )

        if len(invalid_chrom_names) > 0:
            # there are invalid chrom names, that need to be renamed
            # (1) create intermediate fasta and rename chromosomes there
            fasta_dump_path = os.path.join(project_paths.project_dir, f"TEMP_{genome_id}_genome_dump.fa")
            two_bit_to_fa_cmd = f"{executables.two_bit_to_fa} {genome_seq_file} {fasta_dump_path}"
            call_two_bit_to_fa_subprocess(two_bit_to_fa_cmd, genome_seq_file)
            genome_seq_file, chrom_rename_table_path = rename_chrom_names_fasta(
                fasta_dump_path, project_paths.project_dir, genome_id, invalid_chrom_names
            )
            genome_seq_path = os.path.abspath(
                os.path.join(project_paths.project_dir, f"{label}.2bit")
            )
            os.remove(fasta_dump_path)
            # (2) create 2bit with renamed sequences
            fa_to_two_bit_cmd = f"{executables.fa_to_two_bit} {genome_seq_file} {genome_seq_path}"
            call_two_bit_to_fa_subprocess(fa_to_two_bit_cmd, genome_seq_file)
        else:
            # no invalid chrom names, use 2bit as is
            genome_seq_path = os.path.abspath(genome_seq_file)
    else:
        # fasta, need to convert fasta to 2bit
        invalid_chrom_names = check_chrom_names_in_fasta(genome_seq_file)
        if len(invalid_chrom_names) > 0:
            # there are invalid chrom names:
            # create temp fasta with renamed chroms -> use it to produce 2bit file
            # create rename table -> to track chrom name changes
            # update genomes seq file then -> use it as src to create twobit
            genome_seq_file, chrom_rename_table_path = rename_chrom_names_fasta(
                genome_seq_file, project_paths.project_dir, genome_id, invalid_chrom_names
            )

        genome_seq_path = os.path.abspath(os.path.join(project_paths.project_dir, f"{label}.2bit"))
        cmd = f"{executables.fa_to_two_bit} {genome_seq_file} {genome_seq_path}"
        call_two_bit_to_fa_subprocess(cmd, genome_seq_file)

    # now need to create chrom.sizes file
    chrom_sizes_filename = f"{label}.chrom.sizes"
    chrom_sizes_path = os.path.join(project_paths.project_dir, chrom_sizes_filename)

    # must be without errors now
    two_bit_reader = TwoBitFile(genome_seq_path)
    twobit_seq_to_size = two_bit_reader.sequence_sizes()

    f = open(chrom_sizes_path, "w")
    for k, v in twobit_seq_to_size.items():
        f.write(f"{k}\t{v}\n")
    f.close()

    to_log(f"For {genome_id} ({label}) sequence file: {genome_seq_path}; chrom sizes saved to: {chrom_sizes_path}")

    if len(invalid_chrom_names) > 0:
        to_log(f"Warning! Genome sequence file {genome_seq_file}")
        to_log(f"{len(invalid_chrom_names)} chromosome names cannot be processed via pipeline")
        to_log(f"were renamed in the intermediate files according to {chrom_rename_table_path}")

    if label == Constants.TARGET_LABEL:
        project_paths.set_target_chrom_rename_table(chrom_rename_table_path)
    else:
        project_paths.set_query_chrom_rename_table(chrom_rename_table_path)


if __name__ == "__main__":
    pass
