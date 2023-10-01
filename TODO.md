# TODO list

## Mandatory

- Documentation
- ~~Full scale test~~
- ~~get rid of negatively scored chains~~
- ~~Organise cat step better~~
- ~~Get rid of all magic numbers and strings~~
- ~~Check for output presence after each step~~
- ~~Nextflow manager class~~ -> dedicated class for NF config
- ~~Double check the pipeline default parameters~~
- ~~Fix the install dependencies script~~
- ~~Logging messages~~
- ~~For all subprocesses -> error handling~~
- ~~Check for absent expected files~~

## Nice to do

- About dependencies: properly handle `missing *.so` error that may occur when running Kent binaries, like here https://github.com/hillerlab/make_lastz_chains/issues/34
- QC module: https://github.com/hillerlab/make_lastz_chains/issues/33
- lastz_q parameter - figure out what stands for and whether it is needed
- Explanation for each pipeline parameter in the parse_args
- Document masking, etc. - nuances that affect the pipeline performance.
- ~~Refactor HL kent dependencies -> maybe it was not necessary to split into 2 dirs?~~ -> not split anymore
- ~~Refactor chain gap filler: get rid of chainExtractID dependency -> not needed~~
- ~~read parameters from config file~~
- ~~https://github.com/hillerlab/make_lastz_chains/issues/20 - temp files location~~

## Ideas for additional features

- Self chains: https://github.com/hillerlab/make_lastz_chains/issues/31
