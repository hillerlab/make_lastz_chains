#!/usr/bin/env python3
"""Build chains for a given pair of target and query genomes.

Based on Hillerlab solution doBlastzChainNet.pl
and UCSC Kent Source.
"""
import argparse
import sys
import os
import subprocess
from datetime import datetime as dt
from shutil import which
from twobitreader import TwoBitFile
from twobitreader import TwoBitFileError
from install_dependencies import Required


__author__ = "Bogdan Kirilenko, Michael Hiller, Ekaterina Osipova"  # TODO: anyone else?
__maintainer__ = "Bogdan Kirilenko"
__email__ = ""  # TODO: me or Michael?
__version__ = "0.9.1"

DESCRIPTION = "Build chains for a given pair of target and query genomes."
HERE = os.path.abspath(os.path.dirname(__file__))
FATOTWOBIT = "faToTwoBit"

# directories with all necessary scripts
DO_LASTZ_DIR = "doLastzChains"
DO_LASTZ_EXE = "doLastzChain.pl"
HL_SCRIPTS = "HL_scripts"
HL_KENT_BINARIES = "HL_kent_binaries"
KENT_BINARIES = "kent_binaries"


# defaults
SEQ1_CHUNK = 175_000_000
SEQ2_CHUNK = 50_000_000
BLASTZ_H = 2000
BLASTZ_Y = 9400
BLASTZ_L = 3000
BLASTZ_K = 2400

MASTER_SCRIPT = "master_script.sh"


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
    app.add_argument("--project_dir", help="Project directory. By default: pwd")
    app.add_argument(
        "--DEF",
        help="DEF formatted configuration file, please read README.md for details.",
    )
    app.add_argument(
        "--force_def",
        action="store_true",
        dest="force_def",
        help="Continue execution if DEF file in the project dir already exists",
    )
    app.add_argument(
        "--executor",
        default="local",
        help=(
            "Cluster jobs executor. Please see README.md to get "
            "a list of all available systems. Default local"
        ),
    )
    app.add_argument(
        "--resume",
        action="store_true",
        dest="resume",
        help=("Resume execution from the last completed step, "
              "Please specify existing --project_dir to use this option"
        )
    )

    # DEF file arguments that can be overriden
    # have higher priority than def file
    def_params = app.add_argument_group("def_params")
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
        help="CHAINCLEANMEMORY parameter, (default 100000)"
    )

    if len(sys.argv) < 2:
        app.print_help()
        sys.exit(0)

    args = app.parse_args()

    # >>> sanity checks
    resume_cond_1 = args.resume is True and args.project_dir is None
    resume_cond_2 = args.resume is True and not os.path.isdir(args.project_dir)

    if resume_cond_1 or resume_cond_2:
        err_msg = (
            "Error! --resume mode implies already existing project."
            "Please specify already existing project with --project_dir"
        )
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


def get_project_dir(dir_arg):
    """Define project directory."""
    if dir_arg is None:
        return os.path.abspath(os.getcwd())
    os.mkdir(dir_arg) if not os.path.isdir(dir_arg) else None
    return os.path.abspath(dir_arg)


