#!/usr/bin/env python3

############################

"""
Takes chain or chainIDs as input.
For each chain, the script finds a gap of a certain size,
runs a local lastz job, since the resulting alignments can overlap, chains them.
Selects the best 'mini-chain' and directly adds this into the gap.
Then continues iterating.
"""

############################
import sys
import os
import subprocess
import argparse
import logging
import re
import io
import time
import tempfile

############################


__author__ = "Ekaterina Osipova, MPI-CBG/MPI-PKS, 2018."


def build_args_parser():
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
    requiredNamed = parser.add_argument_group("required named arguments")
    requiredNamed.add_argument(
        "--chain", "-c", type=str, help="all.chain file", required=True
    )
    requiredNamed.add_argument(
        "--T2bit", "-T2", type=str, help="reference 2bit file", required=True
    )
    requiredNamed.add_argument(
        "--Q2bit", "-Q2", type=str, help="query 2bit file", required=True
    )
    # Optional arguments
    # parser.add_argument('-m', '--mini', type=str,
    # help="name of a file to put all mini chains from lastz")
    parser.add_argument(
        "--idList",
        type=str,
        help="idList=X,Y,Z a list of IDs of chains that have to be patched",
    )
    parser.add_argument(
        "--idListFile",
        type=str,
        help="File containing list of IDs of chains that have to be patched, one per row",
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
        "--chainExtractID",
        "-cid",
        type=str,
        default="chainExtractID",
        help="path to chainExtractID executable, default = chainExtractID",
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
        help="insert only chains that have at leaset this score, default st = 2000",
    )
    parser.add_argument("--index", "-ix", type=str, help="index.bb file for chains")
    return parser


def parse_and_check_args(parser):
    """Parses arguments from the command and checks for any conflics."""
    args = parser.parse_args()

    # initialize variables
    chainIDs = ""
    # use list containing batches of max. maxChainIDs chainIDs per chainExtract call
    maxChainIDs = 5000
    listChainID = []

    if args.idList and args.idListFile:
        logging.error(
            "ERROR! Choose either idListFile or idList. Both is not supported."
        )
        sys.exit(1)

    if args.idList or args.idListFile:
        if not args.index:
            logging.error(
                "ERROR! index most be specified if idListFile or idList is used."
            )
            sys.exit(1)

    if args.verbose:
        logging.basicConfig(level=logging.INFO)

    if args.idList:
        chainIDs = args.idList

    if args.idListFile:
        try:
            # read IDList file
            with open(args.idListFile, "r") as inf:
                chainIDLines = inf.read().split("\n")
        except IOError as e:
            logging.error("Cannot read to idListFile", e.errno, e.strerror)
            sys.exit(1)
            # we might exceed shell argument maximum byte size, therefore we use smaller batches of chains
            # for chainExtractID; most simple way of getting batches of chains
        nchain = 0
        tchainstr = ""  # add IDs to string until maxChainIDs chains reached

        for line in iter(chainIDLines):
            tchainstr = tchainstr + "," + line
            nchain += 1

            if nchain == maxChainIDs:
                listChainID.append(tchainstr)
                nchain = 0
                tchainstr = ""

        # get final batch of chainIDs
        listChainID.append(tchainstr)

    return args, chainIDs, listChainID


def extract_chain_by_IDs(args, chainIDs, listChainID):
    """Extracts chains with requested ids from all.chain file.

    get chains; either iterate over batches of chains or extract single chain string
    """
    current_chain_string = ""
    if listChainID:

        # loop over chains and concatenate string
        for chainIDs in iter(listChainID):

            extract_command = (f"{args.chainExtractID} {args.index} {args.chain} "
                               f"stdout -idList={chainIDs}")

            try:
                Tcurrent_chain_string = subprocess.check_output(
                    extract_command, shell=True
                )
                Tcurrent_chain_string = Tcurrent_chain_string.decode()
                logging.info("Running patching on the chain ID = {}".format(id))
                current_chain_string = (
                        current_chain_string + "\n" + Tcurrent_chain_string
                )
            except subprocess.CalledProcessError as extractrun:
                logging.error(
                    "extract chain command failed",
                    extractrun.returncode,
                    extractrun.output,
                )
                sys.exit(1)
    else:

        if chainIDs:
            extract_command = "{0} {1} {2} stdout -idList={3}".format(
                args.chainExtractID, args.index, args.chain, chainIDs
            )
            try:
                current_chain_string = subprocess.check_output(
                    extract_command, shell=True
                )
                current_chain_string = current_chain_string.decode()
                logging.info(f"Running patching on the chain ID = {chainIDs}")
            except subprocess.CalledProcessError as extractrun:
                logging.error(
                    "extract chain command failed",
                    extractrun.returncode,
                    extractrun.output,
                )
                sys.exit(1)
        else:
            try:
                with open(args.chain, "r") as content_file:
                    current_chain_string = content_file.read()
            except IOError as e:
                logging.error(
                    "Cannot read chain file {} {}".format(e.errno, e.strerror)
                )
                sys.exit(1)
    return current_chain_string


