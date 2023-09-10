#!/usr/bin/env python3
"""Build chains for a given pair of target and query genomes.

Based on Hillerlab solution doBlastzChainNet.pl
and UCSC Kent Source.
"""
import argparse
import sys
import os
import re
import shutil
import json
import subprocess
from datetime import datetime as dt
from shutil import which
from twobitreader import TwoBitFile
from twobitreader import TwoBitFileError

__author__ = "Bogdan Kirilenko, Michael Hiller, Ekaterina Osipova"  # TODO: anyone else?
__maintainer__ = "Bogdan Kirilenko"
__email__ = ""  # TODO: me or Michael?
__version__ = "0.9.1"

DESCRIPTION = "Build chains for a given pair of target and query genomes."
HERE = os.path.abspath(os.path.dirname(__file__))
FATOTWOBIT = "faToTwoBit"
TWOBITTOFA = "twoBitToFa"
T_CHROM_RENAME_TABLE = "target_chromosomes_rename_table.tsv"
Q_CHROM_RENAME_TABLE = "query_chromosomes_rename_table.tsv"

# directories with all necessary scripts
DO_LASTZ_DIR = "doLastzChains"
DO_LASTZ_EXE = "doLastzChain.pl"
HL_SCRIPTS = "HL_scripts__deprecated"
HL_KENT_BINARIES = "HL_kent_binaries"
KENT_BINARIES = "kent_binaries"
GENOME_ALIGNMENT_TOOLS = "GenomeAlignmentTools/src"

# defaults
SEQ1_CHUNK = 175_000_000
SEQ2_CHUNK = 50_000_000
BLASTZ_H = 2000
BLASTZ_Y = 9400
BLASTZ_L = 3000
BLASTZ_K = 2400

MASTER_SCRIPT = "master_script.sh"

DO_LASTZ_STEPS = {
    "partition",
    "lastz",
    "cat",
    "chainRun",
    "chainMerge",
    "fillChains",
    "cleanChains",
}


def parse_args():
    """Command line arguments parser."""
    app = argparse.ArgumentParser(description=DESCRIPTION)
    app.add_argument(
        "target_name", help="Target genome identifier, e.g. hg38, human, etc."
    )
    app.add_argument(
        "query_name", help="Query genome identifier, e.g. mm10, mm39, mouse, etc."
    )
    app.add_argument(
        "target_genome", help="Target genome. Accepted formats are: fasta and 2bit."
    )
    app.add_argument(
        "query_genome", help="Query genome. Accepted formats are: fasta and 2bit."
    )
    app.add_argument("--project_dir", "--pd", help="Project directory. By default: pwd")
    app.add_argument(
        "--DEF",
        help="DEF formatted configuration file, please read README.md for details.",
    )
    app.add_argument(
        "--force_def",
        action="store_true",
        dest="force_def",
        help=(
            "Start the pipeline even if a DEF file already exists (overwrite the project)"
        ),
    )

    app.add_argument(
        "--continue_arg",
        default=None,
        help=(
            f"Continue execution in the already existing project starting with the specified step. "
            f"Available steps are: {DO_LASTZ_STEPS}"
            f"Please specify existing --project_dir to use this option"
        ),
    )

    cluster_params = app.add_argument_group("cluster_params")
    cluster_params.add_argument(
        "--executor",
        default="local",
        help=(
            "Cluster jobs executor. Please see README.md to get "
            "a list of all available systems. Default local"
        ),
    )
    cluster_params.add_argument(
        "--executor_queuesize",
        default=None,
        type=int,
        help="Controls NextFlow queueSize parameter: maximal number of jobs in the queue (default 2000)",
    )
    cluster_params.add_argument(
        "--executor_partition",
        default=None,
        help="Set cluster queue/partition (default batch)",
    )
    cluster_params.add_argument(
        "--cluster_parameters",
        default=None,
        help="Additional cluster parameters, regulates NextFlow clusterOptions (default None)",
    )

    # DEF file arguments that can be overridden
    # have higher priority than def file
    def_params = app.add_argument_group("def_params")
    def_params.add_argument(
        "--lastz", default="lastz", help="Path to specific lastz binary (if needed)"
    )
    def_params.add_argument(
        "--seq1_chunk",
        default=None,
        type=int,
        help=f"Chunk size for target sequence (default {SEQ1_CHUNK})",
    )
    def_params.add_argument(
        "--seq2_chunk",
        default=None,
        type=int,
        help=f"Chunk size for query sequence (default {SEQ2_CHUNK}) ",
    )

    def_params.add_argument(
        "--blastz_h",
        default=None,
        type=int,
        help=f"BLASTZ_H parameter, (default {BLASTZ_H})",
    )
    def_params.add_argument(
        "--blastz_y",
        default=None,
        type=int,
        help=f"BLASTZ_Y parameter, (default {BLASTZ_Y})",
    )
    def_params.add_argument(
        "--blastz_l",
        default=None,
        type=int,
        help=f"BLASTZ_L parameter, (default {BLASTZ_L})",
    )
    def_params.add_argument(
        "--blastz_k",
        default=None,
        type=int,
        help=f"BLASTZ_K parameter, (default {BLASTZ_K})",
    )
    def_params.add_argument(
        "--fill_prepare_memory",
        default=None,
        type=int,
        help="FILL_PREPARE_MEMORY parameter (default 50000)",
    )
    def_params.add_argument(
        "--chaining_memory",
        default=None,
        type=int,
        help="CHAININGMEMORY parameter, (default 50000)",
    )
    def_params.add_argument(
        "--chain_clean_memory",
        default=None,
        type=int,
        help="CHAINCLEANMEMORY parameter, (default 100000)",
    )

    if len(sys.argv) < 2:
        app.print_help()
        sys.exit(0)

    args = app.parse_args()

    # >>> sanity checks
    resume_cond_1 = args.continue_arg is not None and args.project_dir is None
    resume_cond_2 = args.continue_arg is not None and not os.path.isdir(args.project_dir)

    if resume_cond_1 or resume_cond_2:
        err_msg = (
            "Error! --resume mode implies already existing project."
            "Please specify already existing project with --project_dir"
        )
        sys.exit(err_msg)

    if args.continue_arg and args.continue_arg  not in DO_LASTZ_STEPS:
        err_msg = (f"Error! Invalid --continue_arg, please specify one of these steps: {DO_LASTZ_STEPS}")
        sys.exit(err_msg)
    # >>> sanity checks
    return args


