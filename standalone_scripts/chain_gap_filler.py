#!/usr/bin/env python3
"""
Takes chain or chainIDs as input.
For each chain, the script finds a gap of a certain size,
runs a local lastz job, since the resulting alignments can overlap, chains them.
Selects the best 'mini-chain' and directly adds this into the gap.
Then continues iterating.
"""

import sys
import os
import subprocess
import argparse
import logging
import re
import time
import tempfile


__author__ = "Ekaterina Osipova, MPI-CBG/MPI-PKS, 2018."
# refactored by Bogdan M. Kirilenko, September 2023


def parse_args():
    """Builds an argument parser with all required and optional arguments."""
    # initializes parameters
    parser = argparse.ArgumentParser(
        description=("This script extracts a chain from all.chain file by ID, "
                     "finds gaps and using lastz patches these gaps, "
                     "then inserts new blocks to a chain"),
        epilog=("Example of use:\nchain_gap_filler.py -c hg38.speTri2.all.chain "
                "-ix hg38.speTri2.all.bb -T2 hg38.2bit "
                "-Q2 speTri2.2bit -um -m mini.chains -o out.chain"),
    )
    # Required arguments
    required_named = parser.add_argument_group("required named arguments")
    required_named.add_argument(
        "--chain", "-c", type=str, help="all.chain file", required=True
    )
    required_named.add_argument(
        "--T2bit", "-T2", type=str, help="reference 2bit file", required=True
    )
    required_named.add_argument(
        "--Q2bit", "-Q2", type=str, help="query 2bit file", required=True
    )
    parser.add_argument(
        "--lastz",
        "-l",
        type=str,
        default="lastz",
        help="path to lastz executable, default = lastz",
    )
    parser.add_argument(
        "--axtChain",
        "-x",
        type=str,
        default="axtChain",
        help="path to axtChain executable, default = axtChain",
    )
    parser.add_argument(
        "--chainSort",
        "-s",
        type=str,
        default="chainSort",
        help="path to chainSort executable, default = chainSort",
    )
    parser.add_argument(
        "--output",
        "-o",
        type=str,
        help="name of output chain file. If not specified chains go to stdout",
    )
    parser.add_argument(
        "--workdir",
        "-w",
        type=str,
        default="./",
        help="working directory for temp files, default = ./",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="if -v is not specified, only ERROR messages will be shown",
    )

    # Initial parameters
    parser.add_argument(
        "--chainMinScore",
        "-mscore",
        type=int,
        default=0,
        help="consider only chains with a chainMinScore, default consider all",
    )
    parser.add_argument(
        "--chainMinSizeT",
        "-mst",
        type=int,
        default=0,
        help="consider only chains with a chainMinSizeT, default consider all",
    )
    parser.add_argument(
        "--chainMinSizeQ",
        "-msq",
        type=int,
        default=0,
        help="consider only chains with a chainMinSizeQ, default consider all",
    )
    parser.add_argument(
        "--gapMinSizeT",
        "-gmint",
        type=int,
        default=10,
        help="patch only gaps that are at least that long on the target side, default gmint = 10",
    )
    parser.add_argument(
        "--gapMinSizeQ",
        "-gminq",
        type=int,
        default=10,
        help="patch only gaps that are at least that long on the query side, default gminq = 10",
    )
    parser.add_argument(
        "--gapMaxSizeT",
        "-gmaxt",
        type=int,
        default=100000,
        help="patch only gaps that are at most that long on the target side, default gmaxt = 100000",
    )
    parser.add_argument(
        "--gapMaxSizeQ",
        "-gmaxq",
        type=int,
        default=100000,
        help="patch only gaps that are at most that long on the query side, default gmaxq = 100000",
    )
    parser.add_argument(
        "--lastzParameters",
        "-lparam",
        type=str,
        default=" K=1500 L=2000 M=0 T=0 W=6 ",
        help="line with lastz parameters, default 'K=1500 L=2000 M=0 T=0 W=6' ",
    )
    parser.add_argument(
        "--unmask",
        "-um",
        action="store_true",
        help="unmasking (lower case to upper case) characters from the 2bit files",
    )
    parser.add_argument(
        "--scoreThreshold",
        "-st",
        type=int,
        default=2000,
        help="insert only chains that have at least this score, default st = 2000",
    )
    parser.add_argument("--index", "-ix", type=str, help="index.bb file for chains")

    if len(sys.argv) < 2:
        parser.print_help()
        sys.exit(1)

    args = parser.parse_args()
    if args.verbose:
        logging.basicConfig(level=logging.INFO)
    return args


