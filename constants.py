"""Project-wide constants."""
import os


class Constants:
    DESCRIPTION = "Pipeline to create chain-formatted pairwise genome alignments."

    # defaults
    # DEFAULT_SEQ1_CHUNK = 175_000_000
    # DEFAULT_SEQ2_CHUNK = 50_000_000
    DEFAULT_SEQ1_CHUNK = 200_000
    DEFAULT_SEQ2_CHUNK = 80_000
    DEFAULT_SEQ1_LAP = 0
    DEFAULT_SEQ1_LIMIT = 4000  # what is it?
    DEFAULT_SEQ2_LAP = 10_000
    DEFAULT_SEQ2_LIMIT = 10_000

    DEFAULT_LASTZ_H = 2000
    DEFAULT_LASTZ_Y = 9400
    DEFAULT_LASTZ_L = 3000
    DEFAULT_LASTZ_K = 2400

    DEFAULT_MIN_CHAIN_SCORE = 10_000
    DEFAULT_CHAIN_LINEAR_GAP = "loose"

    DEFAULT_FILL_CHAIN_ARG = 1  # TODO: consider bool
    DEFAULT_FILL_UNMASK_ARG = 1  # TODO: consider bool
    DEFAULT_FILL_CHAIN_MIN_SCORE = 25_000
    DEFAULT_INSERT_CHAIN_MIN_SCORE = 5_000

    DEFAULT_FILL_GAP_MAX_SIZE_T = 20_000
    DEFAULT_FILL_GAP_MAX_SIZE_Q = 20_000
    DEFAULT_FILL_GAP_MIN_SIZE_T = 30
    DEFAULT_FILL_GAP_MIN_SIZE_Q = 30

    DEFAULT_FILL_LASTZ_K = 2000
    DEFAULT_FILL_LASTZ_L = 3000
    DEFAULT_FILL_MEMORY = 15_000
    DEFAULT_FILL_PREPARE_MEMORY = 50_000

    DEFAULT_CHAINING_MEMORY = 50_000
    DEFAULT_CLEAN_CHAIN_ARG = 1  # TODO: consider bool
    DEFAULT_CHAIN_CLEAN_MEMORY = 100_000

    BUNDLE_PSL_MAX_BASES = 1_000_000

    # TODO: fill the rest of defaults and constants
    DEFAULT_CLEAN_CHAIN_PARAMS = (
        "-LRfoldThreshold=2.5 -doPairs -LRfoldThresholdPairs=10 -maxPairDistance=10000 "
        "-maxSuspectScore=100000 -minBrokenChainScore=75000"
    )

    TARGET_LABEL = "target"
    TARGET_SEQ_FILENAME = f"{TARGET_LABEL}.2bit"
    TARGET_CHROM_SIZES_FILENAME = f"{TARGET_LABEL}.chrom.sizes"

    QUERY_LABEL = "query"
    QUERY_SEQ_FILENAME = f"{QUERY_LABEL}.2bit"
    QUERY_CHROM_SIZES_FILENAME = f"{QUERY_LABEL}.chrom.sizes"

    # file and directory names
    TEMP_LASTZ_DIRNAME = "TEMP_run.lastz"
    TEMP_PSL_DIRNAME = "TEMP_psl"
    TEMP_CAT_DIRNAME = "TEMP_run.cat"
    TEMP_AXT_CHAIN_DIRNAME = "TEMP_axtChain"
    SPLIT_PSL_DIRNAME = "splitPSL"

    PARAMS_JSON_FILENAME = "pipeline_parameters.json"
    LASTZ_JOBLIST_FILENAME = "lastz_joblist.txt"

    KENT_BINARIES_DIRNAME = "HL_kent_binaries"

    class NextflowConstants:
        SCRIPT_LOCATION = os.path.abspath(os.path.dirname(__file__))
        NF_DIRNAME = "parallelization"
        NF_DIR = os.path.abspath(os.path.join(SCRIPT_LOCATION, NF_DIRNAME))
        NF_SCRIPT_PATH = os.path.join(NF_DIR, "execute_joblist.nf")
        LASTZ_CONFIG_PATH = os.path.join(NF_DIR, "lastz_step_config.nf")

    class ToolNames:
        PSL_SORT_ACC = "pslSortAcc"
        TWO_BIT_TO_FA = "twoBitToFa"
        FA_TO_TWO_BIT = "faToTwoBit"
