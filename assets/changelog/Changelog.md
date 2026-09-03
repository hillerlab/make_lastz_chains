<p align="center">
<p align="center">
  <picture>
    <source
      media="(prefers-color-scheme: dark)"
      srcset="../figures/hillerlab-dark.png"
    >
    <source
      media="(prefers-color-scheme: light)"
      srcset="../figures/hillerlab-light.png"
    >
    <img
      width="200"
      alt="Hiller Lab"
      src="../figures/hillerlab-light.png"
    >
  </picture>
</p>

  <span>
    <h1 align="center">
        make_lastz_chains
    </h1>
  </span>

  <p align="center">
    <a href="https://github.com/hillerlab/make_lastz_chains" reference="_blank">
      <img alt="GitHub License" src="https://img.shields.io/github/license/hillerlab/make_lastz_chains?color=blue">
    </a>
  </p>

  <p align="center">
    <samp>
        <span> portable solution for generating pairwise genome alignment chains  </span>
        <br>
        <span> The Hiller Lab at the Senckenberg Research Institute </span>
        <br>
        <br>
        <a href="https://genome.ucsc.edu/goldenPath/help/chain.html">format</a> .
        <a href="http://genomewiki.ucsc.edu/index.php/Chains_Nets">chains</a> .
        <a href="https://github.com/hillerlab/make_lastz_chains/blob/main./pipeline/make_lastz_chains.mermaid">pipeline</a>
    </samp>
  </p>

</p>

---

# 4.0.0

