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

**Root cause:** `twobitreader` (the previous Python dependency) only accepts version-0 `.2bit`
files. `faToTwoBit -long` produces version-1 (64-bit) `.2bit` files required for genomes
larger than 4 GB. This caused the pipeline to crash on large genomes (e.g. lungfish ~40 GB,
salamander ~21 GB) during BULK partition LASTZ jobs.

**Fix:** Replaced `twobitreader` with `py2bit`, which supports both version-0 and version-1
`.2bit` files.

| File | Change |
|------|--------|
| `standalone_scripts/run_lastz.py` | `from twobitreader import TwoBitFile` → `import py2bit`; updated sequence extraction call |
| `requirements.txt` | `twobitreader` → `py2bit` |
| `environment.yml` | `twobitreader` → `py2bit` |

---

## New Files

### Entry point & configuration

| File | Description |
|------|-------------|
| `main.nf` | nf-core entry point; validates params, prints run summary |
| `nextflow.config` | All pipeline parameters with defaults; execution profiles (local, slurm, sge, conda, apptainer, singularity, docker, test) |
| `nextflow_schema.json` | JSON Schema for parameter validation and documentation |
| `conf/base.config` | Process resource labels: `process_single` (16 GB), `process_medium` (50 GB), `process_high` (100 GB) |
| `conf/modules.config` | Per-step resource and environment config using `withName` selectors. Each step has individual `conda` and `container` directives. |
| `Dockerfile` | Docker image with all Kent binaries (v482), LASTZ (v1.04.22), Python 3 + py2bit. Builds the apptainer-ready container. |

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

### Resume
Nextflow's built-in `-resume` flag replaces `--continue_from_step`. Nextflow caches
completed process outputs in the `work/` directory and skips them on re-runs.

### Config separation
Each pipeline step has its own `withName` block in `conf/modules.config` with independent
`memory`, `time`, `conda`, and `container` settings. Resources for the most expensive steps
are also tunable at runtime via params:

| Param | Controls |
|-------|---------|
| `--chaining_memory` | Memory per `AXT_CHAIN` job |
| `--fill_memory` | Memory per `REPEAT_FILLER` job |
| `--chain_clean_memory` | Memory for `CHAIN_CLEANER` |

### Containers
`conf/modules.config` declares both `conda` and `container` per process. The active profile
(`-profile conda` or `-profile apptainer`) determines which is used at runtime — they do
not interfere with each other.

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

- [ ] Fill in actual conda env path and container SIF path in `conf/modules.config`
  (search for `/path/to/your/...` placeholders)
- [ ] Build the Docker image and push to a registry (see `Dockerfile`)
- [ ] Add `ucsc-twobitinfo` to `environment.yml` (currently missing)
- [ ] Run `nextflow run main.nf -profile test` to validate end-to-end
- [ ] Add nf-core linting (`nf-core lint`) and fix reported issues before nf-core submission
