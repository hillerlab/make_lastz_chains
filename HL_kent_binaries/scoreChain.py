#!/usr/bin/env python3
"""Python replacement for scoreChain"""
import argparse
import sys
import twobitreader
from collections import defaultdict
from dataclasses import dataclass


DESCRIPTION_FROM_SCORECHAIN = """
scoreChain - (re)score existing chains
usage:
   scoreChain in.chainFile reference.2bit query.2bit out.chain  -linearGap=loose|medium|filename
Where reference.2bit and query.2bit are the names of a .2bit files for the reference and query
options:
 Local score = we set score = 0 if score < 0 and return the max of the score that we reach for a chain
   -returnOnlyScore             default=FALSE. Just return chain ID{tab}globalScore{tab}localScore{tab}totalAligningBases, not the entire chain
   -returnOnlyScoreAndCoords    default=FALSE. Just return chain ID{tab}chainStartInRef{tab}chainEndInRef{tab}localScore{tab}totalAligningBases, not the entire chain
   -doLocalScore                default=FALSE. Only if the global score of a chain is negative, compute and output the local score in the chain file.
   -forceLocalScore             default=FALSE. Always output the local score in the chain file.
   -scoreScheme=fileName        Read the scoring matrix from a blastz-format file
   -linearGap=<medium|loose|filename>    Specify type of linearGap to use.
              *Must* specify this argument to one of these choices.
              loose is chicken/human linear gap costs.
              medium is mouse/human linear gap costs.
              Or specify a piecewise linearGap tab delimited file.
   sample linearGap file (loose)
tablesize       11
smallSize       111
position        1       2       3       11      111     2111    12111   32111   72111   152111  252111
qGap    325     360     400     450     600     1100    3600    7600    15600   31600   56600
tGap    325     360     400     450     600     1100    3600    7600    15600   31600   56600
bothGap 625     660     700     750     900     1400    4000    8000    16000   32000   57000
"""

ORIGINAL_GAP_COSTS = """tableSize 11
smallSize 111
position 1 2 3 11 111 2111 12111 32111 72111 152111 252111\n
qGap 350 425 450 600 900 2900 22900 57900 117900 217900 317900
tGap 350 425 450 600 900 2900 22900 57900 117900 217900 317900
bothGap 750 825 850 1000 1300 3300 23300 58300 118300 218300 318300
"""

DEFAULT_GAP_COSTS = """tablesize       11
smallSize       111
position        1       2       3       11      111     2111    12111   32111   72111   152111  252111
qGap    325     360     400     450     600     1100    3600    7600    15600   31600   56600
tGap    325     360     400     450     600     1100    3600    7600    15600   31600   56600
bothGap 625     660     700     750     900     1400    4000    8000    16000   32000   57000
"""

NUM_NUCL = 4

@dataclass
class ScoringScheme:
    """Scoring scheme"""
    matrix: dict
    gap_open: int
    gap_extent: int
    extra: str



def parse_args():
    """Command line arguments parser."""
    app = argparse.ArgumentParser()
    app.add_argument("in_chain", help="Input chain file or stdin")
    app.add_argument("reference_2bit", help="Reference 2bit file")
    app.add_argument("query_2bit", help="Query 2bit file")
    app.add_argument("output", help="Output chain or stdout")
    app.add_argument("-linearGap", choices=['loose', 'medium', 'filename'], help="loose|medium|filename")
    app.add_argument("-scoreScheme", help="Read the scoring matrix from a blastz-format file")

    if len(sys.argv) < 5:
        app.print_help()
        sys.exit(0)
    
    args = app.parse_args()
    return args


def read_score_scheme(scoreScheme):
    """Read score scheme."""

    """
    struct axtScoreScheme
    /* A scoring scheme or DNA alignment. */
    {
    struct scoreMatrix *next;
    int matrix[256][256];   /* Look up with letters. */
    int gapOpen;	/* Gap open cost. */
    int gapExtend;	/* Gap extension. */
    char *extra;        /* extra parameters */
    };
    """
    if scoreScheme is None:
        raise NotImplementedError("Please specify -scoreScheme")

    matrix = defaultdict(dict)
    f = open(scoreScheme)

    characters = f.__next__().rstrip().split()
    if len(characters) != NUM_NUCL:
        raise ValueError(f"Seems like {scoreScheme} is not a valid score scheme")

    for num, line in enumerate(f):
        vals = [int(x) for x in line.rstrip().split()]
        row_char = characters[num]
        for col_char, v in zip(characters, vals):
            matrix[row_char][col_char] = v
        if num == NUM_NUCL - 1:
            break  # 4 nucleotides are read
    # read O and E if present
    next_line = next(f, None)
    if next_line is None:
        gap_open = 400
        gap_extend = 30
    else:
        line_vals = next_line.rstrip().split()
        gap_open = int(line_vals[2].replace(",", ""))
        gap_extend = int(line_vals[5].replace(",", ""))
    
    ret = ScoringScheme(matrix, gap_open, gap_extend, "")
    f.close()
    return ret


def gap_calc_from_file(filename):
    """Return gapCalc from file. */"""
    if filename == "loose":
        gap_calc_name = DEFAULT_GAP_COSTS
    elif filename == "medium":
        gap_calc_name = ORIGINAL_GAP_COSTS
    else:
        gap_calc_name = None
        raise NotImplementedError("-linearGap filename is not yet supported")
    
    return None

def main():
    """Entry point."""
    args = parse_args()
    score_scheme = read_score_scheme(args.scoreScheme)
    gap_calc = gap_calc_from_file(args.linearGap)

if __name__ == '__main__':
    main()
