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
- **LASTZ 1.04.60.** Bumped LASTZ from 1.04.52 to 1.04.60 in the pipeline image (source build + SHA256SUMS) and in the `LASTZ`/`LASTZ_SEGMENTED` module containers (`lastz:1.04.60--hab16a5f_0`). The `pylastz` and `repeat_filler` images are rebuilt at their existing `:latest` tags, so `KEG_LASTZ` and `KEGALIGN_LASTZ` now run the same LASTZ build.
- **Pipeline image 4.0.0** (`ghcr.io/hillerlab/make_lastz_chains`, hillerlab/containers PR #72). `assets/image/Dockerfile` matches the containers repo's file except for its source paths.
  - **chaintools 0.0.13,** so `CHAINTOOLS_STATS` and `CHAINTOOLS_COVERAGE` run in the pipeline image again. SECTION 5 no longer sends them to `ghcr.io/alejandrogzi/chaintools:latest` (see "Config / plumbing fixes" below). The image build now fails if `chaintools stats` or `chaintools coverage` is missing.
  - **117 MB → 52 MB.** Dropped Perl (~40 MB; it was there only for chainCleaner's `NetFilterNonNested.perl`, unused since `chainc`) and `chainNet`/`chainScore` (unused, so the second Kent source build, v455, goes too). Python is a trimmed copy of `python:3.11-alpine3.22` on plain `alpine:3.22`: no pip, setuptools, wheel, ensurepip, IDLE, Tk, lib2to3 or pydoc data.
  - The final tool check failed only if the last command in its `for` loop was missing. That is how `chainCleaner` could stay listed after it was gone. Every listed tool is now checked.
  - With this image the e2e and CBA goldens match, and the `test_hspz` final chain is byte-identical to the 3.1.7 image's with either fill engine. Only the pipeline image must be rebuilt: KegAlign and hspZ keep their own images.
  - **Order of release.** With the 3.1.7 image (chaintools 0.0.9), `CHAINTOOLS_STATS` fails with `unrecognized subcommand 'stats'`. Publish the 4.0.0 image before this config reaches users or CI, and pull it where a 3.1.7 `:latest` is cached.

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
- **KegAlign 0.3.4 is now what runs.** `nextflow.config` SECTION 5 still forced `kegalign-full:0.1.2.9` whenever `use_container` was on, which hid two upstream breaks behind the module-level bump. First, `package_output.py` renamed `--format_selector` to `--output_format`; `modules/local/kegalign/main.nf` and `bin/run_kegalign_mps_pair.py` now pass the new flag. Second, `run_lastz_tarball.py` now gzips AXT output whatever `--output` is named, so `KEGALIGN_LASTZ` decompresses it with `zcat -f` before `AXT_TO_PSL`. 0.3.4 also fixes upstream's `statistics.quantiles` crash on sparse pairs with a single segments file. kegalign-full 0.3.4 ships lastz 1.04.60 while the then-current `KEG_LASTZ` pipeline image ran 1.04.52 (both are 1.04.60 after the bump above). On a CPU-built keg from the bundled fixture, both executors gave identical PSL (65 records); `compare_aligners.sh` remains the GPU check.
- `SEGMENTS_TO_PSL` takes the PSL `meta.id` from the items instead of interpolating the name channels `HSPZ_ALIGNMENT` passed in, which tagged hspz runs `DataflowVariable(value=hg38).DataflowVariable(value=mm39).all.psl`. The now-unused name inputs are removed.
- `nextflow_schema.json` is valid JSON again (77 trailing commas removed) and lists `hspz` among the `--aligner` values.
- `CHAINTOOLS_STATS` and `CHAINTOOLS_COVERAGE` now run in `ghcr.io/alejandrogzi/chaintools:latest` even when `use_container` is on. The pipeline image (built 2026-08-07) ships chaintools 0.0.9, but `stats` arrived in 0.0.11 and `coverage` in 0.0.13. Every default run therefore published `07_final/` and then failed at `CHAINTOOLS_STATS` with `unrecognized subcommand 'stats'`. `assets/image/Dockerfile` now pins chaintools 0.0.13 for the next image rebuild. The 4.0.0 image has it, and the override is gone again (see "Container image").
- `CHAINTOOLS_SPLIT` passes `--seed 42` with `--randomize`, so a given merged chain always splits into the same `REPEAT_FILLER` chunks. Before, chaintools drew a time-based seed and the chunks changed on every run. Final chains never depended on the shuffle: `chaintools merge --sort-by score --rename` gave byte-identical output across seeds on a 6,683-chain hg38 chr21 × mm39 chr16 file, and the e2e goldens match with 8 chunks as with 1. chaintools 0.0.9 (pipeline image) and 0.0.13 cut identical chunks for the same seed. Its stub now creates `chains/` before touching files there, so `-stub-run --from fill_chains` runs to the end instead of failing on `touch`. `--files` stays at `num_fill_jobs` (1000).
- A full `-stub-run` now reaches the final chain. `CHROMSIZE`'s stub wrote an empty `chrom.sizes`, so `PARTITION`, which has no stub, wrote empty partition lists; `LASTZ` got no jobs and the run reported success right after `PARTITION`. `CHROMSIZE` no longer has a stub, so the real sizes are used. `LASTZ` gains a stub that writes an empty PSL under its real name, so stub runs never align, and `PSL_BUNDLE` gains one that writes a single empty bundle, because stubbed PSL names match no chromosome. Verified with `-profile test` (lastz) and `test_hspz`. Stub blocks are not part of a real task's cache hash, so `-resume` is unaffected.

### Big-genome (.2bit v1) support for the GPU backends

Genomes whose `.2bit` would exceed the v0 32-bit layout (FASTA > ~4 GB) previously broke both GPU backends: hspZ's bundled rust `twobit` crate parses v0 only, `KEGALIGN`'s internal `faToTwoBit` (no `-long`) fails outright on such input, and lastz cannot read v1 at all. Three coordinated changes, all gated so the v0 path is byte-identical:

- **hspZ path** (`subworkflows/local/hspz_alignment/main.nf`): `HSPZ` now always receives whole-genome FASTA via the reused `TWO_BIT_TO_FA` module — unconditional, so there is no launcher-side version probe (unsafe on object-store work dirs) and a single code path. `extract_chroms` is now enabled for `hspz` (`workflows/make_lastz_chains.nf:45`), and `LASTZ_SEGMENTED` (`modules/local/lastz_segmented/main.nf`) resolves each `(ref, query)` pair to the pre-extracted `<chrom>.fa` when present, falling back to the native `.2bit/<chrom>` selection for v0. `SEGMENTS_TO_PSL` threads the new `chroms_dir` inputs through to both callers (`HSPZ_ALIGNMENT`, `FROM_SEGMENTS`), so resumed runs keep the fallback.
- **KegAlign path** (`modules/local/kegalign/main.nf`, new `bin/rewrite_keg_commands.py`): on the big-genome path (`params.force_long_2bit`, or either FASTA > 4 GB) `KEGALIGN` skips the `.2bit` hop entirely — the kegalign binary reads the positional FASTAs (kseq, `main.cpp`) and never opens `work/*.2bit` — and the keg's CPU commands are rewritten from `work/ref.2bit[…][subset=ref_blockN.name]` to per-block FASTAs (`work/ref_blockN.fa[multiple]`, query side without `[multiple]` to match the keg's asymmetric grammar), built in one streaming pass per genome over the FASTA runner.py received. Both CPU executors (`run_lastz_tarball.py`, `run_keg_lastz.py`) execute commands verbatim, so the rewrite is transparent to them. `KEGALIGN_MPS` is untouched by construction: chromosome-granular bins are always v0-safe (`split_input.py` stays byte-verbatim per its header).
- **KegAlign query ceiling**: the binary's query DRAM buffer holds ~6 GB, so `KEGALIGN` fails fast with the reason (`modules/local/kegalign/main.nf:57`) instead of dying deep inside the GPU stage, naming `--aligner lastz`/`hspz` as v1-capable. MPS queries bins rather than the genome, so the guard lives in `KEGALIGN` only; a single > ~6 GB chromosome still dies there with the binary's own DRAM message.

- `params.force_long_2bit` now means "force the big-genome path" for every backend (schema text updated): v1 `.2bit` plus per-chrom FASTAs for lastz/hspz, per-block FASTA CPU commands for kegalign. `README.md` gains a big-genome support matrix per backend (reference ≤ ~16 Gbp with query < 6 GB vs above).
- **Verification so far (stub-run + unit asserts, no GPU on this host):** `bin/rewrite_keg_commands.py --self-check` asserts exact rewritten command text, the target/query `[multiple]` asymmetry, and loud errors on unpaired commands or dangling subsets. Stub-run wiring with KegAlign shims (`test_bgpu,gpu` + `--force_long_2bit`): `HSPZ_ALIGNMENT:REFERENCE/QUERY_TO_FA` → `HSPZ` stages both `.fa`; `LASTZ_SEGMENTED` stages the `*_chroms` dirs (`EXTRACT_CHROMS`: "v1 .2bit detected"); `KEGALIGN` completes the guard → skip → rewrite → package flow with the keg shipping block FASTAs and rewritten commands, while the v0 run keeps verbatim commands and v0 `.2bit`s. The 6 GB guard was unit-tested against a sparse 7 GB file (fires) and a small FASTA (silent). Real-GPU acceptance (lastz/hspz/kegalign parity v0↔v1 via `compare_chains.py`, plus a real v1 `.2bit` input run) remains the gate before this is declared production-ready.
- **Known upstream gaps surfaced, not fixed here:** `chromsize` (`CHROMSIZE`) and `chaintools antirepeat` (`CHAIN_BUILD`) both depend on the v0-only rust `twobit` crate, so real v1 `.2bit` *inputs* and v1 twobits in chain building are expected to fail until those tools gain v1 support (both are `alejandrogzi`-authored; their unpinned `:latest` containers would propagate a fix without pipeline changes). If `package_output.py` turns out to require `work/*.2bit` to exist, the documented one-line fallback in `modules/local/kegalign/main.nf` is to re-add per-file `faToTwoBit -long` on the rewrite path.

### Alignment chain QC control (optional)

- New `params.annotation` (`params.json` section 7, default `null`): when set to a BED/GTF/GFF file, every entry workflow runs the ported `CHAINTOOLS_COVERAGE` (`modules/local/chaintools/coverage/main.nf`, from `hillerlab/core`) on the final chain right after `CHAINTOOLS_STATS`, measuring how many bases of the annotation's features are covered by chain blocks. Skipped entirely when null — one `if (params.annotation)` guard per entry point. `params.annotation_side` (`reference`, default) and `params.annotation_feature` (`cds`, default) select the chain side and feature type; both are validated at startup alongside the other params, and all three carry defaults in `nextflow.config` as well so a bare `--annotation file.bed` works without a params-file. Report lands next to the stats report as `${reference}.${query}.allfilled.coverage.txt` (`07_final/stats/`).

### Many queries, one reference: `--array` (hspZ)

- **Usage.** `--array FILE` (`params.array`, default `''`) aligns every query genome listed in FILE against `--reference_genome` in one run.
  - **Format:** one path per line; `#` and blank lines are skipped, and relative paths resolve against the file's directory.
  - **Constraints:** it replaces `--query_genome`/`--query_name`, needs `--aligner hspz`, and supports full runs only.
  - **Names:** each query is named after its file without `.gz` and `.fa`/`.fasta`/`.fna`/`.2bit`. Startup validation (`main.nf` `arrayQueries()`/`validateArray()`) requires names to be unique, safe in file names and different from the reference name.
  - Without `--array`, the original `--reference_genome` + `--query_genome` mode is unchanged.
- **One GPU stage for every query.** In array mode `HSPZ` (`modules/local/hspz/run/main.nf`) runs a single hspZ `--query-list` batch.
  - Each reference bin is built and uploaded once for the whole list, while each query's segments stay byte-identical to its standalone run.
  - Job directories are renamed after their query using hspZ's `queries.tsv`, guarded by a row count against the list.
  - Single-query runs keep the original `hspZ -q` call and the flat `02_hspz/segments/` layout.
  - hspZ is pinned to `0.0.4`/`0.0.4-zluda` (module, SECTIONS 5 and 5b): `--query-list` needs 0.0.4, and a stale local `:latest`/`:zluda` used to run an older release silently.
- **One bubble per query downstream.** From segments to final chain, `meta` carries the query (`[id: '<ref>.<qry>', query: '<qry>']`).
  - `PREPARE_GENOMES` takes one genome or a list.
  - In `SEGMENTS_TO_PSL`, `CHAIN_BUILD` and `FILL_CLEAN_CHAINS`, each item gets its own query's `.2bit` and chrom.sizes via `combine(by: 0)` + `multiMap`.
  - Their `.collect()` fan-ins became `groupTuple()`. This is a barrier across queries, kept deliberately and marked with `ponytail:` notes.
  - `PSL_BUNDLE`, `AXT_CHAIN`, `CHAINTOOLS_ANTIREPEAT`, `REPEAT_FILLER` and `CHAINTOOLS_SCORE` now pass `meta` through; their scripts are unchanged.
- **Layout.** `--array` publishes each query's steps under `<outdir>/<query>/`, from `02_hspz/{axt,psl}` and `03_psl` through `07_final/stats`, via the `qdir` helper in `nextflow.config`.
  - `00_genome_prep/`, `02_hspz/segments/` and `pipeline_info/` stay shared.
  - `onComplete` reports every query's final chain.
  - Annotation coverage runs for every query; `--annotation_side query` is rejected with `--array`.
  - `--from segments` refuses a segments directory that holds several queries.
- **Verification** (AMD RX 6500 XT + ZLUDA, Nextflow 25.04.6):
  - New `assets/tests/ci/compare_array.sh` (GPU only, also wired into the manual GPU CI job) runs one `--array` batch over two queries (the bundled query and the reference itself; one hspZ batch, 2 jobs, 102 and 984 HSPs), then each query on its own. Per query, the segments, cleaned chain, removed BED and final chain are byte-identical.
  - Against the pre-change commit, single-query hspz and `--from segments` outputs are byte-identical (segments, cleaned and final chains, removed BED, stats), with the same flat layout.
  - The e2e and CBA goldens match.
- **Limits.**
  - The hspZ batch is all-or-nothing and keeps every query's records in host RAM.
  - hspZ refuses a list whose queries plan different reference bins.
  - Editing the list reruns the batch and everything downstream.
  - The GPU gain is large for many small queries (hspZ 0.0.4: 100 × 5 Mbp, −82%) and under 1% for whole genomes.

### GPU chain-gap filling: `--repeat_filler_engine hspz`

- **Why.** With hspZ alignment, RepeatFiller became the slowest step. In hg38 chr21 × mm39 chr16, one REPEAT_FILLER task took 729 s; it held the dominant chain, whose 7,997 gaps ran one after another on one CPU.
  - Measured per gap on 400 real gaps: lastz seeding 8.7–12 ms, extension from anchors 2.7–3.0 ms.
  - axtChain + chainSort took 80–91 ms per gap, because axtChain reloads both whole chromosomes from the .2bit for every gap.
- **Engine.** `params.repeat_filler_engine` (`nextflow.config:90`): `lastz` (default, REPEAT_FILLER unchanged) or `hspz`. The hspz engine is the new subworkflow `FILL_CHAINS_HSPZ` (`subworkflows/local/fill_chains_hspz/main.nf`), selected in `FILL_CLEAN_CHAINS` (`subworkflows/local/fill_clean_chains/main.nf:45`). It runs four new steps:
  1. **FILL_GAPS** (`bin/fill_gaps.py extract`) picks exactly RepeatFiller's gaps.
     - Each gap becomes one target and one query record with the same name: gap-local, plus strand (the query is reverse-complemented for '-' chains), and uppercased unless `skip_fill_unmask`.
     - The gaps are cut into `min(num_fill_jobs, gaps)` shards by gap rather than by chain, so a dominant chain no longer holds a whole task.
  2. **HSPZ_FILL** (`modules/local/hspz/fill/main.nf`) runs hspZ `run --paired` (0.0.6) at `fill_lastz_k` over every gap in one GPU task. Record *i* of the targets is compared only with record *i* of the queries.
  3. **LASTZ_FILL** runs per shard. lastz extends from the anchors (`[multiple]` target, `--segments`, `fill_lastz_l`), and `axtChain -faT -faQ` chains from the shard FASTAs instead of the whole .2bit. chainSort is dropped, because axtChain already writes chains sorted by score.
  4. **FILL_SPLICE** (`bin/fill_gaps.py splice`) inserts each gap's best mini chain scoring at least `fill_insert_chain_min_score`, using RepeatFiller's `insert_chain_content` arithmetic. CHAINTOOLS_SCORE and CHAINTOOLS_MERGE_FILLED_CHAINS then run as on the lastz engine, so `05_filled_chains` and everything downstream keep their names. FILL_SPLICE fails on a mini chain that crosses gaps or strands, names no gap, or leaves its record.
- **Configuration.**
  - `validateFillEngine()` (`main.nf:220`) requires `-profile gpu` or `zluda` for hspz. Any `--aligner` works.
  - `HSPZ_FILL` uses `hspz:0.0.6` / `0.0.6-zluda` (SECTION 5 and 5b; the ZLUDA container options are now shared with HSPZ).
  - SECTION 5d holds the new resources.
  - `LASTZ_FILL` runs in REPEAT_FILLER's image (`repeat_filler:latest`: lastz 1.04.60, axtChain 482), so with `use_container = false` both engines extend and chain with the same builds. The pipeline image still ships lastz 1.04.52 until it is rebuilt; with `use_container = true` both engines run that image.
  - `LASTZ_FILL` joins the SLURM array selector.
  - The schema and `params.json` gain the parameter.
- **Verification** (RX 6500 XT + ZLUDA): new `assets/tests/ci/compare_fill.sh`, run on the hg38 chr21 × mm39 chr16 pre-fill chain (6,683 chains, 8,671 fillable gaps) through `--from fill_chains`:
  - **Exact.** A CPU stand-in for hspZ (`hspz_paired_standin.sh`, lastz's own anchors via `--writesegments`, mounted by `fill_standin.config`) through the hspz engine reproduces the lastz engine's `05_filled_chains`. One chain differs, by a tie: that gap has two mini chains of exactly equal score (12,994; one target block aligned to two tandem copies 3,810 bp apart). axtChain lists them in the same order as the hspz engine, and RepeatFiller's extra chainSort (musl `qsort`, not stable) swaps them. `chain_tie_diff.py` accepts only that kind of difference: the same chains and block sizes, with offsets moved inside the gap. Without the dominant chain (674 gaps), the output is byte-identical.
  - **Tolerance.** With the real hspZ 0.0.6 image, the fill adds 531,416 aligned bp against 530,813 for the lastz engine (+0.11%), with the same 6,683 chains. Filled gaps: 944 of 8,671.
  - **Speed.** The fill stage, from FILL_GAPS to the merged filled chain, takes about 10 s of critical path: HSPZ_FILL 3.6 s, 16 LASTZ_FILL shards at ≤ 2 s each. REPEAT_FILLER's dominant chunk takes 692–729 s. The `--from fill_chains` runs took 12 m 7 s (lastz engine) and 1 m 48 s (hspz engine with the CPU stand-in).
  - **NVIDIA L4** (Delta node50, apptainer `--nv`, driver 595.71): the same `compare_fill.sh` gives the same EXACT (TIE 1) and TOLERANCE (+0.11%) results, and each arm's `05_filled_chains` is byte-identical to its ZLUDA run. HSPZ_FILL takes 2.2 s, with a peak RSS of 13.1 GB.
  - **Whole genome, NVIDIA L4** (hg38 × mm39, `--from fill_chains` on the pre-fill chain of the 2026-11-02 human × mouse run; that run's own lastz-engine fill, on node52's CPUs, is the baseline; same fill parameters, `use_container = false`, 64 CPUs):
    - **Same result.** The fill adds 89,376,800 aligned bp against 89,376,162 (+638 bp, +0.0007%). Both runs have the same 4,902,515 filled chains and the same 4,903,077 final chains. In the final stats, 42 more blocks; the largest chain is 94 bp shorter. 150,979 of 1,455,934 gaps are filled.
    - **Cost, with the FILL_GAPS fix below.**
      - Fill stage: 2.20 CPU h against 57.5 (REPEAT_FILLER 53.1 + CHAINTOOLS_SCORE 4.4), about 26× less. Its wall span is 0.27 h against 1.44 h.
      - The `--from fill_chains` run took 18 m 18 s, against 29 m 54 s before the fix.
      - With the hspZ run's alignment and chain building, the pipeline totals 40.3 CPU h instead of 95.6. See the benchmark's `summary.md` (pipeline-hm/2026-11-02, third column).
    - **Steps.**
      - FILL_GAPS: 124 s, 13.6 GB peak RSS.
      - HSPZ_FILL: 182 s (161 s in the first run), 24.9 GB peak RSS, 3.2 GB of GPU memory. It ran 1,455,934 pairs in 7 batches and 12,061 calls, with no oversized re-issue; the largest call had 22,052 hits. The GPU was busy 26–29% of the time. In the first run, host seed generation took 45% and per-call block-sum round trips 28%.
      - LASTZ_FILL: 1,000 shards, 1.0 CPU h.
      - CHAINTOOLS_SCORE: one task, 0.64 CPU h.
  - **End to end, on the baseline's setup** (node52, GPUs 6–7, 128 CPUs, the same config and parameters plus `--repeat_filler_engine hspz`; benchmark `summary.md`, pipeline-hm/2026-11-02):
    - Times: 1 h 20 m against 2 h 35 m; 40.8 task CPU h against 95.6; fill stage 0.20 h and 2.68 CPU h against 1.44 h and 57.5.
    - HSPZ_FILL took 4 min on one A100.
    - The final stats equal the node50 fill runs' in every field. The chain files differ only in the order and ids of equal-score chains, which already vary in alignment and chain building: with ids removed, the pre-fill, filled and final chain sets are identical.
  - **FILL_GAPS in genome order.** In the first whole-genome run, FILL_GAPS took 23.6 min at 35% CPU and 20.4 GB. It had asked twoBitToFa for the 1.46 M gap regions in chain (score) order. twoBitToFa redoes per-sequence work whenever the sequence changes, which happened 373,299 times per side, here reading over BeeGFS.
    - It now requests the regions sorted and puts the sequences back in gap order.
    - It also splits twoBitToFa's output with string methods instead of a Python loop over lines.
    - On Delta: 1,417 s → 124 s, 20.4 → 13.6 GB. The two runs' `05_filled_chains` and `07_final` are byte-identical.
    - Locally, on hg38 × mm39 without chrY: 12 m 21 s → 2 m 51 s, and `gaps.tsv` and all 2,000 shard FASTAs are byte-identical.
    - What remains (local): the Python chain parse (61 s), twoBitToFa itself (51 s) and writing the shards (32 s).
  - **Default path.** The e2e and CBA goldens match. A full `-stub-run` and a two-query `--array` stub-run with `--repeat_filler_engine hspz` reach `07_final`.
- **Limits.**
  - Unmasked low-complexity gap pairs cost O(L²) hits in hspZ (every hit is extended).
  - FILL_GAPS keeps every gap sequence of a query in memory (13.6 GB peak for hg38 × mm39).
  - `--array` runs one HSPZ_FILL per query.
- **Fix (HLmyoMyot9A × HLmyoDau2).** `FILL_SPLICE` stopped the run on two cross-gap mini chains. Both came from `LASTZ_FILL` running a whole shard against one `[multiple]` target:
  - lastz `--segments` seeds a query record with no anchors itself, against every target record. A 33 bp TA-repeat gap hit another gap's TA repeat (score 3003).
  - With several target records, lastz also reports an anchor's match on another record with the same sequence: two gaps whose 38 bp sides are identical (score 3638).
  - `LASTZ_FILL` now passes lastz only the query records that have anchors, and drops blocks whose target and query records differ before `axtChain`.
  - Verified: `compare_fill.sh` on chr21 × chr16 is unchanged (EXACT 'TIE 1'; 531,416 vs 530,813 bp). `test_hspz` with the hspz engine still gives `d612024aa61d`. On the bats' shards 00000 and 00476 no cross-gap blocks remain and all same-gap blocks are identical, and the run completes.

### hspZ GPU count: `--hspz_gpus`

- `params.hspz_gpus` (default **2**) sets how many GPUs hspZ's seeding step uses (`HSPZ`, `--aligner hspz`).
  - `HSPZ` passes it as hspZ `--gpus`, in single-query and `--array` runs alike. Before, the pipeline passed no flag, so hspZ ran on its default of one GPU.
  - It is also `HSPZ`'s `accelerator` request (SECTION 5c), so a SLURM job asks for that many GPUs instead of the `process_gpu` label's one.
  - The output does not depend on it: hspZ orders its output by work unit, whatever the split across GPUs. With fewer devices than requested visible, hspZ time-slices them, which gives no speed-up.
  - `HSPZ_FILL` always uses one GPU (hspZ `--paired` is single-GPU).
  - The `zluda` profile sets 1 (one workstation GPU).
  - Validated as an integer ≥ 1. It is listed in the help, the schema and `params.json`, and shown in the run banner.
  - `--gpus` must no longer appear in `HSPZ`'s `ext.args`, because hspZ rejects the flag twice. For example, the 2026-11-02 benchmark's `custom.config` passed `--gpus 2 -t 48`; it should now pass `-t 48` with `--hspz_gpus 2`.
- **SLURM GPU requests.** Nextflow's SLURM executor ignores `accelerator`, so until now GPU tasks under `-profile slurm,gpu` went to the `gpu` partition but requested no GPU.
  - The slurm profile's `clusterOptions` now adds `--gres=gpu:N` to every GPU task (`ext.use_gpu`): N is `--hspz_gpus` for `HSPZ`, and the accelerator request or 1 for the others (`HSPZ_FILL`, KegAlign).
  - It sits at process level because of an older bug. A profile's `withLabel: process_gpu` block replaces the base label block, so under `-profile gpu` that label's accelerator, time and memory do not apply. Every GPU step sets its own time and memory in a `withName` block, so only the accelerator was lost, and the fallback of 1 covers it.
- **Verification.**
  - SBATCH headers written by Nextflow 25.10.4 (no submission): with `-profile slurm,gpu`, `HSPZ` gets `--gres=gpu:2` (`gpu:4` with `--hspz_gpus 4`), `HSPZ_FILL` gets `gpu:1`, and CPU tasks get none. With `-profile slurm` alone, nothing is added and the label's 16 h / 32 GB stay.
  - On ZLUDA (`test_hspz,docker,zluda`): the default gives `--gpus 1`. `--hspz_gpus 2` gives `--gpus 2` (two workers on one GPU), and its segments and `07_final` chain are byte-identical to the 1-GPU run. `--hspz_gpus 0` fails validation.

### hspZ image: `:latest`

- `HSPZ` and `HSPZ_FILL` now run `ghcr.io/hillerlab/hspz:latest`, or `:zluda` under ZLUDA (the registry has no `:latest-zluda`). This applies in both modules and in SECTIONS 5 and 5b, where the two steps now share one selector.
  - It replaces the `0.0.4` and `0.0.6` pins described above. Today `:latest` and `:zluda` are the 0.0.6 images, with the same image IDs, so outputs do not change.
  - Minimum versions: `--array` needs 0.0.4 (`--query-list`) and `--repeat_filler_engine hspz` needs 0.0.6 (`--paired`).
  - Docker and the Apptainer/Singularity cache keep the first copy they pulled. After an hspZ release, refresh it (`docker pull ghcr.io/hillerlab/hspz:latest` or `:zluda`, or delete the cached `.img`). Otherwise the old release keeps running.

### Window-masking recovery for CPU lastz: `--window_masking_recovery`

HLmyoMyot9A × HLmyoDau2 (two *Myotis* bats) share unmasked 20-bp-unit satellite arrays (UCSC-style TRF masking keeps
only periods ≤ 12). One CPU lastz job there found 53.5 M anchors and stopped with `init_from_anchors(): structure
size would exceed 2^32`. In v4.0.0 that stopped the run. The old Hiller lab pipeline crashed on 19 such jobs too and
recovered them: it added `windowmaskerSdust` to both genomes and re-ran each job split 5×5.

- **`LASTZ`** recognises the overflow from lastz's message.
  - By default it still fails, now with a hint: re-run with `--window_masking_recovery true`, or soft-mask the arrays.
  - With `--window_masking_recovery true` (`ext.mark_overflow`), it writes `<pair>.overflow` instead.
- **`LASTZ_ALIGNMENT`** re-runs every overflowed pair:
  - `WINDOWMASKER` runs once per genome: `windowmasker -mk_counts`, then `-ustat … -dust true`, UCSC's recipe, in
    `quay.io/biocontainers/blast:2.17.0`, which is kept out of the pipeline image. The intervals are published in
    `00_genome_prep/window_masking/`.
  - `MASK_GENOME` writes each genome with those intervals added to its own soft-masking, keeping the original
    `.2bit` format. It uses `bin/soft_mask_fasta.py`; the result is published as `<name>.wmsdust.2bit`.
  - `MASKED_CHROMS` extracts the overflowed pairs' chromosomes from it.
  - `LASTZ_RECOVER` runs the pair as 5×5 sub-pairs on them; `run_lastz.py` prefers a chroms-dir FASTA over the
    `.2bit`. A sub-pair that still overflows fails the run.
  - A BULK bin is expanded first. With the 175 Mb default chunk every chromosome under ~79 Mb is in one, including
    the bats' SUPER_13. Its chromosomes longer than a fifth of the bin are cut into pieces of that length; the shorter
    ones stay together as one bin.
  - The masked genomes then replace the originals for every later step (chaining, anti-repeat, fill, clean), as in
    the old pipeline. `LASTZ_ALIGNMENT` emits them as `chain_reference_twobit` and `chain_query_prepared`.
    - Anti-repeat discounts masked bases, so this drops many small repeat-derived chains. It is the whole reason the
      old HLmyoMyot9A × HLmyoDau2 run had 2.5× fewer chains than v4.0.0. On SUPER_19 × NC_081858, chainAntiRepeat on
      WindowMasker-masked sequence gives 25,712 chains against the old run's 25,693.
  - Nothing runs unless a job overflowed, so pairs without one are untouched and cost nothing extra.
- **Verification:**
  - A fixture cut from the bats' arrays: 1 Mb of SUPER_13 and 1.3 Mb of NC_081852 plus an orthologous 1 Mb pair.
  - Off: the array × array job fails with the hint.
  - On: it is marked, WindowMasker+sdust covers 98.9% and 97.0% of the two arrays, and 25 masked sub-jobs take
    0.3 min in total. The run completes with 728 final chains.
  - With default chunks, both genomes form one BULK bin and the single job overflows. It is re-run as 36 masked
    sub-jobs; chaining, anti-repeat, fill and clean then read the masked genomes, and the run completes.
  - Real scale on Delta, CPU path, SUPER_13 × NC_081852 whole chromosomes:
    - the overflowing job stops after ~12 min;
    - genome-wide WindowMasker + sdust takes 18 min per genome and covers ~84% of the satellite arrays;
    - the 25 masked sub-jobs take at most 1.7 min each, and the run completes.

### Shared satellite arrays on the hspZ path: `--dense_windows`

On the hspZ path the same bat arrays cost time instead of failing: hspZ hands lastz at most ~50k anchors per task,
and each anchor in an array costs a ~34 kb extension. LASTZ_SEGMENTED needed ~4,770 CPU h for HLmyoMyot9A ×
HLmyoDau2; one 100 kb × 100 kb box (SUPER_13 × NC_081852) took 3,807 h of it.

- **`DENSE_WINDOWS`** (`bin/dense_windows.py`, one task per query, in `SEGMENTS_TO_PSL` before `LASTZ_SEGMENTED`)
  reads all of the query's segments in two steps:
  - Trigger: a 100 kb × 100 kb block (reference chromosome × query chromosome × strand) with ≥ 100k anchors.
    hg38 × mm39 peaks at 13,581, the three *Myotis* pairs at 1.46–3.42 M. Without one, nothing else happens.
  - Regions: anchors per 10 kb window along each genome, summed over all partner chromosomes. A window with ≥ 100k
    seeds a region, which grows through adjacent windows with ≥ 10k. Regions at most 2 windows apart are joined.
    - The block alone would miss arrays whose anchors are spread thin. Three of the 17 jobs that overflowed CPU lastz
      in the old bat run have no block over 82k but 77–143 blocks over 10k.
    - The windows alone would touch hg38 × mm39 (43 windows, 1.6% of its anchors), where nothing is wrong.
  - Minus-strand query positions count from the chromosome end in `.segments`; they are mirrored to forward
    coordinates first.
- **`--dense_windows`**: `report` (default) warns and publishes `<ref>.<query>.dense_windows.tsv` and the regions as
  BED in `02_hspz/dense_windows/`. `filter` drops the anchors whose reference or query position lies in a region,
  close to what soft-masking the regions before hspZ gives. `fail` stops before any lastz job. `off` skips the scan.
  - With `filter`, `MASK_GENOME` (now taking several BEDs and `ext.suffix`) soft-masks the regions into the genomes
    the later steps read (`DENSE_MASK_QUERY` per query, `DENSE_MASK_REFERENCE` with the union over queries). These are
    published as `*.dense.2bit`. `SEGMENTS_TO_PSL` emits them as `chain_reference_twobit` and `chain_query_prepared`,
    so both `--aligner hspz` and `--from segments` pass them to chaining, fill and clean.
  - `filter` and `fail` hold lastz until the scan has finished. `report` holds nothing. A query without a trigger
    keeps its own segment files and genomes in every mode.
- **Verification:**
  - HLmyoMyot9A × HLmyoDau2's unmasked hspZ run (346.8 M anchors, 16,246 files): 3.6 min on 16 cores. Densest
    block 3,147,829 anchors, 499 blocks ≥ 100k. The 75 + 72 regions are byte-identical to the mask that let all 17
    overflowing CPU lastz jobs finish. 33,167,718 anchors are kept, against the 33.2 M hspZ found on the genomes
    masked beforehand.
  - hg38 × mm39 (29.0 M anchors): 6.6 s, densest block 13,581, not triggered.
  - Fixture (`test_segments`): `off`, `report` and an untriggered `filter` give the same final chain. With the
    thresholds lowered to force a trigger:
    - `report` leaves the chains unchanged;
    - `filter` sends LASTZ_SEGMENTED the kept anchors on the original genomes, and AXT_CHAIN, anti-repeat,
      RepeatFiller and chainCleaner the `*.dense.2bit` genomes;
    - `fail` stops with the regions published and no lastz job started.
  - End to end on Delta (SLURM, `--from segments` from the unmasked hspZ run, `--dense_windows filter`,
    `--repeat_filler_engine hspz`): rc 0, 2 h 23 min wall, 72.3 CPU h allocated over all steps.
    - DENSE_WINDOWS: 7.6 min on 16 cores, same report as above. The `*.dense.2bit` genomes are byte-identical
      (twoBitToFa md5) to the genomes masked by hand for the re-run.
    - LASTZ_SEGMENTED: 5,155 tasks, 51.5 CPU h, longest 34.5 min, against ~4,770 CPU h unfiltered. All 5,155
      partitions passed the integrity check.
    - Final chains, against the re-run with the regions masked before hspZ: 16,095,848 vs 16,142,386 chains (−0.29%),
      aligned bp −0.13%, score sum −0.16%, largest chain identical to 0.00%. Dropping anchors after hspZ is close to
      running hspZ on the masked genomes but not the same, so the chains aren't byte-identical.
  - The 17 CPU lastz jobs that overflowed in the old bat run, re-run alone on the genomes with the regions masked: all
    17 finish without overflow. Sixteen take 1–26 min; SUPER_15 × NC_081854 takes 5.0 h (498k alignments).

### Known satellite arrays of the reference: `--mask_reference_regions_bed`

On hs1 (T2T-CHM13v2.0), elephants and a rodent ran LASTZ jobs that timed out at 1 h, 4 h and 8 h. HLloxAfr5A spent
about 950 CPU h in LASTZ_SEGMENTED, against 40–70 for other mammals. All of the slow jobs sit in hs1's HSat3
arrays (chr15:4.7–10.5 Mb on the short arm, chrY:26–63 Mb). These are 97.5% soft-masked, but hspZ seeds in their
unmasked islands, and lastz then extends each anchor through megabases of lowercase satellite. Single alignments ran
1.7 Mb before lastz's traceback memory cut them off. `--dense_windows` never triggered: the anchors are sparse (the
densest block holds 28k against a threshold of 100k), even though each extension is enormous.

- **`--mask_reference_regions_bed`** (default `""`, off): a BED of reference regions.
  - In every `--dense_windows` mode (also `off`), triggered or not, `DENSE_WINDOWS` drops the anchors whose
    reference span overlaps a region (exact bp, merged intervals).
  - It writes every file to `kept/`, plus `<ref>.<query>.mask_reference.bed` (the BED, plus the found regions with
    `filter`) and `.mask_query.bed`. `DENSE_MASK_REFERENCE` soft-masks the reference that chaining, fill and clean
    read; `DENSE_MASK_QUERY` runs only when the query side has regions.
  - `dense_windows.py` takes `--mask-reference-bed`, and `--mode off` (no scan, only the BED). The report adds
    `anchors_in_mask`, `anchors_kept` and the BED's size. Without the BED, its outputs are byte-identical to the
    previous commit in every mode.
  - Alignments that start outside a region can still extend into it, as with `--dense_windows filter`.
- **hs1 BED** (campaign): HSat1A, HSat1B, HSat2, HSat3, beta-satellite and rDNA from `chm13v2.0_censat_v2.1.bed`,
  merged (315 intervals, 145.3 Mb). Alpha satellite is left out: against seven non-primate mammals it holds
  0.001–0.005% of the anchors. The `ct` transition regions hold 4–13% and are ordinary sequence.
- **Verification:**
  - `test_segments`, no BED: all 8 published outputs are identical to the previous commit (final chain
    `e46056e91894`). With a BED over `mock1r:20000-40000`, `off`, `report` and `filter` each drop exactly the 35 of 73
    anchors an independent count finds, and they give the same final chain (`04f702dc4180`). AXT_CHAIN and the
    anti-repeat step read `test_ref.dense.2bit`, whose masked region is all lowercase. Aligned bases inside the
    region fall from 20,629 to 6,128.
  - Delta, real hspZ output with the hs1 BED: HLloxAfr5A drops 20.0 M of 62.3 M anchors (32.2%) in 41 s on 16
    cores, and 1,723 of 10,263 segment files lose every anchor. HLvulVul3 drops 1.9%. The six HLloxAfr5A LASTZ jobs
    that had run more than 4.8 h each on their third attempt lose every anchor.
  - End to end on Delta (`--from segments` from HLloxAfr5A's hspZ run, the campaign's settings with
    `--dense_windows filter`, SLURM, pipeline image 4.0.0-rc2): rc 0, 1.11 h wall, 102.4 CPU h allocated over all
    steps. LASTZ_SEGMENTED ran 8,540 tasks with none retried: 85.6 CPU h, longest 9 min, p99 2.4 min. The production
    run without the BED had 288 jobs time out at 1 h and 72 at 4 h, and was still running after 13 h (about 950 CPU
    h of LASTZ so far). Final chains: 15.9 M, largest 82.9 Mb aligned, and 0.03 Mb of aligned bases inside the BED.

### PSL step: no AXT, no split pass for hspZ, no bundle copies

HLmyoMyot9A × HLmyoDau2 (two Myotis bats, hspZ path) failed at `PSL_BUNDLE`. The run had written 5.2 TB of AXT, then 502 GB of PSL, and split that into 502 GB of per-chromosome PSL. SUPER_13's 406 GB file then ran `psl_bundle.py` out of memory, because it read each file whole. Every byte between `lastz` and `axtChain` was written two or three times, and on SLURM's BeeGFS scratch it was copied back once more.

- **`LASTZ_SEGMENTED`** pipes `lastz` into `axtToPsl`, as `KEG_LASTZ` already did, so no AXT is written.
  - It writes gzipped PSL with one file per reference chromosome: `psl/<chrom>/<segments id>.r<n>.psl.gz`.
  - The hspZ path therefore no longer has `AXT_TO_PSL` tasks, which halves its job count.
  - The step now runs in the pipeline image, which carries `axtToPsl`.
- **`CHAIN_BUILD`** takes a second input of per-chromosome PSL (`psl_by_chrom`), which skips `PSLTOOLS_SPLIT`.
  - The hspZ path and `--from segments` use it. The CPU backends still go through the split.
- **`PSL_BUNDLE` and `bin/psl_bundle.py` are removed.** `CHAIN_BUILD` plans the same bundles in Groovy (`pslBundles`):
  - chromosomes with PSL, largest first, until `bundle_psl_max_bases` or more than 1,000 chromosomes;
  - named `bundle.N` from 0.
- **`AXT_CHAIN`** takes a bundle's files and streams them into `axtChain -psl /dev/stdin`, plain or gzipped. No concatenated bundle is written.
  - For the CPU backends, axtChain receives the same bytes as from the old `bundle.N.psl`.
- **`--save_psl`** (default `false`): alignment PSL is published only on request. Nothing in the pipeline reads it back.
  - This covers `02_lastz_psl/`, `02_kegalign_psl/`, `02_hspz/psl/<chrom>/*.psl.gz` and `03_psl/`.
  - `02_hspz/axt/` is gone. `compare_aligners.sh` passes `--save_psl` and reads gzipped PSL.
- **slurm profile:**
  - `LASTZ_SEGMENTED` runs in job arrays: hg38 × mm39 gives 5,469 tasks, the bats 16,246.
  - `PSLTOOLS_SPLIT` writes in place (`scratch = false`), so its whole output is not copied back from scratch.
- Deleted `modules/local/chaintools/sort` (`CHAINTOOLS_SORT`), unused since 3.1.7 dropped its only caller.
- `assets/image/Dockerfile` no longer ships `psl_bundle.py`. The `hillerlab/containers` Dockerfile still copies it from the submodule, so drop that line when the submodule moves past this commit.
- **Verification** (pipeline image 4.0.0-rc, Nextflow 25.10.4, old code = the previous commit):
  - `compare.sh`: all goldens match.
  - `test_hspz` with both fill engines and `test` (lastz): final chain `d612024aa61d`, stats and coverage unchanged. PSL is published only with `--save_psl`.
  - `test` with `--bundle_psl_max_bases 1` (two bundles): `bundle.0.chain` and `bundle.1.chain` are byte-identical to the old `PSL_BUNDLE` path.
  - hg38 chr21 × mm39 chr16, `--aligner hspz` on ZLUDA: `axtChain` output (57,729 chains), anti-repeat output (6,683) and the merged chain are byte-identical to the old code.
    - 37 tasks instead of 65.
    - 3.7 MB of gzipped PSL written instead of 75.6 MB of AXT plus 35.8 MB of PSL (the same 28,374 alignments).

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
