# 3.1.1

Container re-architecture with a new `use_container` parameter that lets users decide between a single whole-pipeline image and granular per-module containers.

### Container overhaul

- Replaced the old  `Dockerfile` (Ubuntu 22.04, full UCSC Kent rsync) with a modern multi-stage Alpine-based build at `assets/image/Dockerfile`. The new build compiles only the nine Kent tools the pipeline actually needs (faToTwoBit, twoBitToFa, pslSortAcc, axtChain, axtToPsl, chainSort, chainNet from v482; chainCleaner and chainScore from v455), builds LASTZ v1.04.52 from source (up from v1.04.22), and compiles `chaintools` and `chromsize` from their Rust sources. The runtime layer is Python 3.11 on Alpine. The resulting image is 108 MB.
- Deleted the root-level `Dockerfile` — the canonical build definition now lives under `assets/image/` but its pulled from [ghcr.io/hillerlab/make_lastz_chains:latest](https://github.com/hillerlab/containers/pkgs/container/make_lastz_chains).

### New `use_container` parameter

- Added `params.use_container` (boolean, default `true`) to `params.json` and `nextflow.config`. When enabled, a single `withName: '.*'` block overrides all process containers with `ghcr.io/hillerlab/make_lastz_chains:latest` (or `$NXF_CONTAINER_IMAGE` if set). When disabled, each module falls back to its own granular container, preserving the v3.1.0 behavior. This gives users the flexibility to use one lightweight image end-to-end or to swap individual tool containers as needed.

### Infrastructure

- Added `apptainer.pullTimeout = '60 min'` to the standard profile to prevent timeouts when pulling large container images over slow connections.
- Bumped manifest version from `3.1.0` to `3.1.1`.
- Enabled `use_container` in the test profile and fixed indentation alignment for query parameters in the `test` profile block.

### Documentation

- Updated the README with notes on the new pre-built container (`ghcr.io/hillerlab/make_lastz_chains:latest`) and the project's transition to `chaintools` for UCSC tool replacement.
- Fixed the pipeline diagram link in `README.md` (double `https://`).
- Updated `assets/scripts/run_nf_slurm_example.sh` to use the new `reference_name` / `reference_genome` parameter names introduced in v3.1.0 and point to the Hiller Lab container.


# 3.1.0 

Complete overhaul of `make_lastz_chains` from a hybrid Python + Nextflow v2 pipeline to a pure nf-core-style Nextflow v3 pipeline. Drops the legacy Python entry point, replaces monolithic UCSC containers with granular per-tool containers, introduces a new `--from` checkpoint system, swaps `target` terminology for `reference` across the entire codebase, and replaces several UCSC Kent tools with the lighter `chaintools` utility.

### Licensing

- Switched license from MIT to GNU GPL v3 — full GPL-3.0 text in `LICENSE`.

### Terminology

- Renamed `target` → `reference` everywhere: parameters (`--target_name` → `--reference_name`, `--target_genome` → `--reference_genome`), internal variables, channel names, comments, and log output. **This is a breaking change for anyone using the old parameter names.**

### New checkpoint / resume system (`--from`)

- Replaced the old `-entry` subworkflow system with a single `--from` parameter accepting `fill_chains` or `clean_chains`.
- `--from fill_chains` — resumes from an existing `*.all.chain.gz`, skipping LASTZ alignment and chain building. Genomes are prepared with `extract_chroms=false`.
- `--from clean_chains` — resumes from an existing `*.filled.chain.gz`, skipping alignment, building, and gap filling.
- Simplified required parameters for checkpoint workflows: only `--merged_chain_path` or `--filled_chain_path` are needed alongside genome paths; the old `--target_twobit`, `--query_twobit`, `--target_chrom_sizes`, `--query_chrom_sizes` are no longer required.

### Removed legacy v2 Python pipeline

- Deleted `make_chains.py` — the old Python entry point.
- Deleted entire `modules/` package: `common.py`, `error_classes.py`, `make_chains_logging.py`, `parameters.py`, `pipeline_steps.py`, `project_directory.py`, `project_paths.py`, `project_setup_procedures.py`, `step_executables.py`, `step_manager.py`, `step_status.py`.
- Deleted `steps_implementations/`: `cat_step.py`, `chain_merge_step.py`, `chain_run_bundle_substep.py`, `chain_run_step.py`, `clean_chain_step.py`, `fill_chain_split_into_parts_substep.py`, `fill_chain_step.py`, `lastz_step.py`, `partition.py`.
- Deleted `constants.py`, `version.py`, `install_dependencies.py`.
- Deleted `bin/chain_gap_filler.py`, `bin/split_chains.py` (replaced by `chaintools`).
- Deleted `standalone_scripts/` scripts (some moved to `assets/scripts/`).
- Deleted `parallelization/` Nextflow wrapper and job list executor.

### Removed pre-compiled Kent binaries

- Deleted `HL_kent_binaries/` entirely — removed `axtChain`, `chainAntiRepeat`, `chainCleaner`, `chainNet`, `chainScore`, `chainSort`, `pslSortAcc`, `NetFilterNonNested.perl`, and `readme.txt`.

### Container modernization

- Broke up the monolithic `ucsc_tools:332--1` container into granular per-tool containers:
  - `ucsc-axtchain:482` — for `axtChain`
  - `ucsc-pslsortacc:482` — for `pslSortAcc`
  - `ucsc-twobittofa:482` — for `twoBitToFa`
- Upgraded `chainCleaner` to `ghcr.io/hillerlab/chaincleaner:latest` (Docker) / `depot.galaxyproject.org/singularity/ucsc-chaincleaner:455` (Singularity).
- Replaced LASTZ container with `ghcr.io/hillerlab/pylastz:latest`.
- Switched Python containers from `python:3.10.2` to `python:3.8.0--2` for partition/PSL modules.
- New containers for `ghcr.io/alejandrogzi/chaintools:latest` and `ghcr.io/alejandrogzi/chromsize:latest`.

### New `chaintools` module

- Replaced `chainAntiRepeat` within `axtChain` — anti-repeat is now a separate step using `chaintools antirepeat` in the `CHAIN_BUILD` subworkflow.
- Replaced `chainMergeSort` with `chaintools merge` for merging chain files (both in chain building and gap-filling).
- Replaced `chainFilter` with `chaintools filter` — applies minimum score filter and gzips output.
- Replaced `chainScore` + `chainSort` in repeat filler with `chaintools score`.
- Replaced `split_chains.py` with `chaintools split` for splitting chains into chunks.
- New modules: `modules/local/chaintools/antirepeat/main.nf`, `modules/local/chaintools/filter/main.nf`, `modules/local/chaintools/merge/main.nf`, `modules/local/chaintools/score/main.nf`, `modules/local/chaintools/split/main.nf`.

### New `chromsize` module

- Replaced `TWO_BIT_INFO` (`twoBitInfo`) with a format-agnostic `CHROMSIZE` process that uses `chromsize` to generate `.chrom.sizes` files from FASTA or `.2bit` inputs.

### Pipeline structure changes

- Added anti-repeat step to `CHAIN_BUILD` subworkflow: chains now go through `axtChain` → `chaintools antirepeat` → `chaintools merge`.
- Restructured `FILL_CLEAN_CHAINS` subworkflow: replaced `FILL_CHAIN_SPLIT`/`FILL_CHAIN_MERGE` with `chaintools split`/`chaintools merge`, added explicit `chaintools score` step after repeat filling.
- Chain cleaner module refactored: now uses a meta tuple pattern, removed the `before_cleaning.chain.gz` output.
- Made `EXTRACT_CHROMS` conditional in `PREPARE_GENOMES` — controlled by the new `extract_chroms` input parameter (set to `false` for checkpoint workflows).
- Added stub blocks to all new `chaintools` and `chromsize` processes for faster dry-run testing.

### Code formatting

- Applied Ruff formatting across all modified Python scripts (`bin/partition.py`, `bin/psl_bundle.py`, `bin/run_lastz.py`, `bin/run_lastz_intermediate_layer.py`, `assets/scripts/compare_chains.py`). No logic changes — just line wrapping, consistent quoting, and style fixes.

### Minor fixes

- Fixed typo in `run_lastz_intermediate_layer.py`: `axtToPst` → `axtToPsl`.
- Removed `--axt_to_psl_path` parameter from the LASTZ module (hardcoded in the `pylastz` container).
- Removed `--lastz_path` parameter from `REPEAT_FILLER` module (hardcoded in the container).
- Fixed byte-order marker casing in `bin/run_lastz.py` for the `.2bit` version check.
- Updated output path from `final/` to `07_final/` and filename from `*.final.chain.gz` to `*.allfilled.chain.gz`.

### Pipeline diagram

- Added `assets/pipeline/make_lastz_chains.mermaid` — Mermaid flowchart documenting the full pipeline topology, including checkpoint entry points.

### Asset reorganization

- Moved changelog files (`Changelog.md`, `CHANGES_nfcore_refactor.md`, `TODO.md`) → `assets/changelog/`.
- Moved `readme_images/abstract_chains.png` → `assets/figures/`.
- Moved issue debug files (`chainAxtIssue/`) → `assets/issues/`.
- Moved `standalone_scripts/compare_chains.py`, `nf_watchdog.sh`, `run_nf_slurm_example.sh` → `assets/scripts/`.

### Config and schema

- Extended `nextflow_schema.json` to include all new pipeline parameters.
- Refactored `nextflow.config` with grandchild process-level resource overrides, new container mappings, and updated default parameter values.
- Updated `params.json` example to reflect all new parameters.


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
- Debug affordance: `--force_long_2bit` flag to exercise the v1 path on small genomes, `standalone_scripts/compare_chains.py` to exam final output files
- Result publication: per-step intermediates symlinked under `${params.outdir}/`; durable outputs (genome_prep, partition, fill_chains, final) copied