def parse_def_file(def_arg):
    """Parse DEF file provided by user."""
    ret = {}
    if def_arg is None:
        return ret
    f = open(def_arg, "r")
    for line_ in f:
        if line_.startswith("#"):
            continue
        line = line_.rstrip()
        if len(line) == 0:
            continue
        if "=" not in line:
            continue
        var_and_val = line.split("=")
        var = var_and_val[0]
        val = var_and_val[1].split()[0]
        ret[var] = val
    f.close()
    return ret


def get_project_dir(dir_arg, force_arg, resume_arg):
    """Define project directory."""
    if dir_arg is None:
        return os.path.abspath(os.getcwd())
    os.mkdir(dir_arg) if not os.path.isdir(dir_arg) else None
    project_dir = os.path.abspath(dir_arg)
    # checking whether DEF file is present here
    # if yes: this directory was already used
    def_path = os.path.join(project_dir, "DEF")
    if resume_arg is not None:
        # trying to resume the existing run, need DEF
        if os.path.isfile(def_path):
            return project_dir

        else:
            print(f"Error, incompatible parameters. With --continue_arg, ")
            print(f"the pipeline expects DEF file to exist in the project dir.")
            print(f"File {def_path} not found, abort.")
            sys.exit(1)
    if os.path.isfile(def_path) and force_arg is False:
        print(f"Confusion: {def_path} already exists")
        print(f"Please set --force_def to override")
        sys.exit(1)
    return project_dir