Added two GPU alignment backends — [KegAlign](https://github.com/hillerlab/kegalign) (CUDA seeding + HSP filtering) with two CPU gapped-extension executors, and hspZ 0.0.1 (GPU seeding, CPU gapped extension) — and fixed the PSL-splitting path that broke at whole-genome scale.

### GPU alignment backend

- `--aligner kegalign` routes the alignment stage through `KEGALIGN_ALIGNMENT` (`subworkflows/local/kegalign_alignment/`): `.2bit` genomes are round-tripped to FASTA, KegAlign runs on the GPU (`KEGALIGN`, `quay.io/biocontainers/kegalign-full`), and the emitted AXT packages are converted to PSL (`AXT_TO_PSL`). Downstream chain building is unchanged and consumes the identical `psl_gz` contract.
- `--kegalign_executor batched` (default) runs the whole CPU gapped-extension stage as one `KEGALIGN_LASTZ` task. `--kegalign_executor distributed` fans the KegAlign partitions out as one `KEG_LASTZ` task each (`run_keg_lastz.py`), spreading work across nodes and SLURM job arrays.
- KegAlign requires the `gpu` profile (`--gpus all` / `--nv`); requesting `--aligner kegalign` without it fails at startup rather than silently falling back to LASTZ.
- New modules: `kegalign`, `kegalign_lastz`, `kegalign_expand`, `keg_lastz`, `two_bit_to_fa`, `axt_to_psl`. The four LASTZ scoring thresholds are shared with the CPU path: `lastz_k` → `--hspthresh`, `lastz_l` → `--gappedthresh`, `lastz_h` → `--inner`, `lastz_y` → `--ydrop`.

### GPU multi-instance execution (NVIDIA MPS)

- `--kegalign_mps_workers N` (1–4, default `1`) runs N KegAlign instances concurrently on the **single allocated GPU** through the NVIDIA MPS daemon: one SLURM job, one GPU, N `kegalign` processes. `1` never starts an MPS daemon and is by construction the unchanged single-instance path — `run_mig.py` starts a daemon even for `--MPS 1`, so the branch in `KEGALIGN_ALIGNMENT` routes workers=1 through `KEGALIGN` and never through MPS.
- New `KEGALIGN_MPS` module (`modules/local/kegalign_mps/`): GPU/MPS preflight → upstream `split_input.py` bins both genomes (`--goal_bp 200000000 --max_chunks 20`, chromosomes never split) → upstream `run_mig.py` schedules the reference-bin × query-bin pairs → one keg per pair. Scoring, format and diagonal partitioning are untouched: MPS changes work scheduling only, and the four thresholds are forwarded through `run_mig --opt_cmd` (the worker makes them `required`, so a lost `--opt_cmd` fails instead of silently using KegAlign defaults).
- New `bin/run_kegalign_mps_pair.py` — a GPU-only worker passed to `run_mig.py --kegalign_cmd`, replacing upstream's `run_kegalign_symlink_sort`, which starts LASTZ processes while KegAlign is still on the GPU. It runs one chunk pair in an isolated `pair_NNNN/` (`runner.py --diagonal-partition` → `package_output.py`) and stops at `keg_NNNN.tgz`. **No LASTZ runs inside the GPU allocation.** `--self-check` asserts the argv contract `run_mig.py` builds.
- Vendored `bin/split_input.py` and `bin/run_mig.py` from KegAlign `ea16d54` (MIT, provenance in the file headers): the `kegalign-full` conda package does not ship `scripts/mps-mig/`. Nextflow puts `bin/` on the task PATH.
- **Integrity guard (mandatory).** `run_mig.py` exits 0 even when it loses chunk pairs — it only prints `Missing N output parts` and swallows the combine failure — so `KEGALIGN_MPS` fails unless `keg count == reference bins × query bins`, the same last-line defence the distributed executor keeps over its partition list. A chunk pair that legitimately yields no HSP above `--hspthresh` leaves a `keg_*.empty` marker so the count still balances instead of aborting a whole run (unlike a whole-genome run, an empty *bin pair* is normal).
- The CPU stage is per keg either way: `KEGALIGN_LASTZ` / `AXT_TO_PSL` now name their output after the keg rather than after `(reference, query)`, so the one-task-per-keg fan-out cannot collide in `02_kegalign_psl/`. A single keg keeps exactly the previous `${reference}.${query}` names.
- `--kegalign_mps_workers > 1` requires `--kegalign_executor batched` and is rejected with `distributed`, whose job ids and package directory are global to one keg. Preflight fails early when `nvidia-smi`, `nvidia-cuda-mps-control`, `pynvml` or a visible GPU is missing, and warns when VRAM / workers is under 14 GiB (upstream reports 12–16 GiB per instance).

### Upstream KegAlign bugs fixed locally

Both are fatal and marked `make_lastz_chains patch` inline; `split_input.py` is byte-verbatim. Found by running the MPS path, not by reading it — worth reporting upstream:

- `run_mig.py` `NamedPopen.__init__` forwarded `name=` into `subprocess.Popen`, which rejects the keyword: `TypeError` on the first submitted pair. Upstream cannot schedule anything as shipped.
- `run_mig.py` `GPU_queue.__len__` read a module-level `gpu_queue` that does not exist (it is a local in `main()`): `NameError` as soon as a pair is submitted.

Two more upstream limitations are worked around rather than patched, since the scripts live in the container:

- `package_output.py` `realpath()`s the *archive name* as well as the source, so a symlinked `work/ref.2bit` resolving outside the pair directory aborts with `path fail`. The worker hard-links instead (zero copy, falls back to a copy across filesystems).
- `runner.py` sizes diagonal partitions with `statistics.quantiles`, which needs ≥2 `.segments` groups; a sparse bin pair has one or none and it dies there. The worker retries that pair unpartitioned — same alignments, one LASTZ command instead of several. **The single-instance `KEGALIGN` module has the same latent failure for small or sparse genome pairs** and is left untouched here.

### ZLUDA profile — GPU backend on AMD hardware

- `-profile docker,gpu,zluda` runs the three KegAlign processes natively against a local [ZLUDA](https://github.com/vosen/ZLUDA) build while every other stage stays containerised, so the GPU backend is developable and testable without NVIDIA hardware. `assets/tests/ci/zluda_setup.sh` builds what it needs into `~/.cache/make_lastz_chains/zluda`: a `kegalign` shim carrying the ZLUDA recipe (`LD_PRELOAD` reaches only the GPU binary, never the musl-linked UCSC tools), musl-loader wrappers for the pipeline image's `faToTwoBit`/`lastz`, the KegAlign helper scripts, and `bashlex` on `PYTHONPATH` (Nextflow exports `PYTHONNOUSERSITE=1`, so a `pip --user` install is invisible to tasks).
- Implementation notes worth keeping: the process-level part lives in **SECTION 5b**, after SECTION 5, because two `withName` selectors matching the same process do not reliably override each other's `container` — SECTION 5's kegalign selector now decides `null` vs the CUDA image itself. `params.zluda` gates it rather than `workflow.profile`, which is not bound while the config is parsed.
- `-profile ...,zluda_mps_stub` (with `WITH_MPS_STUBS=1`) stubs `nvidia-smi`, the MPS daemon and NVML — the three things ZLUDA cannot provide — so the MPS *plumbing* can be exercised on AMD with real KegAlign on the GPU. It proves nothing about the MPS daemon and makes the preflight pass on a host with no MPS.

### Verification on AMD (RX 6500 XT + ZLUDA, Nextflow 25.04.6)

Every route run end to end on the bundled synthetic fixture, from scratch:

| route | exit | PSL | chains | GPU-stage evidence |
| --- | --- | --- | --- | --- |
| `lastz` (CPU baseline) | 0 | 67 rec | 31 | — |
| `kegalign batched` | 0 | 75 rec | 31 | real KegAlign on the GPU |
| `kegalign distributed` | 0 | 75 rec | 31 | `partition integrity check passed: 4/4` |
| `kegalign_mps_workers 2` | 0 | 75 rec | 31 | `1 ref bins x 1 query bins = 1 pairs`; `integrity check passed: 1/1 kegs`; keg contains 4 partitioned `.segments` + unexecuted `commands.json`, no `.axt` |

- **Normalised PSL and final chains are IDENTICAL across batched, distributed and MPS**; `lastz` vs `kegalign` chain aligned bases differ by +0.5% (CI tolerance 20%).
- Concurrency, with binning forced to 2×2 (`goal_bp` lowered, since the fixture bins to 1×1 at the production 200 Mb goal): **peak 2 concurrent `kegalign` PIDs, 0 `lastz`**, `4/4` pairs accounted for (2 kegs + 2 genuine no-HSP pairs). Those kegs' PSL is aggregate-identical to the single-instance route (same records, matches, insert bases and spans); exactly 1 of 75 records differs, with the same score, endpoints and gap totals but a different equal-scoring internal tie-break — so multiple bins give *equivalent*, not byte-identical, output.
- Not covered: NVIDIA MPS itself. The daemon, `nvidia-smi` and NVML do not exist on AMD, so the first NVIDIA run remains the real test of the daemon lifecycle and of `CUDA_MPS_PIPE_DIRECTORY` path length under deep work directories.

On a 5 Mb synthetic pair (20 independent homologous chromosome pairs, ~10% divergence, inversions in every third) **all three routes produce byte-identical PSL — including `lastz` vs `kegalign`**: 35 records, 4,600,791 matched bases, 5,000,095 bp of reference span covered by both backends. At 10 Mb (40 pairs) batched and distributed stay byte-identical and `kegalign` finds 0.8% more matched bases than `lastz` (9,278,590 vs 9,202,054).

### Benchmark: is the GPU backend actually worth it

Same synthetic pairs, one 16-core workstation, RX 6500 XT via ZLUDA, fill/clean skipped. `wall` is whole-pipeline; `align cpu-time` is the summed task time of the alignment stage only (`LASTZ`, or `KEGALIGN` + `KEGALIGN_LASTZ`/`KEG_LASTZ`):

| genome pair | route | wall | align cpu-time |
| --- | --- | --- | --- |
| 5 Mb | `lastz` (default chunking → 1 task) | 247 s | 173 s |
| 5 Mb | `lastz` (1 Mb chunks → 63 tasks) | 453 s | 194 s |
| 5 Mb | `kegalign batched` | **25 s** | **8.2 s** (5.2 GPU + 3.0 CPU) |
| 5 Mb | `kegalign distributed` | 26 s | 12.1 s |
| 10 Mb | `lastz` (4 tasks) | 413 s | 725 s |
| 10 Mb | `kegalign batched` | **35 s** | **12.7 s** (10.4 GPU + 2.3 CPU) |
| 10 Mb | `kegalign distributed` | 38 s | 35.5 s |

- **~10–12× whole-pipeline wall time, ~21–57× less alignment compute**, and the margin widens with size: doubling the genomes multiplied LASTZ compute by 4.2× (173 → 725 s) but the GPU stage by only 2.0× (5.2 → 10.4 s).
- The honest qualifier: the durable advantage is *total compute* (cores × seconds), not wall time in the abstract. The CPU route's wall time is bounded by its partition count — here one 6m30s LASTZ task dominated the 10 Mb run — so a cluster with enough slots can close much of the wall-time gap while still burning ~50× the CPU. Finer chunking does not help on one machine: 1 Mb chunks made wall time *worse* (453 s vs 247 s) because 63 containerised tasks cost ~3.4 s each in startup and staging, while producing byte-identical PSL.
- Conservative for the GPU side: an entry-level 4 GB card through a translation layer, where KegAlign targets datacentre GPUs. The ZLUDA HIP shim's tracing is not a factor (3,142 trace lines in the 10 Mb run). `KEGALIGN` peaked at 418 MB RSS and 120% CPU.
- Synthetic random sequence has no repeats, which is the workload feature that hurts LASTZ most, so real genomes likely widen the gap rather than narrow it.

### PSL splitting fixes

- `PSLTOOLS_SPLIT` no longer pipes PSL file *contents* into `psl.list` (the previous `xargs -0 cat` fed `psLayout version 3` as a filename, failing every split); it now writes the filenames found by `find`.
- Split inputs are staged in a subdirectory (`stageAs: 'input/*'`) so Nextflow's stage-out glob does not expand to ~100k input symlinks — the previous behaviour hit `E2BIG` ("Argument list too long") at whole-genome scale on scratch executors.

### Container image

- `assets/image/Dockerfile` is rebuildable again: the SHA256SUMS file it greps for is now committed (with real hashes), the stale `modules/chaincleaner/`, `modules/repeat_filler/` and `modules/make_lastz_chains/bin/` COPY paths are fixed (the kent build no longer produces `chainCleaner`), and `repeat_filler` is pulled from its own image via a multi-stage `COPY --from`.

### Tests

- `tests/` and `test_data/` moved under `assets/tests/` (`assets/tests/ci/`, `assets/tests/test_data/`); CI and script paths updated. `assets/tests/ci/compare_aligners.sh` runs the CPU and both GPU executors on the bundled fixture and asserts batched/distributed equivalence.

### hspZ backend — GPU seeding with CUDA or AMD (ZLUDA)

- `--aligner hspz` routes the alignment stage through `HSPZ_ALIGNMENT` (`subworkflows/local/hspz_alignment/`): `HSPZ` runs upstream hspZ 0.0.1 on the GPU (`ghcr.io/hillerlab/hspz:0.0.1`), which returns only high-scoring ungapped alignment blocks; `LASTZ_SEGMENTED` then does the CPU gapped extension per block (`--segments=`, skipping indexing, seeding and gap-free extension), and `AXT_TO_PSL` converts the AXT to PSL. Downstream chain building is unchanged and consumes the identical `psl_gz` contract.
- Requires the `gpu` (CUDA) or `zluda` (AMD) profile — `--aligner hspz` without either fails at startup. The workflow now dispatches the alignment stage via a `switch` on `--aligner`.
- `lastz_k` → hspZ `--hspthresh` (same K as KegAlign; do not pass `-H`, that short flag is `--hspthresh` not BLASTZ inner). `LASTZ_SEGMENTED` forwards `lastz_l`/`lastz_h`/`lastz_y` as `--gappedthresh`/`--inner`/`--ydrop` plus `--strand` from the partition. An integrity guard fails the run if any `.segments` block produces no AXT.
- `-profile docker,zluda` runs HSPZ natively against a local ZLUDA build (`hspz:zluda`): the image's ENTRYPOINT is cleared and the host shim is mounted at `/opt/zluda` on `LD_LIBRARY_PATH`.
- `environment.yml` removed — conda environments are now declared per module (`LASTZ_SEGMENTED` ships its own).
- `PSLTOOLS_SPLIT` now publishes the merged per-chromosome PSL to `03_psl/`; hspZ output lands in `02_hspz/{segments,axt,psl}`.
- New `test_hspz` profile runs the bundled fixture with `--aligner hspz` and `use_container = false`.
- **Fix:** HSPZ previously passed no scoring flags, so hspZ used its CLI default of 3000 while KegAlign ran at `lastz_k` (2400). On hg38 chr21 × mm39 chr16 that dropped 19k HSPs (the 2400–2999 band) and produced thinner chains.
- **Fix:** `LASTZ_SEGMENTED` now matches KegAlign's LASTZ command (`--gappedthresh=${lastz_l}` was incorrectly `lastz_h`; `--strand=plus|minus` from the partition; `--allocate:traceback=1.99G`).
- `assets/tests/ci/compare.sh` asserts that wiring. `compare_aligners.sh` also runs `--aligner hspz` and checks chain aligned bases against KegAlign within `TOLERANCE`.

### Config adjustments

- Raised the `process_fast`/`process_low`/`process_medium` time ceilings (0.5–2 h → 4 h) and gave `process_gpu` an explicit `16 h` time and `32 GB` memory allocation, so the global `errorStrategy` retries a slow or memory-starved GPU task on the same or a bigger allocation instead of failing a run that merely outgrew the old ceilings.

### Final chain statistics

- Added `CHAINTOOLS_STATS` (`modules/local/chaintools/stats/main.nf`, ported from `core/modules/nextflow/chaintools/stats`) — runs `chaintools stats` on the final published chain (`*.allfilled.chain.gz`) and publishes `${reference}.${query}.stats.txt` (`*.stats.txt`) to `${outdir}/07_final/stats/`. Wired into every entry point in `main.nf` (`FULL_RUN`, `FROM_CHAIN_ANTIREPEAT`, `FROM_SEGMENTS`, `FROM_FILL_CHAINS`, `FROM_CLEAN_CHAINS`) so stats are produced regardless of checkpoint (`-entry`). Reuses the existing `process_low` label; `nextflow.config` adds `withName: '.*:CHAINTOOLS_STATS'` publishDir to `07_final/stats`.

### Config / plumbing fixes

- Fixed missing `params.use_container` default in `nextflow.config` (`use_container = true`) — previously caused `Unknown config attribute 'params.use_container'` on Nextflow 25.10+ and blocked all runs.
- Raised `REPEAT_FILLER` wall time from `1.h` to `6.h` (× `task.attempt`) to accommodate long fill jobs without hitting the ceiling and triggering premature retries.

### Big-genome (.2bit v1) support for the GPU backends

Genomes whose `.2bit` would exceed the v0 32-bit layout (FASTA > ~4 GB) previously broke both GPU backends: hspZ's bundled rust `twobit` crate parses v0 only, `KEGALIGN`'s internal `faToTwoBit` (no `-long`) fails outright on such input, and lastz cannot read v1 at all. Three coordinated changes, all gated so the v0 path is byte-identical:

- **hspZ path** (`subworkflows/local/hspz_alignment/main.nf`): `HSPZ` now always receives whole-genome FASTA via the reused `TWO_BIT_TO_FA` module — unconditional, so there is no launcher-side version probe (unsafe on object-store work dirs) and a single code path. `extract_chroms` is now enabled for `hspz` (`workflows/make_lastz_chains.nf:45`), and `LASTZ_SEGMENTED` (`modules/local/lastz_segmented/main.nf`) resolves each `(ref, query)` pair to the pre-extracted `<chrom>.fa` when present, falling back to the native `.2bit/<chrom>` selection for v0. `SEGMENTS_TO_PSL` threads the new `chroms_dir` inputs through to both callers (`HSPZ_ALIGNMENT`, `FROM_SEGMENTS`), so resumed runs keep the fallback.
- **KegAlign path** (`modules/local/kegalign/main.nf`, new `bin/rewrite_keg_commands.py`): on the big-genome path (`params.force_long_2bit`, or either FASTA > 4 GB) `KEGALIGN` skips the `.2bit` hop entirely — the kegalign binary reads the positional FASTAs (kseq, `main.cpp`) and never opens `work/*.2bit` — and the keg's CPU commands are rewritten from `work/ref.2bit[…][subset=ref_blockN.name]` to per-block FASTAs (`work/ref_blockN.fa[multiple]`, query side without `[multiple]` to match the keg's asymmetric grammar), built in one streaming pass per genome over the FASTA runner.py received. Both CPU executors (`run_lastz_tarball.py`, `run_keg_lastz.py`) execute commands verbatim, so the rewrite is transparent to them. `KEGALIGN_MPS` is untouched by construction: chromosome-granular bins are always v0-safe (`split_input.py` stays byte-verbatim per its header).
- **KegAlign query ceiling**: the binary's query DRAM buffer holds ~6 GB, so `KEGALIGN` fails fast with the reason (`modules/local/kegalign/main.nf:57`) instead of dying deep inside the GPU stage, naming `--aligner lastz`/`hspz` as v1-capable. MPS queries bins rather than the genome, so the guard lives in `KEGALIGN` only; a single > ~6 GB chromosome still dies there with the binary's own DRAM message.

- `params.force_long_2bit` now means "force the big-genome path" for every backend (schema text updated): v1 `.2bit` plus per-chrom FASTAs for lastz/hspz, per-block FASTA CPU commands for kegalign. `README.md` gains a big-genome support matrix per backend (reference ≤ ~16 Gbp with query < 6 GB vs above).
- **Verification so far (stub-run + unit asserts, no GPU on this host):** `bin/rewrite_keg_commands.py --self-check` asserts exact rewritten command text, the target/query `[multiple]` asymmetry, and loud errors on unpaired commands or dangling subsets. Stub-run wiring with KegAlign shims (`test_bgpu,gpu` + `--force_long_2bit`): `HSPZ_ALIGNMENT:REFERENCE/QUERY_TO_FA` → `HSPZ` stages both `.fa`; `LASTZ_SEGMENTED` stages the `*_chroms` dirs (`EXTRACT_CHROMS`: "v1 .2bit detected"); `KEGALIGN` completes the guard → skip → rewrite → package flow with the keg shipping block FASTAs and rewritten commands, while the v0 run keeps verbatim commands and v0 `.2bit`s. The 6 GB guard was unit-tested against a sparse 7 GB file (fires) and a small FASTA (silent). Real-GPU acceptance (lastz/hspz/kegalign parity v0↔v1 via `compare_chains.py`, plus a real v1 `.2bit` input run) remains the gate before this is declared production-ready.
- **Known upstream gaps surfaced, not fixed here:** `chromsize` (`CHROMSIZE`) and `chaintools antirepeat` (`CHAIN_BUILD`) both depend on the v0-only rust `twobit` crate, so real v1 `.2bit` *inputs* and v1 twobits in chain building are expected to fail until those tools gain v1 support (both are `alejandrogzi`-authored; their unpinned `:latest` containers would propagate a fix without pipeline changes). If `package_output.py` turns out to require `work/*.2bit` to exist, the documented one-line fallback in `modules/local/kegalign/main.nf` is to re-add per-file `faToTwoBit -long` on the rewrite path.

# 3.1.7

Released three improvements: replaced the C `chainCleaner` with `chainc`, a Rust reimplementation that runs ~3x faster; removed two redundant dataflow passes (a full PSL merge and a full chain sort) without changing any output; and added a CI golden-comparison harness plus the bundled `test` profile to GitHub Actions.

### chainc

- Added `CHAINC` (`modules/local/chainc/main.nf`), a Rust implementation of UCSC `chainCleaner`, and removed the `chain_cleaner` module. `chainc` nets the input chains in memory, so the `--net` file is no longer required; the pipeline still passes the reference/query chromosome sizes and the `--linear-gap` model.
- `clean_chain_parameters` now takes `chainc`'s kebab-case flags (e.g. `--lr-fold-threshold 2.5 --do-pairs --lr-fold-threshold-pairs 10 --max-pair-distance 10000 --max-suspect-score 100000 --min-broken-chain-score 75000`).
- Output is byte-identical to `chainCleaner` for a given set of parameters (verified by the new golden harness).

### Dataflow simplifications

- `LASTZ_ALIGNMENT` (`subworkflows/local/lastz_alignment/main.nf`): removed the per-reference-partition `PSLTOOLS_MERGE` step. Raw `LASTZ` PSL output now goes straight to `PSLTOOLS_SPLIT --by reference`, which already consolidates alignments across query partitions; `axtChain` sorts its block list internally. This drops one full pass over all alignment data.
- `FILL_CLEAN_CHAINS` (`subworkflows/local/fill_clean_chains/main.nf`): removed `CHAINTOOLS_SORT_MERGED_FILLED_CHAINS`. `CHAINTOOLS_MERGE_FILLED_CHAINS` now merges with `--sort-by score` (controllable via `task.ext.sort_by`), directly producing the score-descending order `chainc` requires. This drops a full sort of the filled chain file.
- Deleted `modules/local/psltools/merge/main.nf` (no remaining callers).

### CI

- Added a GitHub Actions workflow (`.github/workflows/ci.yml`) with two jobs:
  - `test-profile` — runs the bundled smoke test `nextflow run main.nf -profile test,docker` and asserts the final chain exists.
  - `golden-comparison` — runs the pipeline on a full-pipeline synthetic fixture and a hand-crafted chain-breaking-alignment (CBA) fixture (`tests/fixture/cba/`), then diffs the outputs byte-for-byte against committed chainCleaner baselines under `tests/golden/`. Regenerate goldens with `tests/ci/make_golden.sh`. See `tests/README.md`.
- The CI pins Nextflow 25.04.6.

### Container image

- `assets/image/Dockerfile` mirrors the `hillerlab/containers` build and now adds `chainc` (cargo-installed), alongside the updated `chaintools`/`psltools` versions. `chainc --version` is smoke-tested at image build time.

# 3.1.6

Fixed two issues that could silently corrupt or crash the pipeline: chain IDs were being improperly renamed during merge, leading to crashes during chain cleaning, and the PSL output channel from `LASTZ_ALIGNMENT` was emitting individual files instead of a single collect, causing multiple collision scenarios in the downstream chain-building subworkflow.

### Chain merge fix

- Added `--rename` to the `chaintools merge` invocation in `CHAINTOOLS_MERGE` (`modules/local/chaintools/merge/main.nf:46`). Without this flag, chain IDs generated by `axtChain` could be inadvertently reassigned during merge, producing chain files with duplicate or out-of-order identifiers that later caused `chainCleaner` to crash with malformed input.

### PSL collection fix

- Rewired the output channel of `LASTZ_ALIGNMENT` (`subworkflows/local/lastz_alignment/main.nf:134–148`). Previously, the subworkflow emitted individual PSL files from `PSLTOOLS_MERGE` directly via `emit: psl_gz`. This meant `CHAIN_BUILD` received each PSL file one at a time rather than as a single batch, triggering multiple concurrent `PSLTOOLS_SPLIT` invocations that raced against each other. The fix collects all merged PSL files into one list, wraps them in a meta tuple with the combined reference/query name, and emits a single channel item downstream.

### Input alignment

- Renamed the `CHAIN_BUILD` input parameter from `psl_gz_files` to `psl_files` to reflect that `PSLTOOLS_MERGE` outputs uncompressed `.psl` files (not `.psl.gz`). Also aligned indentation across the subworkflow's `take` block for consistency.

### Documentation

- Fixed a stale example command in `README.md` that referenced `run_nf_slurm_example.sh` — now correctly points to `make_lastz_chains.sh`.

### Config adjustments

- Bumped manifest version from `3.1.5` to `3.1.6`.

# 3.1.5

Replaced the UCSC `pslSortAcc` and the shell-based `CAT_PSL` module with `psltools`, a dedicated Rust library for working with PSL files, and introduced weighted repeat-filler distribution via `chaintools split --randomize`.

### New `psltools` modules

- Added `PSLTOOLS_SPLIT` (`modules/local/psltools/split/main.nf`) — splits PSL files by reference chromosome, replacing the UCSC `pslSortAcc` tool. The module receives the raw PSL output from LASTZ, groups alignments by reference chromosome, and emits split PSL files, each containing all query-to-reference alignments for one chromosome.
- Added `PSLTOOLS_MERGE` (`modules/local/psltools/merge/main.nf`) — merges multiple PSL files belonging to the same reference bucket into a single PSL output, replacing the old `CAT_PSL` process that relied on `cat` + `grep` + `gzip`.
- Integrated `PSLTOOLS_SPLIT` into the `CHAIN_BUILD` subworkflow in place of `PSL_SORT_ACC`. The split module now feeds individual PSL files (rather than a sorted directory) into `PSL_BUNDLE`, requiring a `map`/`collect` channel transformation before the bundle step.
- Integrated `PSLTOOLS_MERGE` into the `LASTZ_ALIGNMENT` subworkflow in place of `CAT_PSL`. The merge expects a meta tuple `[id:bucket]` instead of a plain bucket string, aligning with the standard nf-core input pattern.
- Removed `modules/local/cat_psl/main.nf` and `modules/local/psl_sort_acc/main.nf`. The UCSC `pslSortAcc` container is no longer required.

### Weighted repeat-filler distribution

- Added the `--randomize` flag to the `chaintools split` invocation in `modules/local/chaintools/split/main.nf`. This flag randomly shuffles the input chains before partitioning them into chunks, ensuring that the workload across `REPEAT_FILLER` array jobs is evenly distributed regardless of the input order. Previously, chunks could be biased toward larger or smaller chains, causing some array tasks to finish significantly faster than others.

### Pipeline configuration

- Bumped manifest version from `3.1.4` to `3.1.5`.
- Relocated the `array = 500` setting from the base `LASTZ`, `AXT_CHAIN`, and `REPEAT_FILLER` process blocks into a `withName` block scoped to the `slurm` profile. This prevents array-job semantics from being enabled in non-SLURM environments (Docker, Apptainer, local) where array syntax is not applicable.
- Reduced `CHAINTOOLS_ANTIREPEAT` CPU allocation from 32 to 16. The anti-repeat step benefits less from aggressive parallelisation on typical datasets, and the reduced allocation better fits common SLURM partition limits.
- Broadened the `errorStrategy` condition to treat exit status `null` and `Integer.MAX_VALUE` (signalling a missing or unreachable exit code) as retryable alongside the existing signal range (`130–145`, `104`, `175`). This catches previously unhandled edge cases where the process wrapper failed before the child process could produce a proper exit code.
- Removed `--qos=public` from the SLURM profile's `clusterOptions`. This QoS flag is not available on all SLURM installations, and its removal makes the SLURM profile portable across clusters.
- Set `use_container = false` in the `test` profile to ensure the test suite runs without relying on an external container registry.
- Updated the `CAT_PSL` (now `PSLTOOLS_MERGE`) publishDir pattern from `*.psl.gz` to `*.psl`, matching the uncompressed output format of `psltools merge`.
- Disabled `publishDir` for the `PSL_SORT_ACC` (now `PSLTOOLS_SPLIT`) process, as its intermediate outputs do not need to be published.

### PSL bundle module updates

- Changed `PSL_BUNDLE` input from a single `path sorted_psl_dir` (a directory) to `path psl_files, stageAs: "sorted_psl/*"` (a list of files staged into a predictable directory). The module now accepts individual PSL files from `PSLTOOLS_SPLIT` rather than a pre-sorted directory structure.
- Renamed the internal chrom-sizes input parameter from `target_chrom_sizes` to `reference_chrom_sizes` for consistency with the rest of the pipeline.

### Removed test file

- Deleted `bin/tests/test_run_lastz_wrappers.py` (268 lines of unit tests for the old LASTZ wrapper scripts). These tests covered `run_lastz.py` and `run_lastz_intermediate_layer.py` internals (BULK expansion, sequence argument formatting, temp workspace cleanup) that have been stable since v3.1.3 and are maintained upstream in the `pylastz` repository.

### Documentation

- Updated `README.md` to mention `psltools` as the PSL counterpart to `chaintools` in the UCSC replacement note.
- Renamed `assets/scripts/run_nf_slurm_example.sh` to `assets/scripts/make_lastz_chains.sh` to match the pipeline's naming convention.
- Expanded the SLURM helper script's embedded `params.json` snippet with explicit fields for `use_container`, `from`, `axtchain_path`, `merged_chain_path`, and `filled_chain_path` — giving users a complete parameter template that matches the current schema.
- Removed the outdated `lastz_path` and `axt_to_psl_path` entries from the SLURM helper's `params.json` — these parameters were removed in v3.1.0 and are no longer recognised.
- Wrapped the smoke-test command in a `[!TIP]` callout to distinguish it from the main execution examples.
- Added `test.json` and `big_test.json` to `.gitignore` to prevent accidental commits of ad-hoc test configuration files.

# 3.1.4

New `--from chain_antirepeat` checkpoint that lets users resume from the axtChain bundle outputs, skipping LASTZ alignment, alongside a bug fix for `.2bit` path resolution in the wrapper layer and a CPU allocation for the anti-repeat process.

### New `--from chain_antirepeat` checkpoint

- Added `FROM_CHAIN_ANTIREPEAT` subworkflow in `main.nf` — a new resume entry point that accepts a directory of `.chain` files from `04_axtchain`. The workflow prepares the reference and query genomes (without chromosome extraction), collects all bundled chains from the provided `--axtchain_path` directory, runs `chaintools antirepeat` on each, merges the result via `CHAINTOOLS_MERGE`, and proceeds through gap filling and chain cleaning. This effectively allows users to skip LASTZ alignment entirely and resume from the point where axtChain output is available.
- Added `validateFromChainAntirepeat()` validation function that requires `--axtchain_path` in addition to the usual alias-base parameters (`--reference_name`, `--query_name`, `--reference_genome`, `--query_genome`).
- Added `--axtchain_path` parameter to `params.json` (defaults to `null`). The parameter accepts a path to a directory containing `.chain` files — typically `results/04_axtchain` from a prior run.
- Updated the README checkpoint documentation to list `chain_antirepeat` as a valid `--from` value alongside `fill_chains` and `clean_chains`, and annotated the `04_axtchain/` output tree to mark it as the anchor directory for this checkpoint.
- The new subworkflow respects `--skip_antirepeat`, `--skip_fill_chains`, and `--skip_clean_chain` flags, giving users fine-grained control over which post-alignment steps execute.

### Bug fix: `.2bit` path resolution in LASTZ wrapper

- Fixed a bug in `bin/run_lastz.py` where the LASTZ wrapper did not properly handle missing or unreadable `.2bit` files when processing ranged chromosome arguments. The fix introduces explicit `os.path.exists()` and `os.access` checks before v1 header detection, surfacing a clear `FileNotFoundError` with a descriptive message that includes the expected shared FASTA path (when `--reference_chrom_dir` or `--query_chrom_dir` is configured) or a note about the missing directory.
- Extracted the shared FASTA lookup into a dedicated `get_shared_chrom_fasta()` helper and added `missing_twobit_message()` to produce consistent, actionable error diagnostics. Both the v0 and v1 `.2bit` paths now produce the same quality of error messaging when the input file is absent.
- Bumped `bin/run_lastz.py` `__version__` from `0.0.2` to `0.0.3`.

### CPU allocation for anti-repeat process

- Added `cpus = 32` to the `CHAINTOOLS_ANTIREPEAT` process block in `nextflow.config`. The anti-repeat step iterates over all aligned chain bundles and benefits from the additional parallelism, reducing wall-clock time during the chain-building stage.

### Documentation

- Added the Hiller Lab logo (`assets/figures/hillerlab.png`) to the top of `README.md`.
- Fixed the GitHub License badge URL, which was incorrectly pointing to the `containers` repository instead of `make_lastz_chains`.
- Added a reference to the [softmask](https://github.com/hillerlab/softmask) solution in the important-notes section for users that need to soft-mask their genomes.

### Config adjustments

- Bumped manifest version from `3.1.3` to `3.1.4`.

# 3.1.3

Refactored the LASTZ alignment wrappers and completed the `target` → `reference` terminology migration across the alignment pipeline, alongside a Python container upgrade and internal code quality improvements.

### LASTZ wrapper rewrite

- Rewrote `bin/run_lastz.py` and `bin/run_lastz_intermediate_layer.py` with structured logging via Python's `logging` module, comprehensive type annotations, and explicit input validation. The older `verbose_msg` lambda pattern has been replaced with proper `LOGGER.debug()` calls throughout.
- Migrated both scripts from positional CLI arguments to explicit `--flag value` options (`--reference`, `--query`, `--params_json`, `--output`, etc.), making the command-line interface self-documenting and consistent with the rest of the pipeline's entry points.
- Added proper resource management — temporary workspace cleanup now uses `try/finally` blocks, ensuring temporary directories are removed even when a subprocess fails.
- Introduced validated parameter access via `require_string_param` in both scripts, surfacing clear error messages when mandatory pipeline configuration keys are missing or malformed.
- Added BULK partition validation in `run_lastz_intermediate_layer.py` to catch malformed partition entries early, and replaced `subprocess.call` with `subprocess.run` + `check=True` for immediate error propagation on child failures.

### Terminology completion (`target` → `reference`)

- Renamed the `--target` CLI argument to `--reference` and `--target_chrom_dir` to `--reference_chrom_dir` in both `bin/run_lastz.py` and `bin/run_lastz_intermediate_layer.py`, including all associated variables, function parameters, and documentation strings.
- Updated `modules/local/lastz/main.nf` to use `reference_part`, `reference_twobit`, `reference_chrom_sizes`, and `reference_chroms_dir` throughout, and aligned the underlying `run_lastz*` script invocations with the new `--reference` and `--reference_chrom_dir` flags.
- Harmonised process tags and output channel naming with the new terminology, completing the glossary update that began in v3.1.0.

### Python container upgrade

- Updated the `PARTITION` and `PSL_BUNDLE` process containers from `biocontainers/python:3.8.0--2` to `biocontainers/python:3.11`. Both modules now run on Python 3.11, matching the runtime version used elsewhere in the pipeline.

### Type hints and documentation

- Added full type annotations and docstrings to `bin/partition.py` and `bin/psl_bundle.py` — function signatures now declare argument and return types, constants carry explicit type declarations, and every public function includes a descriptive docstring.
- Added script-level metadata (`__author__`, `__credits__`, `__email__`, `__github__`, `__version__`) to `bin/run_lastz.py` and `bin/run_lastz_intermediate_layer.py`.

### Config adjustments

- Bumped manifest version from `3.1.2` to `3.1.3`.

# 3.1.2

Introduced a new `chaintools sort` step to sort filled chains before the chain cleaning stage, fixing a `chainNet` error that occurred when unsorted chains reached the cleaning subworkflow.

### New `chaintools sort` module

- Added `modules/local/chaintools/sort/main.nf` — a new process that wraps `chaintools sort` to sort filled chains by score/target/query. The sorted output is now what feeds into the chain cleaning step, preventing the `chainNet` error that previously surfaced when unsorted output from the gap-filling merge reached the cleaner.
- Integrated `CHAINTOOLS_SORT_MERGED_FILLED_CHAINS` into the `FILL_CLEAN_CHAINS` subworkflow, placed between `CHAINTOOLS_MERGE_FILLED_CHAINS` and the chain cleaning step.

### Config adjustments

- Reassigned the `CHAINTOOLS_MERGE` process label to `process_medium` and disabled its `publishDir` (merged intermediates no longer need to be published) — publication is now handled by `CHAINTOOLS_SORT_MERGED_FILLED_CHAINS`, which also uses `process_medium`.
- Updated the publish directory pattern for sorted merged chains from `*.all.chain.gz` to `*.chain*` to capture the new sorted chain outputs.
- Bumped manifest version from `3.1.1` to `3.1.2`.

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
