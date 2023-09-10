#!/usr/bin/env python3
"""Run lastz.

Replacement for blastz-run-ucsc.
"""
import argparse
import os
import sys
import subprocess
from subprocess import PIPE
import shutil
import string
import random
import json
from twobitreader import TwoBitFile


__author__ = "Bogdan Kirilenko, 2022"
__email__ = "Bogdan.Kirilenko@senckenberg.de"


BLASTZ_PREFIX = "lastz_"
FORMAT_ARG = "--format=axt+"
ALLOC_ARG = "--traceback=800.0M"

"""Run lastz example:
/beegfs/software/lastz/lastz-1.04.15/lastz tParts/part000.2bit[multiple] /tmp/blastz.asiAtt/part000.2bit 
K=2400 H=2000 L=3000 Y=9400  --format=axt+ > /tmp/blastz.asiAtt/little.raw

Run blastz-run-ucsc example:
blastz-run-ucsc
-outFormat psl
/Users/krlnk/Developer/chains_builder/quick_test/hg38.chrM.2bit:chrM:0-500
/Users/krlnk/Developer/chains_builder/quick_test/mm10.chrM.2bit:chrM:0-15000
../DEF
/Users/krlnk/Developer/chains_builder/temp/TEMP_psl/hg38.chrM.2bit:chrM:0-5000/
    hg38.chrM.2bit:chrM:0-5000_mm10.chrM.2bit:chrM:0-15000.psl

Example command tested on macBook:
lastz "quick_test/hg38.chrM.2bit/chrM[100,5000][multiple]" 
"quick_test/mm10.chrM.2bit/chrM[100,5000][multiple]"
--format=axt+ K=2400 H=2000 L=3000 Y=9400

Just need to call this and that's all, no need for temp input files I guess

Bogdan: probably it makes sense to also add
--allocate=800M
"""


def _gen_random_string(n):
    return ''.join(random.SystemRandom().choice(string.ascii_uppercase + string.digits) for _ in range(n))


def print_err(msg):
    sys.stderr.write(msg)
    sys.stderr.write("\n")


def parse_args():
    """Parse arguments."""
    app = argparse.ArgumentParser()
    app.add_argument("target", help="Target: single sequence file or .lst")
    app.add_argument("query", help="Query: single sequence file or .lst")
    app.add_argument("params_json", help="pipeline configuration file")
    app.add_argument("output", help="Output file location")

    app.add_argument("--output_format", choices=["psl", "axt"], help="Output format axt|psl")
    app.add_argument("--gz", help="Compress output with gzip")
    app.add_argument("--temp_dir",
                     help="Temp directory to save intermediate fasta files (if needed)\n"
                          "/tmp/ is default, however, params_json key TMPDIR can provide a value"
                          "the command line argument has a higher priority than DEF file"
                    )
    app.add_argument("--verbose",
                     "-v",
                     action="store_true",
                     dest="verbose",
                     help="Show verbosity messages")

    if len(sys.argv) < 5:
        app.print_help()
        sys.exit(0)
    args = app.parse_args()
    return args


def clean_die(tmp_dir, msg):
    shutil.rmtree(tmp_dir) if os.path.isdir(tmp_dir) else None
    sys.stderr.write(f"{msg}\n")
    sys.exit(1)


def read_json_file(file_path):
    with open(file_path, 'r') as f:
        return json.load(f)


def read_chrom_sizes(chrom_sizes):
    """Read chrom.sizes file."""
    ret = {}
    f = open(chrom_sizes, "r")
    for line in f:
        ld = line.rstrip().split("\t")
        ret[ld[0]] = int(ld[1])
    f.close()
    return ret


