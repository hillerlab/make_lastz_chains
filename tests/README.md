# make_lastz_chains — golden comparison tests

CI runs `tests/ci/compare.sh` on every push/PR. It runs the pipeline twice and
diffs the published outputs against committed "golden" files:

1. **e2e** (`tests/ci/e2e_*`): full pipeline (LASTZ → axtChain → fill → clean
   → filter) on the bundled synthetic genomes (`test_data/`).
2. **cba** (`tests/ci/cba_*`): the clean step only (`--from clean_chains`) on a
   hand-crafted chain with one chain-breaking alignment — guarantees the clean
   step actually **removes** a suspect. The tiny synthetic genomes produce no
   CBAs, so this fixture is the one that exercises the removal code path.

Goldens live in `tests/golden/{e2e,cba}/`:

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
bash tests/ci/make_golden.sh   # reruns pipeline + rewrites tests/golden/
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
