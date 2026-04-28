### For reasons, the versions history starts with 2.0.8

- added agrs to manually define lastz and nextflow executables location
- fixing issue [hillerlab/make_lastz_chains#35](https://github.com/hillerlab/make_lastz_chains/issues/35) - 
the previous implementation limited the number of little chromosomes per batch based solely
on the size threshold, which could lead to a system argument list overflow error
when there are a vast number of small chromosomes. The updated implementation now
also considers a maximum chromosome count per bucket.
- bulky nextflow classes cooperation is wrapped into `execute_nextflow_step` (bulky as well,
but a bit better) 

# 2.0.9 (in progress)

- added executor.queueSize parameter to the NF config (default to 1000)

# 3.0.0

- Full nf-core DSL2 refactor: pipeline logic moved from Python orchestration into native Nextflow modules, subworkflows, and channels
- Scientific parameters separated into `params.json`; `nextflow.config` is infrastructure-only
- All tools run inside a single Docker/Apptainer container (`nilablueshirt/make_lastz_chains:latest-amd64`)
- LASTZ, AXT_CHAIN, and REPEAT_FILLER submit as SLURM job arrays (`process.array`) to reduce scheduler overhead
- Added `FROM_FILL_CHAINS` and `FROM_CLEAN_CHAINS` entry alias workflows for checkpoint restarts
- Fixed issue #56: size-aware writer + version-aware reader. `faToTwoBit -long` is now only enabled when the input FASTA exceeds 4 GB, so mammalian-scale genomes get a v0 `.2bit` and large ones (lungfish, salamander, etc.) get v1. `run_lastz.py` then dispatches by detected version: v0 files are read directly by lastz as upstream does, preserving byte-identical output; v1 files — which lastz cannot read — are handled by extracting the whole chromosome to a temp FASTA via `twoBitToFa -seq=<chrom>` (bare `>chrom` header, no offset suffix), then calling lastz with the same subrange syntax on the FASTA so coordinates and chromosome names match native `.2bit` reading. Removed `py2bit`/`twobitreader` Python dependencies entirely. An earlier version of this fix extracted each partition with `-start/-end`, which produced `>chrom:start-end` headers and partition-relative coordinates that broke downstream `psl_bundle.py` chrom-name lookups and produced a much smaller `.all.chain.gz` than upstream
- All module process labels aligned with `nextflow.config` `withLabel` blocks (was causing jobs to get no container or memory allocation)
- `run_lastz.py` and `run_lastz_intermediate_layer.py` added to `bin/` for automatic Nextflow staging
- Container image selectable via `NXF_CONTAINER_IMAGE` env var; falls back to Docker Hub pull
- Old `make_chains.py` Python entry point preserved for backward compatibility