def generate_def_params(def_arg):
    """Generate def file with default parameters.

    If DEF file is provided: override defined parameters.
    """
    # TODO: comments, maybe move some of them to README
    def_vals = {
        # lastz with sensitive alignment parameters
        "BLASTZ": "lastz",
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
        ## cluster related
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


def stat_fa_to_two_bit():
    """Find faToTwoBit executable."""
    fatotwobit_exe = which(FATOTWOBIT)
    if fatotwobit_exe:
        return fatotwobit_exe
    # ok, faToTwoBit is not in the $PATH
    fa_to_two_bit_loc = os.path.join(HERE, KENT_BINARIES, FATOTWOBIT)
    if os.path.isfile(fa_to_two_bit_loc):
        # found it in the KENT_BINARIES
        return fa_to_two_bit_loc
    # not found fatotwobit_exe
    err_msg = (
        f"Error! Cannot stat faToTwoBit: "
        f"nether in $PATH nor in {fa_to_two_bit_loc}\n"
        f"Please make sure you called ./install_dependencies.py and "
        f"it quit without error"
    )
    sys.exit(err_msg)
    

def setup_genome(genome_seq_file, genome_id, tmp_dir):
    """Setup genome sequence input.

    DoBlastzChainNet procedure requires the 2bit-formatted sequence
    so create 2bit if the genome sequence is fasta-formatted.
    Also the procedure requires chrom.sizes file, which also needs
    to be satisfied."""
    # check whether genome sequence is twobit or fasta
    is_two_bit = __check_if_twobit(genome_seq_file)
    if is_two_bit:
        # no need to create any copies etc, just use this file
        genome_seq_path = os.path.abspath(genome_seq_file)
    else:
        # need to convert fasta to 2bit
        genome_seq_src_fname = f"{genome_id}.2bit"
        genome_seq_path = os.path.abspath(os.path.join(tmp_dir, genome_seq_src_fname))
        fa_to_two_bit = stat_fa_to_two_bit()
        cmd = f"{fa_to_two_bit} {genome_seq_file} {genome_seq_path}"
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

    return genome_seq_path, chrom_sizes_path


def check_env():
    """Check that all necessary environment variables are set."""
    # TODO: this func
    pass


def write_def_file(def_dct, project_dir, force):
    """Write DEF file to the project dir."""
    def_path = os.path.join(project_dir, "DEF")
    if os.path.isfile(def_path) and force is False:
        print(f"Confusion: {def_path} already exists")
        print(f"Please set --force_def to override")
        sys.exit(1)
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


def run_do_chains_pl(def_path, project_dir, executor):
    """Run doLastzChain.pl"""
    do_blastz_exe = os.path.join(HERE, DO_LASTZ_DIR, DO_LASTZ_EXE)
    cmd = (
        f"{do_blastz_exe} {def_path} -clusterRunDir {project_dir} --executor {executor}"
    )
    script_loc = os.path.join(project_dir, MASTER_SCRIPT)

    do_lastz_env = os.path.join(HERE, DO_LASTZ_DIR)
    hl_scripts_env = os.path.join(HERE, HL_SCRIPTS)
    hl_kent_env = os.path.join(HERE, HL_KENT_BINARIES)
    kent_env = os.path.join(HERE, KENT_BINARIES)

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
    f.write("\n")

    f.write(f"{cmd}\n")

    f.close()
    make_executable(script_loc)
    print(f"Calling: {script_loc}...")
    subprocess.call(script_loc, shell=True)
    # that's it?


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
        args.chaining_memory
        if args.chaining_memory
        else def_params["CHAININGMEMORY"]
    )
    def_params["CHAINCLEANMEMORY"] = (
        args.chain_clean_memory
        if args.chain_clean_memory
        else def_params["CHAINCLEANMEMORY"]
    )
    # TODO: add other params if need be


def check_proj_dir_for_resuming(project_dir):
    """Check whether the project dir is valid for -resume."""
    def_path = os.path.join(project_dir, "DEF")
    ms_path = os.path.join(project_dir, MASTER_SCRIPT)
    if not os.path.isfile(ms_path) or not os.path.isfile(def_path):
        err_msg = (
            f"Error! Cannot resume the execution in the {project_dir} "
            f"dir:\nPlease make sure that {def_path} and {ms_path} exist."
        )
        sys.exit(err_msg)
    return ms_path


def main():
    args = parse_args()
    check_env()
    project_dir = get_project_dir(args.project_dir)
    print(f"Project directory: {project_dir}")
    if args.resume: 
        # the pipeline already've been called -> resume execution
        # but first check that the request is valid
        ms_loc = check_proj_dir_for_resuming(project_dir)
        subprocess.call(ms_loc, shell=True)
        sys.exit(0)  # no need to continue

    def_parameters = generate_def_params(args.DEF)
    # define parameters inferred from input
    def_parameters["ref"] = args.target_name
    def_parameters["query"] = args.query_name

    # deal with input sequences, add respective parameters to def file
    t_path, t_sizes = setup_genome(args.target_genome, args.target_name, project_dir)
    q_path, q_sizes = setup_genome(args.query_genome, args.query_name, project_dir)
    print(f"Target path: {t_path} | chrom sizes: {t_sizes}")
    print(f"Query path: {q_path} | query sizes: {q_sizes}")

    def_parameters["SEQ1_DIR"] = t_path
    def_parameters["SEQ1_LEN"] = t_sizes
    def_parameters["SEQ2_DIR"] = q_path
    def_parameters["SEQ2_LEN"] = q_sizes

    include_cmd_def_opts(def_parameters, args)

    # write def path and run the script
    def_path = write_def_file(def_parameters, project_dir, args.force_def)
    run_do_chains_pl(def_path, project_dir, args.executor)


if __name__ == "__main__":
    main()
