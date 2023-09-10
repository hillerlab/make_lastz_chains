"""Project-wide constants."""


class Constants:
    DESCRIPTION = "Pipeline to create chain-formatted pairwise genome alignments."
    # defaults
    DEFAULT_SEQ1_CHUNK = 175_000_000
    DEFAULT_SEQ2_CHUNK = 50_000_000
    DEFAULT_LASTZ_H = 2000
    DEFAULT_LASTZ_Y = 9400
    DEFAULT_LASTZ_L = 3000
    DEFAULT_LASTZ_K = 2400

    DEFAULT_CLEANCHAIN_PARAMS = (
        "-LRfoldThreshold=2.5 -doPairs -LRfoldThresholdPairs=10 -maxPairDistance=10000 "
        "-maxSuspectScore=100000 -minBrokenChainScore=75000"
    )