def get_chain_string(args):
    """Extracts chains with requested ids from "all.chain" file.

    get chains; either iterate over batches of chains or extract single chain string
    """
    try:
        with open(args.chain, "r") as content_file:
            current_chain_string = content_file.read()
    except IOError as e:
        logging.error(
            f"Cannot read chain file {e.errno} {e.strerror}"
        )
        sys.exit(1)
    return current_chain_string


def make_shell_list(input_chain, out_file, args):
    """Makes a list of jobs to run in temp shell script.

    inChain: string containing all chains
    out_file: path to output file; shell commands will be written into this file
    """
    try:
        out_file_handler = open(out_file, "w")
    except IOError as e:
        logging.error(f"Cannot write to shell script: {e.errno} {e.strerror}")
        sys.exit(1)

    # write a header for the shell script
    out_file_handler.write("#!/usr/bin/env bash\n")
    out_file_handler.write("#set -o pipefail\n")
    out_file_handler.write("#set -e\n")

    # count gaps patched in this file
    gap_count = 0

    # numbers for tracking the line number
    line_number = 0

    # two bit files
    target_two_bit = args.T2bit
    query_two_bit = args.Q2bit

    lastz_arg = args.lastz
    axt_chain_arg = args.axtChain
    chain_sort_arg = args.chainSort

    # put chain string into a list
    # TODO: to refactor this part
    chain_list = iter([f"{chain_line}\n" for chain_line in input_chain.split("\n")])

    # change to access by index
    for line in chain_list:
        line_number += 1

        ll = line.split()
        if len(ll) > 0:
            if ll[0] == "chain":
                # read the chain line:
                # e.g. chain 196228 chr4 62094675 + 12690854 12816143 chr23 24050845 - 20051667 20145391 1252
                score = int(ll[1])
                t_name, t_start, t_end = ll[2], int(ll[5]), int(ll[6])
                q_name, q_start_x, q_end_x, q_strand = ll[7], int(ll[10]), int(ll[11]), ll[9]
                q_size = int(ll[8])
                logging.info(f"q_strand = {q_strand}")
                # changing coords for -strand if necessary

                q_start = q_start_x
                q_end = q_end_x
                lastz_parameters = args.lastzParameters + " --strand=plus"

                if q_strand == "-":
                    lastz_parameters = args.lastzParameters + " --strand=minus"

                if ll[4] != "+":
                    logging.error(
                        f"ERROR: target strand is not + for chain:{line}"
                    )
                    sys.exit(1)
                # check if we consider this chain
                logging.info(f"score of this chain = {score}")
                if (
                        (score >= args.chainMinScore)
                        and (t_end - t_start >= args.chainMinSizeT)
                        and (q_end - q_start >= args.chainMinSizeQ)
                ):
                    logging.info("valid chain")
                    current_t_position = t_start
                    current_q_position = q_start

                    line = next(chain_list)
                    line_number += 1

                    while re.match(r"^\d+", line) is not None:
                        a = line.split()
                        if len(a) == 1:
                            # t_block_end = current_t_position + int(a[0])
                            # q_block_end = current_q_position + int(a[0])
                            logging.info("it was the last block\n")

                        else:
                            block_len = int(a[0])
                            t_block_end = current_t_position + block_len
                            q_block_end = current_q_position + block_len
                            t_gap_end = current_t_position + block_len + int(a[1])
                            q_gap_end = current_q_position + block_len + int(a[2])
                            t_gap_span = t_gap_end - t_block_end
                            q_gap_span = q_gap_end - q_block_end
                            # check if we want to patch this gap
                            if (
                                    (t_gap_span >= args.gapMinSizeT)
                                    and (t_gap_span <= args.gapMaxSizeT)
                                    and (q_gap_span >= args.gapMinSizeQ)
                                    and (q_gap_span <= args.gapMaxSizeQ)
                            ):
                                logging.info(f"yes, this gap will be patched: {line}")
                                t_block_end += 1
                                q_block_end += 1

                                # replace the content of the unmask by '[unmask]'
                                # if the user sets this flag, otherwise ''
                                if args.unmask:
                                    unmask = "[unmask]"
                                else:
                                    unmask = ""

                                if q_strand == "-":
                                    real_q_block_end = q_size - q_gap_end + 1
                                    real_q_gap_end = q_size - q_block_end + 1
                                else:
                                    real_q_block_end = q_block_end
                                    real_q_gap_end = q_gap_end

                                logging.info("running lastz on the block:")
                                region_to_be_patched = [
                                    t_name,
                                    str(t_block_end),
                                    str(t_gap_end),
                                    q_name,
                                    str(real_q_block_end),
                                    str(real_q_gap_end),
                                ]
                                logging.info(" ".join(region_to_be_patched))

                                # making lastz command for this region
                                command_1 = (
                                    f"{target_two_bit}/{t_name}[{t_block_end}..{t_gap_end}]{unmask} "
                                    f"{query_two_bit}/{q_name}[{real_q_block_end}..{real_q_gap_end}]{unmask} "
                                    f"--format=axt {lastz_parameters} | "
                                )
                                command_2 = (
                                    f"-linearGap=loose stdin {target_two_bit} {query_two_bit} stdout 2> /dev/null | "
                                )
                                command_3 = "stdin stdout"
                                command_lastz = (
                                    f"{lastz_arg}{command_1}{axt_chain_arg}"
                                    f"{command_2}{chain_sort_arg}{command_3}"
                                )

                                # adding this lastz run to a shell command list; line_number - 1 because we start
                                # with 1 and later with 0
                                shell_command = (
                                    f'echo -e "LINE{line_number - 1}\\n{block_len}\\n{t_block_end}\\n{t_gap_end}\\n'
                                    f'{real_q_block_end}\\n{real_q_gap_end}\\n"; {command_lastz}; '
                                    f'echo -e "LINE{line_number - 1}\\n"\n')

                                out_file_handler.write(shell_command)

                            current_q_position = q_gap_end
                            current_t_position = t_gap_end

                        # get next line, break if no more line in string
                        try:
                            line = next(chain_list)
                            line_number += 1
                        except StopIteration:
                            break
                else:
                    logging.info("invalid chain\n")

                    # save chain header line; get next line
                    line = next(chain_list)
                    line_number += 1

                    # read the rest of the chain store blocks
                    while re.match(r"^\d+", line) is not None:
                        try:
                            line = next(chain_list)
                            line_number += 1
                        except StopIteration:
                            break

    logging.info("Done with reading gaps")
    logging.info(f"Gaps patched in this chain = {gap_count}")
    logging.info("\n")
    logging.info("\n")

    # close file handler
    out_file_handler.close()