def get_temp_dir(tmp_dir_param):
    """Get temp directory."""
    rnd_suff = _gen_random_string(8)
    tmp_dirname = f"blastz.{rnd_suff}"

    if tmp_dir_param:
        if not os.path.isdir(tmp_dir_param):
            raise ValueError(f"TMPDIR parameter {tmp_dir_param} not a dir")
        tmp_path = os.path.abspath(os.path.join(tmp_dir_param, tmp_dirname))
    else:
        tmp_path = os.path.abspath(os.path.join("/tmp", tmp_dirname))
    os.mkdir(tmp_path) if not os.path.isdir(tmp_path) else None
    return tmp_path


def define_if_not(dct, key, val):
    if not dct.get(key):
        dct[key] = val
    else:
        pass


def get_blastz_params(def_vals):
    params_lst = []
    for k, v in def_vals.items():
        if not k.startswith(BLASTZ_PREFIX):
            continue
        lastz_key = k.replace(BLASTZ_PREFIX, "").upper()
        kv_pair = f"{lastz_key}={v}"
        params_lst.append(kv_pair)
    params_line = " ".join(params_lst)
    return params_line


def parse_file_spec(filename):
    """For a given filename return file specifications.
    
    Such as sequence name (chrom), start and end.
    """
    if len(filename.split(":")) == 1:
        # if no filespecs?
        # this is a collapsed fasta, for instance
        return filename, None, None, None
    base = os.path.basename(filename)
    path_bare = filename.split(":")[0]
    _, seq_id, start_end_str = base.split(":")
    start_end_str_split = start_end_str.split("-")
    start = int(start_end_str_split[0])
    end = int(start_end_str_split[1])
    return path_bare, seq_id, start, end


def call_process(cmd):
    subprocess.call(cmd, shell=True)


def build_lastz_command(t_specs, q_specs, blastz_options):
    # print(t_specs, q_specs, blastz_options)
    t_path, t_chrom, t_start, t_end = t_specs
    q_path, q_chrom, q_start, q_end = q_specs
    """http://www.bx.psu.edu/miller_lab/dist/README.lastz-1.02.00/
    README.lastz-1.02.00a.html#options_where
    
    Subrange indices begin with 1 and are inclusive
    (i.e., they use the origin-one, closed position numbering system).
    For example, 201..300 is a 100-bp subrange that skips the first 200 bp in the sequence.

    Whatever it means.
    """
    if all(x is not None for x in t_specs):
        # if specs (chrom, start and end) are specified: feed them to lastz
        target_arg = f"\"{t_path}/{t_chrom}[{t_start + 1},{t_end}][multiple]\""
    else:  # not specified: do not add, quite simple
        target_arg = f"\"{t_path}[multiple]\""
    if all(x is not None for x in q_specs):
        # the same applies to query sequences
        query_arg = f"\"{q_path}/{q_chrom}[{q_start + 1},{q_end }][multiple]\""
    else:  # no specs: get entire file
        query_arg = f"\"{q_path}[multiple]\""
    fields = ("lastz", target_arg, query_arg, blastz_options, ALLOC_ARG, FORMAT_ARG)
    return " ".join(fields)


def call_lastz(cmd):
    lastz_out = subprocess.check_output(cmd, shell=True).decode("utf-8")
    return lastz_out


def make_psl_if_needed(raw_out, out_format, s1p, s2p, v):
    """Convert lastz output to psl if needed."""
    if out_format == "axt":
        return raw_out  # it's already AXT
    # need to convert to PSL
    # print(raw_out)
    
    axt_to_psl_cmd = ["axtToPsl", "/dev/stdin", s1p, s2p, "stdout"]
    _cmd_plain = " ".join(axt_to_psl_cmd)
    v(f"Running: {_cmd_plain}")
    p = subprocess.Popen(axt_to_psl_cmd, stdout=PIPE, stderr=PIPE, stdin=PIPE)
    stdout_, stderr_ = p.communicate(input=raw_out.encode())
    stdout = stdout_.decode("utf-8")
    stderr = stderr_.decode("utf-8")
    rc = p.returncode
    if rc != 0:
        print("AXTTOPSL COMMAND CRASHED")
        print(stderr)
        # p.terminate()  # also not needed?
        sys.exit(2)
    return stdout