def make_shell_list(inChain, outf, args):
    """Makes a list of jobs to run in temp shell script.

    inChain: string containing all chains
    outf: path to output file; shell commands will be written into this file
    """
    try:
        fhout = open(outf, "w")
    except IOError as e:
        logging.error("Cannot write to shell script", e.errno, e.strerror)
        sys.exit(1)

    # write a header for the shell script
    fhout.write("#!/usr/bin/env bash\n")
    fhout.write("#set -o pipefail\n")
    fhout.write("#set -e\n")

    # count gaps patched in this file
    gap_count = 0

    # Nmbrs for tracking the line number
    lineNmbr = 0

    # two bit files
    T2bit = args.T2bit
    Q2bit = args.Q2bit

    lastzVar = args.lastz
    axtChainVar = args.axtChain
    chainSortVar = args.chainSort

    # put chain string into a list
    ChainList = iter([i + "\n" for i in inChain.split("\n")])

    # change to access by index
    for line in ChainList:
        lineNmbr += 1

        ll = line.split()
        if len(ll) > 0:
            if ll[0] == "chain":
                # read the chain line:
                # e.g. chain 196228 chr4 62094675 + 12690854 12816143 chr23 24050845 - 20051667 20145391 1252
                score = int(ll[1])
                tName, tStart, tEnd = ll[2], int(ll[5]), int(ll[6])
                qName, qStartx, qEndx, qStrand = ll[7], int(ll[10]), int(ll[11]), ll[9]
                qSize = int(ll[8])
                logging.info("qStrand = {}".format(qStrand))
                # changing coords for -strand if necessary

                qStart = qStartx
                qEnd = qEndx
                lastzParameters = args.lastzParameters + " --strand=plus"

                if qStrand == "-":
                    lastzParameters = args.lastzParameters + " --strand=minus"

                if ll[4] != "+":
                    logging.error(
                        "ERROR: target strand is not + for chain:{}".format(line)
                    )
                    sys.exit(1)
                # check if we consider this chain
                logging.info("score of this chain = {}".format(score))
                if (
                        (score >= args.chainMinScore)
                        and (tEnd - tStart >= args.chainMinSizeT)
                        and (qEnd - qStart >= args.chainMinSizeQ)
                ):
                    logging.info("valid chain")
                    curTPos = tStart
                    curQPos = qStart

                    line = next(ChainList)
                    lineNmbr += 1

                    while re.match("^\d+", line) is not None:
                        a = line.split()
                        if len(a) == 1:
                            TblockEnd = curTPos + int(a[0])
                            QblockEnd = curQPos + int(a[0])
                            logging.info("it was the last block\n")

                        else:
                            blockLen = int(a[0])
                            TblockEnd = curTPos + blockLen
                            QblockEnd = curQPos + blockLen
                            TgapEnd = curTPos + blockLen + int(a[1])
                            QgapEnd = curQPos + blockLen + int(a[2])
                            tGapSpan = TgapEnd - TblockEnd
                            qGapSpan = QgapEnd - QblockEnd
                            # check if we want to patch this gap
                            if (
                                    (tGapSpan >= args.gapMinSizeT)
                                    and (tGapSpan <= args.gapMaxSizeT)
                                    and (qGapSpan >= args.gapMinSizeQ)
                                    and (qGapSpan <= args.gapMaxSizeQ)
                            ):
                                logging.info(
                                    "yes, this gap will be patched: {}".format(
                                        line.strip()
                                    )
                                )
                                TblockEnd += 1
                                QblockEnd += 1

                                # replace the content of the unmask by '[unmask]'
                                # if the user sets this flag, otherwise ''
                                if args.unmask:
                                    unmask = "[unmask]"
                                else:
                                    unmask = ""

                                if qStrand == "-":
                                    realQblockEnd = qSize - QgapEnd + 1
                                    realQgapEnd = qSize - QblockEnd + 1
                                else:
                                    realQblockEnd = QblockEnd
                                    realQgapEnd = QgapEnd

                                logging.info("running lastz on the block:")
                                regionToBePatched = [
                                    tName,
                                    str(TblockEnd),
                                    str(TgapEnd),
                                    qName,
                                    str(realQblockEnd),
                                    str(realQgapEnd),
                                ]
                                logging.info(" ".join(regionToBePatched))

                                # making lastz command for this region

                                # command_lastz = lastzVar + ' {0}/{1}[{2}..{3}]{9} {4}/{5}[{6}..{7}]{9} --format=axt {8} | 
                                # ' + axtChainVar + ' -linearGap=loose stdin {0} {4} stdout 2> /dev/null | 
                                # ' + chainSortVar + ' stdin stdout'.format
                                # (
                                # T2bit, tName, TblockEnd, TgapEnd, Q2bit, qName, realQblockEnd, 
                                # realQgapEnd, lastzParameters, unmask
                                # )
                                command1 = " {0}/{1}[{2}..{3}]{9} {4}/{5}[{6}..{7}]{9} --format=axt {8} | ".format(
                                    T2bit,
                                    tName,
                                    TblockEnd,
                                    TgapEnd,
                                    Q2bit,
                                    qName,
                                    realQblockEnd,
                                    realQgapEnd,
                                    lastzParameters,
                                    unmask,
                                )
                                command2 = " -linearGap=loose stdin {0} {1} stdout 2> /dev/null | ".format(
                                    T2bit, Q2bit
                                )
                                command3 = " stdin stdout"
                                command_lastz = (
                                        lastzVar
                                        + command1
                                        + axtChainVar
                                        + command2
                                        + chainSortVar
                                        + command3
                                )
                                ### adding this lastz run to a shell command list; lineNmbr - 1 because we start with 1 and later with 0
                                shellCommand = 'echo -e "LINE{0}\\n{1}\\n{2}\\n{3}\\n{4}\\n{5}\\n"; {6}; echo -e "LINE{0}\\n"\n'.format(
                                    (lineNmbr - 1),
                                    blockLen,
                                    TblockEnd,
                                    TgapEnd,
                                    realQblockEnd,
                                    realQgapEnd,
                                    command_lastz,
                                )
                                fhout.write(shellCommand)
                                # logging.error("Edit line number:" + str(lineNmbr))

                            curQPos = QgapEnd
                            curTPos = TgapEnd

                        # get next line, break if no more line in string
                        try:
                            line = next(ChainList)
                            lineNmbr += 1
                        except Exception:
                            break
                else:
                    logging.info("invalid chain\n")

                    # save chain header line; get next line
                    line = next(ChainList)
                    lineNmbr += 1

                    # read the rest of the chain store blocks
                    while re.match("^\d+", line) is not None:
                        try:
                            line = next(ChainList)
                            lineNmbr += 1
                        except Exception:
                            break

    logging.info("Done with reading gaps")
    logging.info("Gaps patched in this chain = {}".format(gap_count))
    logging.info("\n")
    logging.info("\n")

    # close file handler
    fhout.close()


