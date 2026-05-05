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
2. **Reader (`lastz`)** — lastz can read v0 (32-bit) `.2bit` files natively but cannot read v1
   (64-bit) `.2bit` files produced by `faToTwoBit -long`.

Both issues surfaced on large genomes (e.g. lungfish ~40 GB, salamander ~21 GB).

**Fix:** size-aware writer + version-aware reader.

Writer (`modules/local/fa_to_two_bit/main.nf`): `faToTwoBit -long` is now only enabled when
the input FASTA exceeds 4 GB. Smaller genomes get a v0 `.2bit` (upstream's default);
larger ones get v1.

Reader (`bin/run_lastz.py`, `standalone_scripts/run_lastz.py`):

- **v0 `.2bit` (≤4 GB, the common case):** pass through to lastz unchanged with
  `<file>/<chrom>[start+1,end][multiple]` — byte-identical behaviour to upstream, no
  extraction overhead.
- **v1 `.2bit` (>4 GB):** extract the **whole chromosome** (not just the partition) to a
  temp FASTA via `twoBitToFa -seq=<chrom>`. This yields a bare `>chrom` header. lastz then
  applies the subrange itself on the FASTA, so output sequence names and absolute
  coordinates match what native `.2bit` reading would have produced.

The version is detected by reading the 8-byte `.2bit` header (4-byte magic `0x1A412743`
followed by 4-byte version field). The two halves must stay in sync: if the writer
unconditionally produced v1, the reader's v0 fast-path would be dead code and every run
would pay the FASTA-extraction cost (and lose the byte-identical parity guarantee).

> **Why not always extract?** An earlier version of the fix unconditionally extracted each
> partition to a FASTA via `twoBitToFa -seq=<chrom> -start=<S> -end=<E>`. The kent
> `twoBitReadSeqFrag` helper writes the FASTA header as `>chrom:start-end` whenever the
> requested range is not the full chromosome, and the resulting FASTA forces lastz to emit
> 0-based partition-relative coordinates. Both effects break downstream parsing
> (`bin/psl_bundle.py` looks for `<chrom>.psl` from `chrom.sizes` and silently skips files
> named `<chrom>:start-end.psl`), producing a much smaller `.all.chain.gz` than upstream.

| File | Change |
|------|--------|
| `modules/local/fa_to_two_bit/main.nf` | `-long` flag added but conditional on FASTA size > 4 GB. Smaller genomes get v0 (upstream default); only large genomes get v1 |
| `bin/run_lastz.py` | Detects `.2bit` version. v0: lastz reads `.2bit` directly (upstream parity). v1: extract whole chromosome to temp FASTA, then call lastz with subrange syntax on the FASTA |
| `standalone_scripts/run_lastz.py` | Same fix as `bin/run_lastz.py` |
| `requirements.txt` | Removed (no Python `.2bit` library needed; `twoBitToFa` is a UCSC tool already in the container) |
| `environment.yml` | Removed `py2bit`; `ucsc-twobittofa` already present |
| `pyproject.toml` | Removed `py2bit`/`twobitreader` from `dependencies` |
| `modules/project_setup_procedures.py` | Removed `twobitreader` imports; replaced `TwoBitFile` usage with `twoBitInfo` subprocess calls (chrom names, chrom sizes, and `.2bit` format check) |
| `Dockerfile` | Removed `pip3 install py2bit`; no Python `.2bit` library needed |

### BULK partition output silently dropped (filename-too-long)

**Symptom:** `*.all.chain.gz` significantly smaller than upstream output for genomes with
many small scaffolds (e.g. ~20 MB vs ~26 MB). Per-target-chromosome chain counts revealed
that chains for thousands of small scaffolds were missing while the few large
chromosomes were present.

**Root cause:** [modules/local/lastz/main.nf](modules/local/lastz/main.nf) built the LASTZ
output filename from the full partition string via
`target_part.replaceAll('[:/]', '_')`. For BULK partitions — which can list up to 100
scaffold names ([bin/partition.py](bin/partition.py) `MAX_CHROM_IN_BULK = 100`) — the
resulting filename ran 800+ characters, well past the 255-byte filesystem cap. When
[bin/run_lastz.py](bin/run_lastz.py) tried `open(args.output, "a")` it raised
`OSError: [Errno 36] File name too long`. That error was silently swallowed by
[bin/run_lastz_intermediate_layer.py](bin/run_lastz_intermediate_layer.py) because
`subprocess.call(lastz_cmd)` doesn't raise on non-zero exit — every BULK chrom in the
loop hit the same too-long path, the wrapper exited 0, and Nextflow recorded the task
as successful with no `.psl` (allowed by `optional: true`). Every BULK partition's
alignments were lost.

**Fix:** mirror the old pipeline's
[steps_implementations/lastz_step.py](steps_implementations/lastz_step.py)
`_get_lastz_out_fname_part`: shorten the partition string to a stable identifier
**before** putting it in the filename. BULK partitions become `BULK_<n>`; regular
partitions become `<chrom>_<start>-<end>`. Filenames now stay under ~80 chars even
in the worst case. No need for a per-job uniqueness counter — each Nextflow task has
its own work directory.

| File | Change |
|------|--------|
| `modules/local/lastz/main.nf` | Replaced `replaceAll('[:/]', '_')` on the full partition string with a `safe_part` closure that emits `BULK_<n>` for bulk partitions and `<chrom>_<start>-<end>` for regular ones |

### v1 path: lastz `file/seqname` syntax is `.2bit`-only (FASTA inputs failed)

**Symptom (caught by `--force_long_2bit` parity test):** every v1-path LASTZ task crashed
with:

```
FAILURE: fopen_or_die failed to open ".../<random>_<chrom>.fa/<chrom>" for "rb"
```

The task then thrashed through `errorStrategy = 'retry'` retries until SLURM SIGTERM'd
it (exit 143), and the cycle repeated. No `.psl` was produced for any v1 partition pair.

**Root cause:** lastz's `<file>/<seqname>` selector is documented and implemented as
**`.2bit`-only** — it relies on the `.2bit` index. For FASTA inputs lastz takes the
string literally and tries to open it as a filesystem path. Our v1 fix in
[bin/run_lastz.py](bin/run_lastz.py) `main()` extracts the whole chromosome to FASTA but
left `chrom` set in the specs, so `build_lastz_command` emitted
`<extracted.fa>/<chrom>[start,end][multiple]`. lastz tried to `fopen` the literal path
`<extracted.fa>/<chrom>` and failed.

**Fix:** route the lastz argument construction through a small `_seq_arg` helper that
checks the file extension. `.2bit` → keep `<file>/<chrom>[start+1,end][multiple]`. FASTA
→ `<file>[start+1,end][multiple]` (no `/seqname` selector). The extracted FASTA contains
only the requested chromosome, so the subrange applies unambiguously to that one
sequence and lastz emits absolute coordinates the same way it does for `.2bit` subrange.

| File | Change |
|------|--------|
| `bin/run_lastz.py` | Refactored `build_lastz_command` to dispatch on file extension via `_seq_arg`. `.2bit` keeps `file/chrom[range][multi]`; FASTA uses `file[range][multi]` (the `/seqname` selector is `.2bit`-only and lastz reads it as a literal path on FASTA, causing `fopen` to fail) |
| `standalone_scripts/run_lastz.py` | Same fix as `bin/run_lastz.py` |

### v1 path: cache whole-chromosome FASTA extractions

**Symptom 1 (slow):** for v1 BULK partitions with many scaffolds (e.g. BULK_16 with 60
scaffolds), the LASTZ task hit the `process_fast` 30-min time limit and got SIGTERM'd
(exit 143) by SLURM. Nextflow retried, but the wasted work added up across runs.

**Symptom 2 (large work dir):** v1 runs ballooned to many GB of cached FASTA across
~50k LASTZ task work dirs — every task was extracting its own copy of the same
chromosomes from the v1 `.2bit`.

Both stem from the same root cause: redundant `twoBitToFa` extractions.
[bin/run_lastz_intermediate_layer.py](bin/run_lastz_intermediate_layer.py) unfolds a
BULK partition into one `run_lastz.py` call per target scaffold; every call re-extracted
the **query** chromosome (shared across the whole BULK loop) from scratch. And every
LASTZ task — BULK or regular — extracted its own copy of the chromosomes it touched,
even though tens of thousands of tasks all referenced the same handful of chromosomes.

**Fix:** two-layer cache.

1. **Pipeline-level (preferred):** new `EXTRACT_CHROMS` process runs **once per genome**
   in the prepare-genomes stage. For v1 `.2bit` it extracts every chromosome to its own
   FASTA in a directory; for v0 it emits an empty directory. The
   [PREPARE_GENOMES](subworkflows/local/prepare_genomes/main.nf) subworkflow now emits
   a `chroms_dir` channel alongside `prepared`. The
   [main workflow](workflows/make_lastz_chains.nf) forwards both target and query
   `chroms_dir` to [LASTZ_ALIGNMENT](subworkflows/local/lastz_alignment/main.nf), which
   passes them as `path` inputs to [LASTZ](modules/local/lastz/main.nf). Nextflow
   symlinks the directories into every LASTZ task work dir — one extraction per genome
   instead of one per task. Storage drops from O(N tasks × genome) to O(1 × genome).

2. **Per-task fallback:** `extract_chrom_to_fasta` in `run_lastz.py` still falls back to
   `./_v1_chrom_cache/` in the task work dir when the shared dir doesn't contain the
   chromosome (e.g. legacy `make_chains.py` flow that doesn't supply the new
   `--target_chrom_dir`/`--query_chrom_dir` args). The fallback still deduplicates within
   a single BULK loop, so the BULK-task timeout is fixed even without the pipeline-level
   shared cache.

| File | Change |
|------|--------|
| `modules/local/extract_chroms/main.nf` | **New module.** Detects `.2bit` version; for v1, extracts every chromosome to `<genome_name>_chroms/<chrom>.fa` via `twoBitToFa -seq=<chrom>`; for v0, emits an empty directory (no-op) |
| `subworkflows/local/prepare_genomes/main.nf` | Calls `EXTRACT_CHROMS` after `TWO_BIT_INFO`; adds `chroms_dir` output channel |
| `workflows/make_lastz_chains.nf` | Forwards `target_chroms_dir` and `query_chroms_dir` from `PREPARE_GENOMES` to `LASTZ_ALIGNMENT` |
| `subworkflows/local/lastz_alignment/main.nf` | Accepts `target_chroms_dir`/`query_chroms_dir` and passes them as `path` inputs to `LASTZ` |
| `modules/local/lastz/main.nf` | Adds `target_chroms_dir`/`query_chroms_dir` `path` inputs; forwards them to `run_lastz_intermediate_layer.py` via `--target_chrom_dir`/`--query_chrom_dir` |
| `bin/run_lastz_intermediate_layer.py` | Accepts `--target_chrom_dir`/`--query_chrom_dir` and forwards them to `run_lastz.py` |
| `standalone_scripts/run_lastz_intermediate_layer.py` | Same as the `bin/` copy |
| `bin/run_lastz.py` | `extract_chrom_to_fasta` checks the shared dir first (`<dir>/<chrom>.fa`); falls back to per-task `./_v1_chrom_cache/` extraction. Args `--target_chrom_dir`/`--query_chrom_dir` added to CLI |
| `standalone_scripts/run_lastz.py` | Same as the `bin/` copy |

### Strict error handling + LASTZ integrity check

**Symptom (latent):** the previous config (`errorStrategy = 'retry'`, `maxRetries = 8`,
`maxErrors = '-1'`) tolerated unlimited permanently-failed tasks. After a task exhausted
its 8 retries it was simply marked FAILED and the workflow continued without its output.
The BULK filename-too-long bug rode on this — every BULK LASTZ task failed silently and
the run completed "successfully" with a `.all.chain.gz` ~23% smaller than upstream's,
with no error to flag the loss.

**Fix:** two layers of defence.

1. **`errorStrategy` now terminates after retries.** Replaced the static
   `errorStrategy = 'retry'` + unlimited `maxErrors` with a dynamic strategy:
   ```groovy
   errorStrategy = { task.attempt <= 8 ? 'retry' : 'terminate' }
   maxRetries    = 8
   ```
   A task that can't recover after 8 attempts now aborts the entire workflow loudly,
   not silently. `maxErrors` is removed (no longer needed; the dynamic strategy is
   unambiguous).

2. **Post-LASTZ integrity check** in
   [subworkflows/local/lastz_alignment/main.nf](subworkflows/local/lastz_alignment/main.nf).
   Before the LASTZ stage runs, the (target × query) pair list is materialised and its
   length recorded as `expected_n`. After LASTZ, `LASTZ.out.versions` (which every
   successful task always emits) is counted as `actual_n`. If they don't match, the
   workflow aborts with a message like:
   ```
   LASTZ integrity check failed: expected 49410 alignment tasks, only 49382 produced
   output. 28 pair(s) were lost silently. Aborting before downstream chain building
   reads incomplete data.
   ```
   This is belt-and-braces — the strict `errorStrategy` should already prevent silent
   loss, but the assertion catches anything the error strategy misses (Nextflow channel
   bugs, processes that exit 0 without writing expected outputs, etc.).

| File | Change |
|------|--------|
| `nextflow.config` | Replaced `errorStrategy = 'retry'`/`maxErrors = '-1'` with `errorStrategy = { task.attempt <= 8 ? 'retry' : 'terminate' }` so permanently-failed tasks abort the workflow instead of being silently dropped |
| `subworkflows/local/lastz_alignment/main.nf` | Added post-LASTZ integrity check: counts expected pairs (target × query) vs. actual `LASTZ.out.versions` count and aborts if they differ |

### Debug affordance — `--force_long_2bit`

Added a CLI/params flag that overrides the FASTA-size threshold and always passes
`-long` to `faToTwoBit`. This produces a v1 `.2bit` regardless of genome size, so the
v1 FASTA-extraction path can be exercised on small genomes for parity testing against
the v0 path. Default is `false` — production runs are unaffected.

```bash
nextflow run main.nf -params-file params.json --outdir results_v1 --force_long_2bit
```

| File | Change |
|------|--------|
| `nextflow.config` | Added `params.force_long_2bit = false` default (debug, not exposed in `params.json` since that file is reserved for scientific parameters) |
| `nextflow_schema.json` | Added schema entry so `--force_long_2bit` is a recognised CLI flag |
| `modules/local/fa_to_two_bit/main.nf` | `need_long = params.force_long_2bit \|\| genome_fa.size() > 4 GB` — flag bypasses the size check |

---

## New Files

### Entry point & configuration

| File | Description |
|------|-------------|
| `main.nf` | nf-core entry point; validates params, prints run summary, defines entry alias workflows |
| `nextflow.config` | Single unified config: scientific params, compute resource tiers, per-step container/publishDir wiring, profiles, and reporting |
| `nextflow_schema.json` | JSON Schema for parameter validation and documentation |
| `Dockerfile` | Docker image with full UCSC Kent distribution (rsync), `NetFilterNonNested.perl` (pinned to commit fbdd299), LASTZ (v1.04.22), Python 3 (no py2bit; `.2bit` reading via `twoBitToFa`) |
| `params.json` | Template for scientific parameters; pass with `-params-file params.json` |
| `run_nf_slurm_example.sh` | Example SLURM job array script for running many genome pairs in parallel; reads a tab-separated manifest (target_name, target_path, query_name, query_path) and launches one independent Nextflow run per pair |

### Nextflow modules (`modules/local/*/main.nf`)

One process per tool/step, nf-core style with `label`, `conda`, `container`, `publishDir`,
and `versions.yml` emission.

| Module | Tool(s) |
|--------|---------|
| `fa_to_two_bit` | `faToTwoBit` |
| `two_bit_info` | `twoBitInfo` → chrom.sizes |
| `extract_chroms` | `twoBitToFa` per chrom (v1 .2bit only; no-op for v0) |
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
| `prepare_genomes` | FASTA→2bit (conditional) + chrom.sizes + per-chrom FASTAs (v1 only) |
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
- Python 3 (no `.2bit` Python library; reading is done via `twoBitToFa`)

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
- [x] Add `ucsc-twobitinfo` to `environment.yml`; remove `py2bit` (replaced by `twoBitToFa`)
- [x] Switch Dockerfile to full Kent rsync distribution
- [x] Fix `NetFilterNonNested.perl` URL to use `raw.githubusercontent.com` pinned to commit `fbdd299`
- [ ] Run `nextflow run main.nf -profile test,apptainer` to validate end-to-end
- [ ] Run `nextflow run main.nf -profile test,apptainer,slurm` to validate SLURM job array submission
- [ ] Add nf-core linting (`nf-core lint`) and fix reported issues before nf-core submission
