# nf-core Refactor & Bug Fix — Change Summary

## Overview

This branch refactors `make_lastz_chains` from a Python-orchestrated pipeline (that used
Nextflow only as a generic parallel job runner) into a proper **nf-core-style DSL2 pipeline**
with separated per-step configuration, container support, and native Nextflow channel-based
parallelization.

The old Python entry point (`make_chains.py`) is **preserved** for backward compatibility.

---

## Bug Fix

### Issue #56 — Large genome (>4 GB) `.2bit` file support

**Root cause:** Two separate tools are involved in `.2bit` handling, and both needed fixing:

1. **Writer (`faToTwoBit`)** — without `-long`, the UCSC C tool uses 32-bit offsets and cannot
   index sequences past 4 GB, aborting with *"index overflow … use -long option"*.
2. **Reader (`twobitreader`)** — only accepts version-0 `.2bit` files; `faToTwoBit -long`
   produces version-1 (64-bit) files that `twobitreader` cannot read.

Both issues surfaced on large genomes (e.g. lungfish ~40 GB, salamander ~21 GB).

**Fix:**

| File | Change |
|------|--------|
| `modules/local/fa_to_two_bit/main.nf` | Added `-long` flag to `faToTwoBit` call so 64-bit `.2bit` files are written correctly |
| `standalone_scripts/run_lastz.py` | `from twobitreader import TwoBitFile` → `import py2bit`; updated sequence extraction call; added `extract_twobit_partition()` to extract `.2bit` partitions to temp FASTA before calling lastz (lastz cannot read v1/64-bit `.2bit`); temp files written to task work dir instead of `/tmp` |
| `bin/run_lastz.py` | Same fix as `standalone_scripts/run_lastz.py` applied to the Nextflow-staged copy |
| `requirements.txt` | Removed (`py2bit` is declared in `environment.yml` and `Dockerfile`) |
| `environment.yml` | `twobitreader` → `py2bit` |

---

## New Files

### Entry point & configuration

| File | Description |
|------|-------------|
| `main.nf` | nf-core entry point; validates params, prints run summary, defines entry alias workflows |
| `nextflow.config` | Single unified config: scientific params, compute resource tiers, per-step container/publishDir wiring, profiles, and reporting |
| `nextflow_schema.json` | JSON Schema for parameter validation and documentation |
| `Dockerfile` | Docker image with full UCSC Kent distribution (rsync), `NetFilterNonNested.perl` (pinned to commit fbdd299), LASTZ (v1.04.22), Python 3 + py2bit |
| `params.json` | Template for scientific parameters; pass with `-params-file params.json` |
| `run_nf_slurm_example.sh` | Example SLURM job array script for running many genome pairs in parallel; reads a tab-separated manifest (target_name, target_path, query_name, query_path) and launches one independent Nextflow run per pair |

### Nextflow modules (`modules/local/*/main.nf`)

One process per tool/step, nf-core style with `label`, `conda`, `container`, `publishDir`,
and `versions.yml` emission.

| Module | Tool(s) |
|--------|---------|
| `fa_to_two_bit` | `faToTwoBit` |
| `two_bit_info` | `twoBitInfo` → chrom.sizes |
| `partition` | `bin/partition.py` |
| `lastz` | `run_lastz_intermediate_layer.py` + `run_lastz.py` |
| `cat_psl` | `cat` + `gzip` (strips PSL headers, compresses) |
| `psl_sort_acc` | `pslSortAcc` |
| `psl_bundle` | `bin/psl_bundle.py` |
| `axt_chain` | `axtChain` \| `chainAntiRepeat` |
| `chain_merge_sort` | `chainMergeSort` \| `gzip` |
| `fill_chain_split` | `bin/split_chains.py` |
| `repeat_filler` | `chain_gap_filler.py` \| `chainScore` \| `chainSort` |
| `fill_chain_merge` | `chainMergeSort` \| `gzip` |
| `chain_cleaner` | `chainCleaner` |
| `chain_filter` | `chainFilter` \| `gzip` |

### Subworkflows (`subworkflows/local/*/main.nf`)