def make_shell_jobs(args, current_chain_string):
    """Makes a temp file with a jobList."""
    if not os.path.isdir(args.workdir):
        logging.error("ERROR! Working directory '" + args.workdir + "' does not exist.")
        sys.exit(1)

    # create temp file
    try:
        temp = tempfile.NamedTemporaryFile(
            prefix="tempCGFjobList", dir=args.workdir, delete=False
        )
        temp.close()
    except PermissionError as e:
        logging.error(
            "ERROR! Failed to create temporary file inside '{}'. {} {}".format(
                args.workdir, e.errno, e.strerror
            )
        )
        sys.exit(1)

    # Find gaps and write corresponding jobs to a shell script
    make_shell_list(current_chain_string, temp.name, args)
    return temp


def run_all_shell(shellfile):
    """Takes temp file with all shell commands to run and returns lastz output in a single string."""
    all_shell_command = "bash " + shellfile
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

    except subprocess.CalledProcessError as shellrun:
        logging.error("shell command failed", shellrun.returncode, shellrun.output)
        sys.exit(1)

    all_mini_chains = all_mini_chains.decode()
    return all_mini_chains


def get_chain_block_from_lastz_output(all_mini_chains_split, cur_position):
    """
    Takes the whole lastz output chain list and return list containing chain block starting at cur_position

    (lineNmbr: [blockLen, TblockEnd, TgapEnd, realQblockEnd, realQgapEnd, 'allChainsStrings']) from LINE# to LINE#
    returns a dictionary

    all_mini_chains_split: list containing line-wise lastz output file including LINE### statements as block separator
    positions: starting position of current block (should start with LINE###

    returns list of line split strings: one output block starting with LINE### and ending with LINE#
    raises ValueError if block not properly separated by LINE#
    """

    position = cur_position
    start = position
    end = None
    line = all_mini_chains_split[position]
    reLine = re.compile(r"LINE\d+")

    # check whether initial line start with LINE#, raise error otherwise
    if reLine.match(line) is not None:

        position += 1  # get next line
        line = all_mini_chains_split[position]

        # process block until LINE# as end separator is encountered
        while reLine.match(line) is None:
            position += 1  # get next line
            line = all_mini_chains_split[position]

        # check that last line contains LINE#
        if reLine.match(line) is not None:
            end = position
        else:
            raise ValueError(
                "ERROR! all_mini_chains_split end separator line at position "
                + str(position)
                + " does not start with LINE..."
            )

    else:
        raise ValueError(
            "ERROR! all_mini_chains_split start separator line at position "
            + str(position)
            + " does not start with LINE..."
        )

    cur_block_list = all_mini_chains_split[start: (end + 1)]
    return cur_block_list