def make_shell_jobs(args, current_chain_string):
    """Makes a temp file with a jobList."""
    if not os.path.isdir(args.workdir):
        logging.error(f"ERROR! Working directory {args.workdir} does not exist.")
        sys.exit(1)

    # create temp file
    try:
        temp = tempfile.NamedTemporaryFile(
            prefix="tempCGFjobList", dir=args.workdir, delete=False
        )
        temp.close()
    except PermissionError as e:
        logging.error(
            f"ERROR! Failed to create temporary file inside '{args.workdir}'. {e.errno} {e.strerror}"
        )
        sys.exit(1)

    # Find gaps and write corresponding jobs to a shell script
    make_shell_list(current_chain_string, temp.name, args)
    return temp


def run_all_shell(shell_file):
    """Takes temp file with all shell commands to run and returns lastz output in a single string."""
    all_shell_command = f"bash {shell_file}"
    try:
        all_mini_chains = subprocess.check_output(all_shell_command, shell=True)

        """
        # for debugging write all mini chains to a file
        with open("allminifile", 'w') as f:
            all_mini_chainsStr = all_mini_chains.decode()
            for el in all_mini_chainsStr.split('\n'):
                f.write(el)
                f.write('\n')
        """

    except subprocess.CalledProcessError as shell_run:
        logging.error("shell command failed", shell_run.returncode, shell_run.output)
        sys.exit(1)

    all_mini_chains = all_mini_chains.decode()
    return all_mini_chains


def get_chain_block_from_lastz_output(all_mini_chains_split, cur_position):
    """
    Takes the whole lastz output chain list and return list containing chain block starting at cur_position

    (line_number: [block_len, TblockEnd, t_gap_end, real_q_block_end, real_q_gap_end, 'all_chains_strings'])
    from LINE# to LINE#
    returns a dictionary

    all_mini_chains_split: list containing line-wise lastz output file including LINE### statements as block separator
    positions: starting position of current block should start with LINE###

    returns list of line split strings: one output block starting with LINE### and ending with LINE#
    raises ValueError if block not properly separated by LINE#
    """

    position = cur_position
    start = position
    # end = None
    line = all_mini_chains_split[position]
    re_line = re.compile(r"LINE\d+")

    # check whether initial line start with LINE#, raise error otherwise
    if re_line.match(line) is not None:

        position += 1  # get next line
        line = all_mini_chains_split[position]

        # process block until LINE# as end separator is encountered
        while re_line.match(line) is None:
            position += 1  # get next line
            line = all_mini_chains_split[position]

        # check that last line contains LINE#
        if re_line.match(line) is not None:
            end = position
        else:
            raise ValueError(
                f"ERROR! all_mini_chains_split end separator line at"
                f"position {position} does not start with LINE..."
            )

    else:
        raise ValueError(
            f"ERROR! all_mini_chains_split start separator line at"
            f"position {str(position)} does not start with LINE..."
        )

    cur_block_list = all_mini_chains_split[start: (end + 1)]
    return cur_block_list