| Subworkflow | Steps |
|-------------|-------|
| `prepare_genomes` | FASTA→2bit (conditional) + chrom.sizes |
| `lastz_alignment` | Partition → LASTZ (N×K via `combine`) → CAT_PSL |
| `chain_build` | PSL_SORT_ACC → PSL_BUNDLE → AXT_CHAIN → CHAIN_MERGE_SORT |
| `fill_clean_chains` | FILL_CHAIN_SPLIT → REPEAT_FILLER → FILL_CHAIN_MERGE → CHAIN_CLEANER → CHAIN_FILTER |

### Main workflow

| File | Description |
|------|-------------|
| `workflows/make_lastz_chains.nf` | Orchestrates all 4 subworkflows in order |

### bin/ helper scripts

Standalone Python scripts extracted from `steps_implementations/` for use inside Nextflow
work directories (Nextflow adds `bin/` to PATH automatically).

| Script | Extracted from |
|--------|---------------|
| `bin/partition.py` | `steps_implementations/partition.py` |
| `bin/psl_bundle.py` | `steps_implementations/chain_run_bundle_substep.py` |
| `bin/split_chains.py` | `steps_implementations/fill_chain_split_into_parts_substep.py` |

Key change in `bin/partition.py`: outputs partition strings using the `.2bit` **filename**
(not the absolute path), so they resolve correctly when Nextflow stages files into work
directories.

---

## Key Design Decisions

### LASTZ parallelization
The old pipeline wrote a joblist file (one shell command per line) and fed it to a generic
Nextflow executor. The new pipeline uses Nextflow's `combine` channel operator to natively
create the N×K target×query partition pairs, eliminating joblist files entirely.

### Checkpoint entry points (replaces `--continue_from_step`)
The old Python `StepManager` tracked named step states in a JSON file and supported
`--continue_from_step` to resume from any named stage.

In the new pipeline, Nextflow's built-in `-resume` replaces this for mid-run recovery
(it caches task outputs by content hash and skips completed tasks on re-run). For
restarting from a published intermediate file, two named entry workflows are provided:

| Entry alias | Starts from | Input param |
|-------------|-------------|-------------|
| `-entry FROM_FILL_CHAINS` | `results/chain_merge/*.all.chain.gz` | `--merged_chain` |
| `-entry FROM_CLEAN_CHAINS` | `results/fill_chains/*.filled.chain.gz` | `--filled_chain` |

Both aliases also require `--target_twobit`, `--query_twobit`, `--target_chrom_sizes`,
`--query_chrom_sizes`, `--target_name`, `--query_name`.

Validation functions (`validateFullRun`, `validateFromFillChains`, `validateFromCleanChains`)
are defined inside each workflow block so that only the params relevant to the active entry
point are checked.

### Parameter file support
The old `--params_from_file` flag is replaced by Nextflow's native `-params-file <json>`:
```bash
nextflow run main.nf -params-file my_params.json
```

### Config organisation
Everything lives in a single `nextflow.config`, organised into five clearly labelled sections:

| Section | Contains |
|---------|----------|
| 1. `params {}` | All scientific / I/O parameters |
| 2. `withLabel` blocks | Compute resource tiers (cpus, memory, time) |
| 3. `withName` blocks | Per-step container, conda, publishDir wiring |
| 4. `profiles {}` | Executor and environment selection |
| 5. Reporting | timeline, trace, DAG output |

The old `conf/base.config` and `conf/modules.config` are removed — their content is now
inlined into `nextflow.config`. Memory for each step is set by its `withLabel` tier and
is not exposed as a user-facing param. To tune memory for a specific step, edit the
`withName` block for that step and add a `memory` override.

### Containers
All tools run inside a single container built from the `Dockerfile`. The image includes:
- Full UCSC Kent binary distribution installed via `rsync` (replaces individual `wget` per binary)
- `NetFilterNonNested.perl` pinned to commit `fbdd299` via the correct `raw.githubusercontent.com` URL — the `/blob/` HTML page URL used in some build scripts is a bug that silently downloads the wrong file
- LASTZ v1.04.22 built from source
- Python 3 + py2bit

Each process in `nextflow.config` declares both `conda` and `container` directives. The active
profile (`-profile conda` or `-profile apptainer`) determines which is used. Conda is disabled
by default; apptainer is the intended production environment.