def generate_def_params(def_arg, lastz_arg):
    """Generate def file with default parameters.

    If DEF file is provided: override defined parameters.
    """
    # TODO: comments, maybe move some of them to README
    def_vals = {
        # lastz with sensitive alignment parameters
        "BLASTZ": lastz_arg,
        "BLASTZ_H": BLASTZ_H,
        "BLASTZ_Y": BLASTZ_Y,
        "BLASTZ_L": BLASTZ_L,
        "BLASTZ_K": BLASTZ_K,
        # how to split the reference and query into chunks.
        # This needs to be adapted to larger chunk or larger SEQ1/2_LIMIT
        # settings in case you get too many lastz jobs.
        #
        # reference
        # "SEQ1_CHUNK": 175_000_000,
        "SEQ1_CHUNK": SEQ1_CHUNK,
        "SEQ1_LAP": 0,
        "SEQ1_LIMIT": 4000,
        # query
        # "SEQ2_CHUNK": 50_000_000,
        "SEQ2_CHUNK": SEQ2_CHUNK,
        "SEQ2_LAP": 10_000,
        "SEQ2_LIMIT": 10_000,
        # for filling chains flag: set to 1 if you want to fill chains
        # two use cases:
        # 1) Unmask the unaligning sequence between two aligning
        #   blocks and try to find mostly repeat alignments in
        #   between with parameters of similar sensitivity.
        #   This should be done for closer-species comparisons
        #   (within mammals, birds, etc) using the default parameters below.
        # 2) Align the unaligning sequence between two aligning
        #   blocks without unmasking using much more sensitive parameters.
        #   Should be done for comparisons of >0.5 subs per neutral site
        #   (human to platypus onwards).
        #    For this, set
        #      FILL_UNMASK=0
        #      FILL_CHAIN_MINSCORE=5000
        #      FILL_INSERTCHAIN_MINSCORE=1000
        #      FILL_GAPMAXSIZE_T=500000
        #      FILL_GAPMAXSIZE_Q=500000
        #      FILL_BLASTZ_K=1500
        #      FILL_BLASTZ_L=2500
        #      FILL_BLASTZ_W=5
        "FILL_CHAIN": 1,
        # unmask chains for chain filling
        "FILL_UNMASK": 1,
        # fill only chains with min score
        "FILL_CHAIN_MINSCORE": 25000,
        # only insert new chain into original chain if it exceeds this min score
        "FILL_INSERTCHAIN_MINSCORE": 5000,
        # consider only gaps that are in the reference (target)
        # and query between min and max size
        "FILL_GAPMAXSIZE_T": 20_000,
        "FILL_GAPMAXSIZE_Q": 20_000,
        "FILL_GAPMINSIZE_T": 30,
        "FILL_GAPMINSIZE_Q": 30,
        # lastz parameters for patching
        "FILL_BLASTZ_K": 2000,
        "FILL_BLASTZ_L": 3000,
        # cluster related
        # memory limit for cluster jobs
        "FILL_MEMORY": 15000,
        # prepare job splits entire chain file might need some more memory
        "FILL_PREPARE_MEMORY": 50_000,
        # set the LSF queue used for chaining. Chaining can take a long time
        # and for mammals most jobs have to run in the long queue (default).
        # If you see that your chaining jobs for your alignments
        # are faster, set to medium or short.
        "CHAININGQUEUE": "medium",
        "CHAININGMEMORY": 50_000,
        # flag: set to 1 if you want to clean the chains
        # (removing random chain-breaking alignments)
        # recommended for all chains, except very close species
        # comparisons (such as human to primates or d.mel to d.sim)
        "CLEANCHAIN": 1,
        "CHAINCLEANMEMORY": 100_000,
        # Optional: specify parameters to be passed on to chainCleaner. E.g.
        "CLEANCHAIN_PARAMETERS": (
            "-LRfoldThreshold=2.5 "
            "-doPairs "
            "-LRfoldThresholdPairs=10 "
            "-maxPairDistance=10000 "
            "-maxSuspectScore=100000 "
            "-minBrokenChainScore=75000"
        ),
    }

    user_def_params = parse_def_file(def_arg)
    def_vals.update(user_def_params)
    # TODO: check for invalid args in user-provided def
    return def_vals


def __check_if_twobit(genome_seq_file):
    try:
        two_bit_reader = TwoBitFile(genome_seq_file)
        del two_bit_reader
        return True
    except TwoBitFileError:
        # not a twobit, likely a fasta
        return False


def stat_kent_exec(name):
    """Find faToTwoBit executable."""
    exec_which_out = which(name)
    if exec_which_out:
        return exec_which_out
    # ok, faToTwoBit is not in the $PATH
    exec_bit_loc = os.path.join(HERE, KENT_BINARIES, name)
    if os.path.isfile(exec_bit_loc):
        # found it in the KENT_BINARIES
        return exec_bit_loc
    # not found fatotwobit_exe
    err_msg = (
        f"Error! Cannot stat faToTwoBit: "
        f"nether in $PATH not in {exec_bit_loc}\n"
        f"Please make sure you called ./install_dependencies.py and "
        f"it quit without error"
    )
    sys.exit(err_msg)