def parse_seq_arg(arg, tmp_dir, v):
    """Parse target or query argument.
    
    If it's just a .2bit -> keep it.
    If a .lst:
        if single element -> return it
        if multiple -> merge to a single fasta file.
    If merged fasta: second ag is True
    """
    if not arg.endswith(".lst"):
        # not a .lst -> just return it
        v(f"Arg {arg} doesnt end with .lst")
        return arg
    v(f"### Arg {arg} ends with lst: collapsing...")
    with open(arg, "r") as f:
        # a list of 2bits: need to read it
        content = [x.rstrip() for x in f.readlines()]
    num_elems = len(content)
    if num_elems == 1:
        # a single element in the list -> return it
        single_elem = content[0]
        v(f"List contains a single element: {single_elem}")
        return single_elem
    v(f"List contains multiple elements ({num_elems})")
    # multiple elements
    # need to collapse them into a single fasta file
    # then output the path to this temp fasta
    temp_input_filename = f"{_gen_random_string(8)}_collapsed.fa"
    fasta_path = os.path.join(tmp_dir, temp_input_filename)
    v(f"# Saving collapsed fasta to: {fasta_path}")

    f = open(fasta_path, "w")
    for elem in content:
        print(f"   # Saving elem: {elem}")
        path_specs_split = elem.split(":")
        path = path_specs_split[0]
        chrom = path_specs_split[1]
        # extract the chrom sequence from 2bit
        two_bit_conn = TwoBitFile(path)
        chrom_seq = two_bit_conn[chrom]
        f.write(f">{chrom}\n{chrom_seq}\n")
    f.close()
    return fasta_path


def check_temp_is_needed(t, q):
    if t.endswith(".lst") or q.endswith(".lst"):
        return True
    return False


def verbose_msg(msg):
    sys.stderr.write(f"{msg}\n")


def main():
    """Entry point."""
    args = parse_args()
    # not orthodox solution but...
    v = verbose_msg if args.verbose else lambda x: None
    pipeline_params = read_json_file(args.params_json)
    seq_1_sizes_path = pipeline_params["seq_1_len"]
    seq_2_sizes_path = pipeline_params["seq_2_len"]
    temp_is_needed = check_temp_is_needed(args.target, args.query)
    # create temp dir iff input contains .lst files
    tmp_dir = get_temp_dir(pipeline_params.get("temp_dir")) if temp_is_needed else None
    tmp_dir = args.temp_dir if args.temp_dir else tmp_dir

    v(f"Temp directory is needed: {temp_is_needed}: {tmp_dir}")
    target_seqs = parse_seq_arg(args.target, tmp_dir, v)
    query_seqs = parse_seq_arg(args.query, tmp_dir, v)
    v(f"Target: {target_seqs} | Query: {query_seqs}")

    # parse input files ranges (if present)
    target_specs = parse_file_spec(target_seqs)
    query_specs = parse_file_spec(query_seqs)
    v(f"Target specs: {target_specs} | Query specs: {query_specs}")

    define_if_not(pipeline_params, "lastz_h", 2000)
    blastz_options = get_blastz_params(pipeline_params)
    v(f"LASTZ options: {blastz_options}")

    cmd = build_lastz_command(target_specs, query_specs, blastz_options)
    v(f"Lastz command: {cmd}")
    lastz_output = call_lastz(cmd)
    out_to_save = make_psl_if_needed(lastz_output, args.output_format, seq_1_sizes_path, seq_2_sizes_path, v)
    f = open(args.output, "w")
    f.write(out_to_save)
    f.close()

    # remove temp file if was used
    if temp_is_needed:
        shutil.rmtree(tmp_dir) if os.path.isdir(tmp_dir) else None


if __name__ == '__main__':
    main()
