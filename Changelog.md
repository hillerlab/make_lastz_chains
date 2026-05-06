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

# 3.0.0 — nf-core DSL2 refactor

Full pipeline refactor. See [CHANGES_nfcore_refactor.md](CHANGES_nfcore_refactor.md) for detailed root-cause writeups, file-change tables, design rationale, and parameter audit.

Highlights:

- Pipeline logic moved from Python orchestration into native Nextflow DSL2 modules, subworkflows, and channels; old `make_chains.py` entry point preserved for backward compatibility
- Scientific parameters separated into `params.json`; `nextflow.config` covers infrastructure (compute tiers, profiles, per-step wiring) and default param values
- Single Docker/Apptainer container for all tools (`nilablueshirt/make_lastz_chains:latest-amd64`); image overridable via `NXF_CONTAINER_IMAGE` env var, falls back to Docker Hub
- LASTZ, AXT_CHAIN, REPEAT_FILLER submit as SLURM job arrays (`process.array`); added `FROM_FILL_CHAINS` / `FROM_CLEAN_CHAINS` entry aliases for checkpoint restarts
- `run_lastz.py` and `run_lastz_intermediate_layer.py` added to `bin/` for automatic Nextflow staging
- All module process labels aligned with `nextflow.config` `withLabel` blocks (a previous mismatch caused jobs to get no container or memory allocation)
- Bug fixes: large-genome (>4 GB) `.2bit` support (issue #56), BULK-partition silent data loss (filename too long), v1 `.2bit` lastz invocation, redundant chromosome FASTA extraction
- Reliability: strict `errorStrategy` + post-LASTZ integrity check, SLURM RPC pressure mitigations (`pollInterval`, `queueStatInterval`, `exitReadTimeout`), `standalone_scripts/nf_watchdog.sh` to detect and recover from wedged head jobs
- Debug affordance: `--force_long_2bit` flag to exercise the v1 path on small genomes
- Result publication: per-step intermediates symlinked under `${params.outdir}/`; durable outputs (genome_prep, partition, fill_chains, final) copied