# def _fix_dot_space_chrom_name(chrom_name):
#     """Fix dots and spaces in the chrom name."""
#     dot_space_split = re.split(" |\.", chrom_name)
#     return dot_space_split[0]


def _check_and_fix_chrom_names(chrom_names, path):
    """Given list of chrom names, fix those with dots and spaces in names."""
    ret = {}  # old chrom name: new chrom name
    upd_cnames_qc = []  # to check whether all new chrom names are uniq
    for chrom_name in chrom_names:
        if " " in chrom_name or "\t" in chrom_name:
            # error, spaces and tabs are not allowed in chromosome names
            print(f"Error! File: {path} - detected space-or-tab-containing sequence:")
            print(f"{chrom_name}")
            print("Please exclude or fix sequences with spaces and tabs.\nAbort")
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
        upd_cnames_qc.append(upd_chrom_name)

    if len(upd_cnames_qc) != len(set(upd_cnames_qc)):
        print(f"Error! Some chromosome names in {path} contain dots and spaces")
        print(f"Could not fix names automatically: the process produces non-unique")
        print(f"chromosome names. Pls see README.md for details.")
        print("Abort.")
        sys.exit(1)
    return ret


def _check_chrom_names_in_fasta(fa_path):
    """Check whether chrom names contain dots or spaces in fasta."""
    with open(fa_path, "r") as f:
        chrom_names = [line.lstrip(">").rstrip() for line in f if line.startswith(">")]
    old_to_new_chrom_name = _check_and_fix_chrom_names(chrom_names, fa_path)
    return old_to_new_chrom_name


def rename_chromnames_fasta(genome_seq_file, tmp_dir, genome_id, invalid_chrom_names):
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

    # write renam table
    f = open(rename_table, "w")
    for k, v in invalid_chrom_names.items():
        f.write(f"{k}\t{v}\n")
    f.close()
    return renamed_fasta_path, rename_table


def call_twobitfa_subprocess(cmd, genome_seq_file):
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
        sys.stderr.write(err_msg)
        sys.exit(1)


def setup_genome(genome_seq_file, genome_id, tmp_dir, continue_arg):
    """Setup genome sequence input.

    DoBlastzChainNet procedure requires the 2bit-formatted sequence
    so create 2bit if the genome sequence is fasta-formatted.
    Also the procedure requires chrom.sizes file, which also needs
    to be satisfied."""
    # check whether genome sequence is twobit or fasta
    # afterwards, check whether there are valid chrom names
    # the pipeline cannot process chromosome names containing dots and spaces
    # Pls see the github issue about this:
    # https://github.com/hillerlab/make_lastz_chains/issues/3
    is_two_bit = __check_if_twobit(genome_seq_file)
    chrom_rename_table_path = None

    # genome seq path -> final destination of 2bit used for further pipeline steps
    if is_two_bit:
        # two bit -> if chrom names are intact, just use this file without
        # creating any intermediate files
        # otherwise, create intermediate fasta with fixed chrom names
        two_bit_reader = TwoBitFile(genome_seq_file)
        two_bit_chrom_names = list(two_bit_reader.sequence_sizes().keys())
        invalid_chrom_names = _check_and_fix_chrom_names(
            two_bit_chrom_names, genome_seq_file
        )
        if len(invalid_chrom_names) > 0:
            # there are invalid chrom names, that need to be renamed
            # (1) create intermediate fasta and rename chromosomes there
            fasta_dump_path = os.path.join(tmp_dir, f"TEMP_{genome_id}_genome_dump.fa")
            two_bit_to_fa = stat_kent_exec(TWOBITTOFA)
            fa_to_two_bit = stat_kent_exec(FATOTWOBIT)
            twobittofa_cmd = f"{two_bit_to_fa} {genome_seq_file} {fasta_dump_path}"
            call_twobitfa_subprocess(twobittofa_cmd, genome_seq_file)
            genome_seq_file, chrom_rename_table_path = rename_chromnames_fasta(
                fasta_dump_path, tmp_dir, genome_id, invalid_chrom_names
            )
            genome_seq_path = os.path.abspath(
                os.path.join(tmp_dir, f"{genome_id}.2bit")
            )
            os.remove(fasta_dump_path)
            # (2) create 2bit with renamed sequences
            fatotwobit_cmd = f"{fa_to_two_bit} {genome_seq_file} {genome_seq_path}"
            call_twobitfa_subprocess(fatotwobit_cmd, genome_seq_file)
        else:
            # no invalid chrom names, use 2bit as is
            genome_seq_path = os.path.abspath(genome_seq_file)
    else:
        # fasta, need to convert fasta to 2bit
        invalid_chrom_names = _check_chrom_names_in_fasta(genome_seq_file)
        if len(invalid_chrom_names) > 0:
            # there are invalid chrom names:
            # create temp fasta with renamed chroms -> use it to produce 2bit file
            # create rename table -> to track chrom name changes
            # update genomes seq file then -> use it as src to create twobit
            genome_seq_file, chrom_rename_table_path = rename_chromnames_fasta(
                genome_seq_file, tmp_dir, genome_id, invalid_chrom_names
            )

        genome_seq_path = os.path.abspath(os.path.join(tmp_dir, f"{genome_id}.2bit"))
        fa_to_two_bit = stat_kent_exec(FATOTWOBIT)
        cmd = f"{fa_to_two_bit} {genome_seq_file} {genome_seq_path}"
        call_twobitfa_subprocess(cmd, genome_seq_file)

    # now need to create chrom.sizes file
    chrom_sizes_fname = f"{genome_id}.chrom.sizes"
    chrom_sizes_path = os.path.join(tmp_dir, chrom_sizes_fname)

    # must be without errors now
    two_bit_reader = TwoBitFile(genome_seq_path)
    twobit_seq_to_size = two_bit_reader.sequence_sizes()

    f = open(chrom_sizes_path, "w")
    for k, v in twobit_seq_to_size.items():
        f.write(f"{k}\t{v}\n")
    f.close()

    if len(invalid_chrom_names) > 0:
        print(f"Warning! Genome sequence file {genome_seq_file}")
        print(
            f"{len(invalid_chrom_names)} chromosome names cannot be processed via pipeline"
        )
        print(
            f"were renamed in the intermediate files according to {chrom_rename_table_path}"
        )
    return genome_seq_path, chrom_sizes_path, chrom_rename_table_path


