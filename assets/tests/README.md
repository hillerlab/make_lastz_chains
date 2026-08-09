# make_lastz_chains — golden comparison tests

CI runs `assets/tests/ci/compare.sh` on every push/PR. It runs the pipeline twice and
diffs the published outputs against committed "golden" files:

1. **e2e** (`assets/tests/ci/e2e_*`): full pipeline (LASTZ → axtChain → fill → clean
   → filter) on the bundled synthetic genomes (`assets/tests/test_data/`).
2. **cba** (`assets/tests/ci/cba_*`): the clean step only (`--from clean_chains`) on a
   hand-crafted chain with one chain-breaking alignment — guarantees the clean
   step actually **removes** a suspect. The tiny synthetic genomes produce no
   CBAs, so this fixture is the one that exercises the removal code path.

A third script, `assets/tests/ci/compare_aligners.sh`, runs the same synthetic fixture
three ways — `--aligner lastz`, `--aligner kegalign --kegalign_executor batched`,
and `--aligner kegalign --kegalign_executor distributed` — and checks that each
completes with non-empty PSL and a non-empty final chain. Then:

- **lastz vs kegalign**: chain aligned bases must agree within `TOLERANCE`
  (default 20%); the normalised chain diff is printed for inspection only, since
  KegAlign partitions differently from LASTZ and byte identity is not claimed.
- **batched vs distributed**: normalised PSL and final chains must match
  **exactly**. Both executors run the identical KegAlign-generated LASTZ
  commands, so any difference is a bug, not a tolerance question.

KegAlign has no CPU fallback, so the script **skips (exit 0) when no GPU is
present** and is deliberately not part of the GitHub-hosted CI jobs above.

`bin/run_keg_lastz.py --self-check` asserts the LASTZ-command reconstruction and
stderr-tolerance rules that the distributed executor depends on. It needs neither
a GPU nor LASTZ, so it is runnable anywhere.

Goldens live in `assets/tests/golden/{e2e,cba}/`:

| file | what |
|---|---|
| `final.chain` | decompressed `07_final/*.chain.gz` |
| `cleaned_intermediate.chain` | `06_cleaned_chains/*.chain` (chainc `${meta.id}.chain`) |
| `removed_suspects.bed` | `06_cleaned_chains/*.removed.bed` (chainc `${meta.id}.removed.bed`) |

## Purpose

These goldens are snapshots of the **original** pipeline (chainCleaner). The
chainc swap keeps these files as the reference: the identical CI job diffs
chainc output against them. They pass byte-for-byte — the swap changes nothing.

## Regenerating goldens

Only after an intentional, human-approved change (e.g. a tool/image bump that
legitimately changes output):

```bash
bash assets/tests/ci/make_golden.sh   # reruns pipeline + rewrites assets/tests/golden/
```

Notes:

- The pipeline container is `ghcr.io/hillerlab/make_lastz_chains:latest`
  (override with `NXF_CONTAINER_IMAGE`). `:latest` drifts — if a non-chainc tool
  update breaks byte-identity, regenerate goldens. The image (and the chainc
  addition) is built from the `hillerlab/containers` repo —
  `images/make_lastz_chains/` — the copy at `assets/image/Dockerfile` mirrors it.
- Chain output is deterministic for a given image (verified); gzip itself is
  not, so `final.chain.gz` is compared decompressed.
- Nextflow is pinned to 25.04.6 in CI: the config's `nextflowVersion = '!>=25.04.6'`
  and Nextflow 26.x rejects the repo's `if (params.use_container)` config block.