### SLURM job arrays
LASTZ, AXT_CHAIN, and REPEAT_FILLER use `process.array` (Nextflow ≥ 25.04.6) to submit
tasks as SLURM job arrays rather than individual `sbatch` calls. This significantly reduces
scheduler overhead and Fairshare score impact for runs with thousands of alignment jobs.

### SLURM partition routing
Jobs are automatically routed to the appropriate partition based on their wall-time request,
without requiring the user to specify a queue:
- `process_fast` (2 h) → `htc` partition, `public` QOS
- All other labels (48 h+) → `public` partition, `public` QOS

Resource requests are capped against `params.max_memory` and `params.max_time` via the
`check_max()` helper function, preventing jobs from exceeding partition hard limits.

---

## Parameter audit — old pipeline vs params.json

### Parameters actually used in tool commands

All parameters that reach actual tool command lines are present in `params.json`:

| Module | Parameters used |
|--------|----------------|
| PARTITION | `seq1/2_chunk`, `seq1/2_lap` |
| LASTZ | `lastz_k`, `lastz_h`, `lastz_l`, `lastz_y`, `axt_to_psl_path` |
| PSL_BUNDLE | `bundle_psl_max_bases` |
| AXT_CHAIN | `min_chain_score`, `chain_linear_gap` |
| REPEAT_FILLER | `min_chain_score`, `fill_gap_max/min_size_t/q`, `fill_insert_chain_min_score`, `fill_lastz_k/l`, `chain_linear_gap`, `skip_fill_unmask`, `lastz_path` |
| CHAIN_CLEANER | `chain_linear_gap`, `clean_chain_parameters` |
| CHAIN_FILTER | `min_chain_score` |

### Parameters removed vs old pipeline

| Parameter | Reason removed |
|-----------|---------------|
| `--seq1_limit` / `--seq2_limit` | Accepted by old CLI but never applied in partitioning logic in either pipeline. Not implemented. |
| `--fill_chain_min_score` | Stored in old `PipelineParameters` but never passed to any tool in either pipeline. Dead param. |
| `--fill_prepare_memory` | Defined in old constants but hardcoded to 16 GB in practice; never user-configurable. Replaced by `process_single` label. |
| `--chaining_memory` | Moved to `process_medium` label in `nextflow.config` (50 GB default). Override with a `memory` line in the `AXT_CHAIN` `withName` block if needed. |
| `--fill_memory` | Moved to `process_single` label in `nextflow.config` (16 GB default). |
| `--chain_clean_memory` | Moved to `process_high` label in `nextflow.config` (100 GB default). |

All default values are preserved — only where they are defined has changed.

### Dead parameters (never consumed by any tool)

| Parameter | Old default | Finding |
|-----------|-------------|---------|
| `--seq1_limit` | 5000 | Parsed and stored in `PipelineParameters` but never read by any module or tool command in either pipeline |
| `--seq2_limit` | 10000 | Same |
| `--fill_chain_min_score` | 25000 | Same — distinct from `fill_insert_chain_min_score` which is active |

---

## What Was Preserved (Backward Compatibility)

The following files are unchanged and the old `make_chains.py` CLI still works:

- `make_chains.py` — original Python entry point
- `modules/` — Python orchestration modules
- `steps_implementations/` — Python step implementations
- `parallelization/execute_joblist.nf` — generic joblist Nextflow executor
- `parallelization/nextflow_wrapper.py` — Python→Nextflow wrapper
- `standalone_scripts/` — tool wrapper scripts (used by both old and new pipeline)

---

## TODO (before production use)

- [x] Build the Docker image (`nilablueshirt/make_lastz_chains:latest-amd64`) and update `nextflow.config`
- [x] Add `ucsc-twobitinfo` to `environment.yml`
- [x] Switch Dockerfile to full Kent rsync distribution
- [x] Fix `NetFilterNonNested.perl` URL to use `raw.githubusercontent.com` pinned to commit `fbdd299`
- [ ] Run `nextflow run main.nf -profile test,apptainer` to validate end-to-end
- [ ] Run `nextflow run main.nf -profile test,apptainer,slurm` to validate SLURM job array submission
- [ ] Add nf-core linting (`nf-core lint`) and fix reported issues before nf-core submission