def check_env():
    """Check that all necessary environment variables are set."""
    # TODO: this func
    pass


def write_def_file(def_dct, project_dir, force, continue_arg):
    """Write DEF file to the project dir."""
    def_path = os.path.join(project_dir, "DEF")
    # >>>> This functionality moved to get project dir function
    # if os.path.isfile(def_path) and force is False:
    #     print(f"Confusion: {def_path} already exists")
    #     print(f"Please set --force_def to override")
    #     sys.exit(1)
    if continue_arg:
        # it is already written
        return def_path
    now = dt.now()
    f = open(def_path, "w")
    f.write("### Make chains properties\n")
    f.write(f"# The file generated automatically by make_chains.py on {now}\n\n")
    for k, v in def_dct.items():
        f.write(f"{k}={v}\n")
    f.close()
    return def_path


def make_executable(path):
    """Like chmod +x.

    Taken from
    https://stackoverflow.com/questions/12791997/how-do-you-do-a-simple-chmod-x-from-within-python
    """
    mode = os.stat(path).st_mode
    mode |= (mode & 0o444) >> 2  # copy R bits to X
    os.chmod(path, mode)


def run_do_chains_pl(def_path, project_dir, executor, args):
    """Run doLastzChain.pl"""
    do_blastz_exe = os.path.join(HERE, DO_LASTZ_DIR, DO_LASTZ_EXE)
    cmd = (
        f"{do_blastz_exe} {def_path} -clusterRunDir {project_dir} --executor {executor}"
    )
    # additional params to doLastzChains script:
    if args.executor_queuesize:
        cmd += f" --queueSize {args.executor_queuesize}"
    if args.executor_partition:
        cmd += f" --cluster_partition {args.executor_partition}"
    if args.cluster_parameters:
        cmd += f' --clusterOptions "{args.cluster_parameters}"'
    if args.continue_arg:
        cmd += f" --continue {args.continue_arg}"

    # if args.continue:/..

    # additional params to doLastzChains script
    # add logging
    log_file = os.path.join(project_dir, "make_chains.log")
    cmd += f" 2>&1 | tee -a {log_file}"

    script_loc = os.path.join(project_dir, MASTER_SCRIPT)

    do_lastz_env = os.path.join(HERE, DO_LASTZ_DIR)
    hl_scripts_env = os.path.join(HERE, HL_SCRIPTS)
    hl_kent_env = os.path.join(HERE, HL_KENT_BINARIES)
    kent_env = os.path.join(HERE, KENT_BINARIES)
    genome_ali_anv = os.path.join(HERE, GENOME_ALIGNMENT_TOOLS)

    now = dt.now()

    f = open(script_loc, "w")
    f.write("#!/bin/bash\n")  # TODO: check if it's fine
    f.write("### Make chains master script\n")
    f.write(f"# Antomatically generated by make_chains.py on {now}\n\n")

    # define env variables: they contain necessary executables
    f.write(f"export PATH={do_lastz_env}:$PATH\n")
    f.write(f"export PATH={hl_scripts_env}:$PATH\n")
    f.write(f"export PATH={hl_kent_env}:$PATH\n")
    f.write(f"export PATH={kent_env}:$PATH\n")
    f.write(f"export PATH={genome_ali_anv}:$PATH\n")
    f.write("\n")

    f.write(f"{cmd}\n")

    f.close()
    make_executable(script_loc)
    print(f"Calling: {script_loc}...")
    rc = subprocess.call(script_loc, shell=True)
    if rc != 0:
        print(f"Error! The script {script_loc} failed")
        sys.exit(rc)