def take_first_chain_from_list(chain_list):
    """
    Takes first chain from a chain list
    returns the header: "chain 52633 chr..." and a list of lines of this chain
    returns twice None if no chains are present
    """
    head_line = None
    chain_content = None
    chain_start = None
    chain_end = None

    for pos in range(0, len(chain_list)):

        line = chain_list[pos]

        # check if chain line
        m = re.match(r"chain", line)
        if m is not None:
            head_line = line.strip("\n")

            # process and store end position
            pos += 1
            line = chain_list[pos]
            chain_start = pos

            while re.match(r"^\d+", line) is not None:
                pos += 1
                line = chain_list[pos]
            chain_end = pos  # actually position after chain

            # don't process lower scoring chains
            break

    # extract chain
    if chain_start is not None:
        chain_content = chain_list[chain_start:chain_end]
    return head_line, chain_content


def write_mini_chains_file(s, outfile, enum):
    """Enumerates all mini chains and writes them to a file."""
    lines_list = [f"{line}\n" for line in s.split("\n") if line]

    with open(outfile, "a") as ouf:
        for element in lines_list:
            if element.startswith("chain"):
                header_no_enum = " ".join(element.split[:-1])
                element = f"{header_no_enum}\t{enum}\n"
                # element = " ".join(element.split()[:-1]) + f"\t{enum}\n"
                enum += 1
            ouf.write(element)

    return enum


def insert_chain_content(
        chain_content, best_chain, block_len_a, t_block_end, t_gap_end, lo_q_block_end, lo_q_gap_end
):
    """
    After patching chain we need to insert it back on the right place
    insert_chain_content calculates new coordinates for a chain to be inserted
    and returns a list of lines, that were changed in comparison with an old chain file
    """
    t_lastz_start = int(best_chain.split()[5]) + 1
    t_lastz_end = int(best_chain.split()[6])

    if best_chain.split()[9] == "+":
        q_lastz_start = int(best_chain.split()[10]) + 1
        q_lastz_end = int(best_chain.split()[11])
    else:
        # recalculate -strand coords to +strand:
        q_lastz_start = int(best_chain.split()[8]) - int(best_chain.split()[10])
        q_lastz_end = int(best_chain.split()[8]) - int(best_chain.split()[11]) + 1

        temp_q = lo_q_gap_end
        lo_q_gap_end = lo_q_block_end
        lo_q_block_end = temp_q

    blocks_to_add = []

    if best_chain.split()[9] == "+":
        first_q_gap = abs(q_lastz_start - int(lo_q_block_end))
        last_q_gap = abs(int(lo_q_gap_end) - q_lastz_end)
    else:
        first_q_gap = abs(q_lastz_start - int(lo_q_block_end))
        last_q_gap = abs(int(lo_q_gap_end) - q_lastz_end)

    first_line = f"{str(block_len_a)}\t{str(t_lastz_start - int(t_block_end))}\t{str(first_q_gap)}\t"

    blocks_to_add.append(first_line)
    for i in range(0, len(chain_content) - 1):
        blocks_to_add.append(chain_content[i])

    chain_content_prelast = chain_content[len(chain_content) - 1].strip()
    last_line = f"{chain_content_prelast}\t{str(int(t_gap_end) - t_lastz_end)}\t{str(last_q_gap)}\t"
    blocks_to_add.append(last_line)
    return blocks_to_add