def take_first_chain_from_list(chainList):
    """
    Takes first chain from a chain list
    returns the header: "chain 52633 chr..." and a list of lines of this chain
    returns twice None if no chains are present
    """
    headLine = None
    chainContent = None
    chainStart = None
    chainEnd = None

    for pos in range(0, len(chainList)):

        line = chainList[pos]

        # check if chain line
        m = re.match(r"chain", line)
        if m is not None:
            headLine = line.strip("\n")

            # process and store end position
            pos += 1
            line = chainList[pos]
            chainStart = pos

            while re.match("^\d+", line) is not None:
                pos += 1
                line = chainList[pos]
            chainEnd = pos  # actually position after chain

            # don't process lower scoring chains
            break

    # extract chain
    if chainStart is not None:
        chainContent = chainList[chainStart:chainEnd]
    return (headLine, chainContent)


def write_mini_chains_file(s, outfile, enum):
    """Enumerates all mini chains and writes them to a file."""
    list = [l + "\n" for l in s.split("\n") if l]
    ouf = open(outfile, "a")
    for element in list:
        if element.startswith("chain"):
            element = " ".join(element.split()[:-1]) + "\t{}\n".format(enum)
            enum += 1
            ouf.write(element)
        else:
            ouf.write(element)
    ouf.close()
    return enum


def insert_chain_content(
        chain_content, best_chain, BlockLenA, TblockEnd, TgapEnd, LoQblockEnd, LoQgapEnd
):
    """
    After patching chain we need to insert it back on the right place
    insert_chain_content calculates new coordinates for a chain to be inserted
    and returns a list of lines, that were changed in comparision with an old chain file
    """
    TlastzStart = int(best_chain.split()[5]) + 1
    TlastzEnd = int(best_chain.split()[6])

    if best_chain.split()[9] == "+":
        QlastzStart = int(best_chain.split()[10]) + 1
        QlastzEnd = int(best_chain.split()[11])
    else:
        # recalculate -strand coords to +strand:
        QlastzStart = int(best_chain.split()[8]) - int(best_chain.split()[10])
        QlastzEnd = int(best_chain.split()[8]) - int(best_chain.split()[11]) + 1

        tempQ = LoQgapEnd
        LoQgapEnd = LoQblockEnd
        LoQblockEnd = tempQ

    BlockToAdd = []

    if best_chain.split()[9] == "+":
        FirstQgap = abs(QlastzStart - int(LoQblockEnd))
        LastQGap = abs(int(LoQgapEnd) - QlastzEnd)
    else:
        FirstQgap = abs(QlastzStart - int(LoQblockEnd))
        LastQGap = abs(int(LoQgapEnd) - QlastzEnd)

    FirstLine = f"{str(BlockLenA)}\t{str(TlastzStart - int(TblockEnd))}\t{str(FirstQgap)}\t"

    BlockToAdd.append(FirstLine)
    for i in range(0, len(chain_content) - 1):
        BlockToAdd.append(chain_content[i])

    chain_content_prelast = chain_content[len(chain_content) - 1].strip()
    LastLine = f"{chain_content_prelast}\t{str(int(TgapEnd) - TlastzEnd)}\t{str(LastQGap)}\t"
    BlockToAdd.append(LastLine)
    return BlockToAdd