def include_cmd_def_opts(def_params, args):
    """If user set some DEF parameters through the cmd, set them."""
    # update params if set by user, otherwise keep what it was before
    def_params["SEQ1_CHUNK"] = (
        args.seq1_chunk if args.seq1_chunk else def_params["SEQ1_CHUNK"]
    )
    def_params["SEQ2_CHUNK"] = (
        args.seq2_chunk if args.seq2_chunk else def_params["SEQ2_CHUNK"]
    )
    def_params["BLASTZ_H"] = args.blastz_h if args.blastz_h else def_params["BLASTZ_H"]
    def_params["BLASTZ_Y"] = args.blastz_y if args.blastz_y else def_params["BLASTZ_Y"]
    def_params["BLASTZ_L"] = args.blastz_l if args.blastz_l else def_params["BLASTZ_L"]
    def_params["BLASTZ_K"] = args.blastz_k if args.blastz_k else def_params["BLASTZ_K"]
    def_params["FILL_PREPARE_MEMORY"] = (
        args.fill_prepare_memory
        if args.fill_prepare_memory
        else def_params["FILL_PREPARE_MEMORY"]
    )
    def_params["CHAININGMEMORY"] = (
        args.chaining_memory if args.chaining_memory else def_params["CHAININGMEMORY"]
    )
    def_params["CHAINCLEANMEMORY"] = (
        args.chain_clean_memory
        if args.chain_clean_memory
        else def_params["CHAINCLEANMEMORY"]
    )
    # TODO: add other params if need be


def dump_make_chains_params(args, wd):
    """Dump command line arguments to wd."""
    dct_args_repr = vars(args)
    params_path = os.path.join(wd, "make_chains_py_params.json")
    with open(params_path, "w") as f:
        json.dump(dct_args_repr, f, default=str)


def check_proj_dir_for_resuming(project_dir):
    """Check whether the project dir is valid for -continue."""
    def_path = os.path.join(project_dir, "DEF")
    ms_path = os.path.join(project_dir, MASTER_SCRIPT)
    if not os.path.isfile(ms_path) or not os.path.isfile(def_path):
        err_msg = (
            f"Error! Cannot resume the execution in the {project_dir} "
            f"dir:\nPlease make sure that {def_path} and {ms_path} exist."
        )
        sys.exit(err_msg)
    return ms_path


def _make_chrom_rename_dict(table):
    """Create new chrom name: old chrom name dict."""
    ret = {}
    if table is None:
        # empty dict is also good
        return ret
    f = open(table, "r")
    for line in f:
        ld = line.rstrip().split("\t")
        old_name = ld[0]
        new_name = ld[1]
        ret[new_name] = old_name
    f.close()
    return ret


