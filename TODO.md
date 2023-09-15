# TODO list

## Mandatory

- Documentation
- Full scale test
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

- Refactor HL kent dependencies -> maybe it was not necessary to split into 2 dirs?
- QC module or something - detailed statistics per each step
- Explanation for each pipeline parameter in the parse_args
- ~~Refactor chain gap filler: get rid of chainExtractID dependency -> not needed~~
- ~~read parameters from config file~~
- Document masking, etc. - nuances that affect the pipeline performance.
- https://github.com/hillerlab/make_lastz_chains/issues/20 - temp files location

## Minor things

- lastz_q parameter - figure out what stands for and whether it is needed
- 