def fill_gaps_from_mini_chains(
        current_chain_lines,
        cur_mini_block_lines,
        args,
        nmbr_mini_chains,
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
    relineNmbr = re.compile(r"LINE(\d+)")
    # get next lineNmbr where initial chain will be filled with gaps
    m = relineNmbr.match(cur_mini_block_lines[0])
    if m is not None:
        next_lineNmbr = int(m.group(1))
    else:
        raise ValueError(
            "ERROR! Could not extract line number from separator current miniChain block"
        )

    # initial position
    next_pos = 0
    for lineNmbr in range(0, len(current_chain_lines)):

        # get current initial chain line
        line = current_chain_lines[lineNmbr]

        # update chain
        if lineNmbr == next_lineNmbr:

            # strip first and last line containing LINE# from block
            valueList = cur_mini_block_lines[1: (len(cur_mini_block_lines) - 1)]
            coords = valueList[:5]
            # remove new lines from coords elements
            coords = map(lambda s: s.strip(), coords)

            # update next_pos and get next mini chain block;
            # +1 since we have new line after each block in the output
            next_pos = next_pos + len(cur_mini_block_lines) + 1
            # test that we are not out of bounds, i.e. last entry, -1 since last line is new line
            if next_pos < nmbr_mini_chains - 1:
                cur_mini_block_lines = get_chain_block_from_lastz_output(
                    all_mini_chain_lines, next_pos
                )
                # get next lineNmbr
                m = relineNmbr.match(cur_mini_block_lines[0])
                if m is not None:
                    next_lineNmbr = int(m.group(1))
                else:
                    raise ValueError(
                        "ERROR! Could not extract line number from separator current miniChain block"
                    )

            # get chain to be inserted
            best_chain, chain_content = take_first_chain_from_list(valueList[5:])

            # insert nothing if no chain in block
            if best_chain is not None:
                if int(best_chain.split()[1]) >= args.scoreThreshold:
                    logging.info("Best lastz output chain = {}".format(best_chain))

                    insert_block = insert_chain_content(
                        chain_content, best_chain, *coords
                    )
                    output_chain = "\n".join(insert_block)
                    logging.info("--- %s seconds ---" % (time.time() - start_time))
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

    # Build arguments parser
    parser = build_args_parser()

    # Check arguments; initialize parameters
    args, chainIDs, listChainID = parse_and_check_args(parser)

    # Get chains with requested IDs
    current_chain_string = extract_chain_by_IDs(args, chainIDs, listChainID)

    # 1) Loop through .all.chain file and make a jobList
    temp = make_shell_jobs(args, current_chain_string)

    # 2) Run prepared jobList
    all_mini_chains = run_all_shell(temp.name)

    # Remove this jobList
    os.unlink(temp.name)

    # 3) Check if executing the jobList returned nothing = no new blocks to add
    if all_mini_chains == "":
        # This dirty patch is added by Bogdan Kirilenko
        # if there is nothing to insert -> the script does not return anything
        # TODO: refactor this part
        if args.output:
            try:
                ouf = open(args.output, "w")
            except IOError as e:
                logging.error("Cannot write to output file", e.errno, e.strerror)
                sys.exit(1)
        else:  # Bogdan: ouf not defined if not args.output
            ouf = sys.stdout

            # print output
        if args.output:
            ouf.write(current_chain_string)
        else:
            print(current_chain_string)

        # close output file handle
        if args.output:
            ouf.close()
        logging.info("Found no new blocks to insert in this chain. Done!")
    else:
        logging.info(
            "Found new blocks to insert in this chain. Filling gaps now . . . ."
        )

        # Get initial position of mini chain block
        next_pos = 0

        # list of initial chains
        current_chain_lines = [i + "\n" for i in current_chain_string.split("\n")]

        # list of mini chain blocks
        all_mini_chain_lines = [i + "\n" for i in all_mini_chains.split("\n")]
        nmbr_mini_chains = len(all_mini_chain_lines)

        # Get the first mini chain
        cur_mini_block_lines = get_chain_block_from_lastz_output(
            all_mini_chain_lines, next_pos
        )

        # Process initial chain and fill gaps from mini chains
        fill_gaps_from_mini_chains(
            current_chain_lines,
            cur_mini_block_lines,
            args,
            nmbr_mini_chains,
            all_mini_chain_lines,
            start_time,
        )
    # Record runtime
    logging.info("--- Final runtime: %s seconds ---" % (time.time() - start_time))


if __name__ == "__main__":
    main()