def rename_chroms_in_chain(
    not_renamed_chain, renamed_chain_path, t_chrom_dct, q_chrom_dct
):
    """Rename chromosomes to original names in the output chains file."""
    in_f = open(not_renamed_chain, "r")
    out_f = open(renamed_chain_path, "w")
    for line in in_f:
        if not line.startswith("chain"):
            # not a header
            out_f.write(line)
            continue
        # this is a chain header
        header_fields = line.rstrip().split()
        # according to chain file specification fields 2 and 7 contain
        # target and query chromosome/scaffold names
        # 0 field - just the word chain
        t_name = header_fields[2]
        q_name = header_fields[7]

        t_upd = t_chrom_dct.get(t_name)
        q_upd = q_chrom_dct.get(q_name)

        if t_upd is None and q_upd is None:
            # those chromosomes were not renamed, keep line as is
            out_f.write(line)
            continue

        if t_upd:
            header_fields[2] = t_upd
        if q_upd:
            header_fields[7] = q_upd
        upd_header = " ".join(header_fields)
        out_f.write(f"{upd_header}\n")

    in_f.close()
    out_f.close()


def check_results(project_dir, t_rename_table, q_rename_table, args):
    """Check whether output chain file is present.

    If scaffolds were renamed -> return the original names.
    """
    chain_filename = f"{args.target_name}.{args.query_name}.allfilled.chain.gz"
    chain_path = os.path.join(project_dir, chain_filename)
    if not os.path.isfile(chain_path):
        print(f"Error!!! Output file {chain_path} not found!")
        print(
            "The pipeline crashed. Please contact developers by creating an issue at:"
        )
        print("https://github.com/hillerlab/make_lastz_chains")
        sys.exit(1)
    if t_rename_table is None and q_rename_table is None:
        return  # no need to rename chromosomes
    # there is need to rename chromosomes
    # unzip chain file, create temp chain file with renamed chromosomes/scaffolds
    # rename chromosomes
    print("Renaming chromosome names in the chain file")
    unzip_cmd = f"gunzip {chain_path}"
    subprocess.call(unzip_cmd, shell=True)
    unzipped_filename = f"{args.target_name}.{args.query_name}.allfilled.chain"
    unzipped_path = os.path.join(project_dir, unzipped_filename)
    renamed_chain_path = os.path.join(project_dir, "RENAMED.chain")
    t_chrom_dct = _make_chrom_rename_dict(t_rename_table)
    q_chrom_dct = _make_chrom_rename_dict(q_rename_table)
    rename_chroms_in_chain(unzipped_path, renamed_chain_path, t_chrom_dct, q_chrom_dct)
    # remove temp file and rename output file + gzip it
    os.remove(unzipped_path)
    shutil.move(renamed_chain_path, unzipped_path)
    zip_cmd = f"gzip -9 {unzipped_path}"
    subprocess.call(zip_cmd, shell=True)


def main():
    args = parse_args()
    check_env()
    project_dir = get_project_dir(args.project_dir, args.force_def, args.continue_arg)
    print(f"Project directory: {project_dir}")
    # if args.continue_arg:
    #     # the pipeline already been called -> resume execution
    #     # but first check that the request is valid
    #     ms_loc = check_proj_dir_for_resuming(project_dir)
    #     subprocess.call(ms_loc, shell=True)
    #     sys.exit(0)  # no need to continue

    # normal mode, generate DEF parameters from scratch and call the pipeline
    # TODO: if continue_arg is not None, all this data must be already known
    # no need to ask user to provide these
    def_parameters = generate_def_params(args.DEF, args.lastz)
    # define parameters inferred from input
    def_parameters["ref"] = args.target_name
    def_parameters["query"] = args.query_name

    # deal with input sequences, add respective parameters to def file
    t_path, t_sizes, t_rename_table = setup_genome(
        args.target_genome, args.target_name, project_dir, args.continue_arg
    )
    q_path, q_sizes, q_rename_table = setup_genome(
        args.query_genome, args.query_name, project_dir, args.continue_arg
    )
    print(f"Target path: {t_path} | chrom sizes: {t_sizes}")
    print(f"Query path: {q_path} | query sizes: {q_sizes}")

    def_parameters["SEQ1_DIR"] = t_path
    def_parameters["SEQ1_LEN"] = t_sizes
    def_parameters["SEQ2_DIR"] = q_path
    def_parameters["SEQ2_LEN"] = q_sizes

    include_cmd_def_opts(def_parameters, args)

    # write def path and run the script
    def_path = write_def_file(def_parameters, project_dir, args.force_def, args.continue_arg)
    dump_make_chains_params(args, project_dir)
    run_do_chains_pl(def_path, project_dir, args.executor, args)
    check_results(project_dir, t_rename_table, q_rename_table, args)


if __name__ == "__main__":
    main()
