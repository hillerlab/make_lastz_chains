### For reasons, the versions history starts with 2.0.8

- added agrs to manually define lastz and nextflow executables location
- fixing issue [hillerlab/make_lastz_chains#35](https://github.com/hillerlab/make_lastz_chains/issues/35) - 
the previous implementation limited the number of little chromosomes per batch based solely
on the size threshold, which could lead to a system argument list overflow error
when there are a vast number of small chromosomes. The updated implementation now
also considers a maximum chromosome count per bucket.
- bulky nextflow classes cooperation is wrapped into `execute_nextflow_step` (bulky as well,
but a bit better) 