def fill_gaps_from_mini_chains(
        current_chain_lines,
        cur_mini_block_lines,
        args,
        number_mini_chains,
        all_mini_chain_lines,
        start_time,
):
    """Processes initial chain and fills gaps with mini chains; writes to output file if provided."""
    if args.output:
        try:
            ouf = open(args.output, "w")
        except IOError as e:
            logging.error("Cannot write to output file", e.errno, e.strerror)
            sys.exit(1)
    else:  # Bogdan: ouf not defined if not args.output
        ouf = sys.stdout

    # regexp for getting lineNumber
    re_line_number = re.compile(r"LINE(\d+)")
    # get next line number where initial chain will be filled with gaps
    m = re_line_number.match(cur_mini_block_lines[0])
    if m is not None:
        next_line_number = int(m.group(1))
    else:
        raise ValueError(
            "ERROR! Could not extract line number from separator current miniChain block"
        )

    # initial position
    next_pos = 0
    for line_num in range(0, len(current_chain_lines)):

        # get current initial chain line
        line = current_chain_lines[line_num]

        # update chain
        if line_num == next_line_number:

            # strip first and last line containing LINE# from block
            values_list = cur_mini_block_lines[1: (len(cur_mini_block_lines) - 1)]
            coords = values_list[:5]
            # remove new lines from coords elements
            coords = [s.strip() for s in coords]

            # update next_pos and get next mini chain block;
            # +1 since we have new line after each block in the output
            next_pos = next_pos + len(cur_mini_block_lines) + 1
            # test that we are not out of bounds, i.e. last entry, -1 since last line is new line
            if next_pos < number_mini_chains - 1:
                cur_mini_block_lines = get_chain_block_from_lastz_output(
                    all_mini_chain_lines, next_pos
                )
                # get next line number
                m = re_line_number.match(cur_mini_block_lines[0])
                if m is not None:
                    next_line_number = int(m.group(1))
                else:
                    raise ValueError(
                        "ERROR! Could not extract line number from separator current miniChain block"
                    )

            # get chain to be inserted
            best_chain, chain_content = take_first_chain_from_list(values_list[5:])

            # insert nothing if no chain in block
            if best_chain is not None:
                if int(best_chain.split()[1]) >= args.scoreThreshold:
                    logging.info(f"Best lastz output chain = {best_chain}")

                    insert_block = insert_chain_content(
                        chain_content, best_chain, *coords
                    )
                    output_chain = "\n".join(insert_block)
                    time_mark = time.time() - start_time
                    logging.info(f"--- {time_mark} seconds ---")
                else:
                    logging.info("lastz output chains have low score\n")
                    output_chain = line
            else:
                logging.info("lastz changed nothing in this block\n")
                output_chain = line
        else:
            # Just add this line to the chain string and go further
            output_chain = line

        # print output
        if args.output:
            ouf.write(output_chain)
        else:
            print(output_chain)

    # close output file handle
    if args.output:
        ouf.close()


def main():
    # Track runtime
    start_time = time.time()

    # Parse CLI args
    args = parse_args()

    # Get chains with requested IDs
    current_chain_string = get_chain_string(args)

    # 1) Loop through .all.chain file and make a jobList
    temp = make_shell_jobs(args, current_chain_string)

    # 2) Run prepared jobList
    all_mini_chains = run_all_shell(temp.name)

    # Remove this jobList
    os.unlink(temp.name)

    # 3) Check if executing the jobList returned nothing = no new blocks to add
    if all_mini_chains == "":
        # This patch is added by Bogdan Kirilenko
        # If there is nothing to insert, the script doesn't return anything
        # Initialize output stream to stdout by default
        if args.output:
            # If an output file is specified, write to it
            with open(args.output, "w") as file:
                file.write(current_chain_string)
        else:
            # Otherwise, write to stdout
            sys.stdout.write(current_chain_string)

        logging.info("Found no new blocks to insert in this chain. Done!")

    else:
        logging.info(
            "Found new blocks to insert in this chain. Filling gaps now . . . ."
        )

        # Get initial position of mini chain block
        next_pos = 0

        # list of initial chains
        current_chain_lines = [f"{i}\n" for i in current_chain_string.split("\n")]

        # list of mini chain blocks
        all_mini_chain_lines = [f"{i}\n" for i in all_mini_chains.split("\n")]
        number_mini_chains = len(all_mini_chain_lines)

        # Get the first mini chain
        cur_mini_block_lines = get_chain_block_from_lastz_output(
            all_mini_chain_lines, next_pos
        )

        # Process initial chain and fill gaps from mini chains
        fill_gaps_from_mini_chains(
            current_chain_lines,
            cur_mini_block_lines,
            args,
            number_mini_chains,
            all_mini_chain_lines,
            start_time,
        )
    # Record runtime
    tot_time = time.time() - start_time
    logging.info(f"--- Final runtime: {tot_time} seconds ---")


if __name__ == "__main__":
    main()
