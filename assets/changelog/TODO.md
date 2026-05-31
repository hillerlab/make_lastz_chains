# TODO list

## nf-core refactor (this branch)

### Done
- [x] nf-core DSL2 pipeline: `main.nf`, subworkflows, modules, `workflows/make_lastz_chains.nf`
- [x] Single unified `nextflow.config` (merged `conf/base.config` + `conf/modules.config`)
- [x] Checkpoint entry workflows: `FROM_FILL_CHAINS`, `FROM_CLEAN_CHAINS`
- [x] Per-entry validation functions (`validateFullRun`, `validateFromFillChains`, `validateFromCleanChains`)
- [x] `process_fast` label for short-lived steps → auto-routes to `htc` partition on SLURM
- [x] `check_max()` resource ceiling helper (caps memory/time against partition limits)
- [x] SLURM dynamic partition routing (`htc` < 4 h, `public` ≥ 4 h) with `--qos=public`
- [x] `process.array` job arrays for LASTZ, AXT_CHAIN, REPEAT_FILLER
- [x] Conda disabled by default; apptainer is the intended production profile
- [x] Dockerfile: full Kent distribution via rsync; `NetFilterNonNested.perl` pinned to commit `fbdd299` via correct raw URL
- [x] `environment.yml`: removed `twobitreader`/`py2bit`; added `ucsc-twobitinfo`; `.2bit` reading now via `twoBitToFa`
- [x] Removed dead params: `fill_chain_min_score`, `seq1_limit`, `seq2_limit`, `fill_prepare_memory`, `--chaining_memory`, `--fill_memory`, `--chain_clean_memory`
- [x] `-params-file` documented as replacement for old `--params_from_file`
- [x] `bin/partition.py`, `bin/psl_bundle.py`, `bin/split_chains.py` extracted for Nextflow work dirs
- [x] README rewritten for nf-core pipeline
- [x] `CHANGES_nfcore_refactor.md` written

### Still needed before merging
- [x] Build Docker image (`docker://nilablueshirt/make_lastz_chains:latest-amd64`), update `nextflow.config`
- [ ] Run `nextflow run main.nf -profile test,apptainer` to validate end-to-end locally
- [ ] Run `nextflow run main.nf -profile test,apptainer,slurm` on HPC to validate SLURM job array submission for LASTZ, AXT_CHAIN, REPEAT_FILLER
- [ ] Run `nf-core lint` and fix reported issues before nf-core submission
  - [ ] Decide scope: full `nf-core/<name>` submission vs. lint-hygiene-only (latter → use `.nf-core.yml` `lint:` skips to opt out of irrelevant checks)
  - [ ] **Manifest** ([nextflow.config](nextflow.config) lines 27-35): rename `manifest.name` from bare `make_lastz_chains` to `<org>/<pipeline>` form (e.g. `hillerlab/make_lastz_chains`) — fails `pipeline_name_conventions`
  - [ ] **Required top-level files**: add `.nf-core.yml`, `.editorconfig`, `.gitattributes`, `.prettierrc.yml`, `.prettierignore`, `.pre-commit-config.yaml`, `modules.json`, `CITATIONS.md`, `CODE_OF_CONDUCT.md`
  - [ ] **Filename casing**: rename git-tracked `Changelog.md` → `CHANGELOG.md` (use `git mv` so it survives case-insensitive macOS)
  - [ ] **`.github/` scaffolding**: `workflows/ci.yml`, `workflows/linting.yml`, `workflows/linting_comment.yml`, `workflows/branch.yml`, issue/PR templates, `CONTRIBUTING.md`
  - [ ] **`conf/` split**: extract `base.config`, `modules.config`, `test.config`, `test_full.config` out of the unified [nextflow.config](nextflow.config)
  - [ ] **`assets/`**: email templates, `nf-core-<pipeline>_logo_light.png`, `schema_input.json` for samplesheet
  - [ ] **`docs/`**: `usage.md`, `output.md`, `docs/README.md`
  - [ ] **Profiles**: add the standard set lint expects — `docker`, `singularity`, `conda`, `mamba`, `podman`, `test`, `test_full`
  - [ ] **`params.input`**: declare in `params {}` + schema (nf-core assumes samplesheet entrypoint)
  - [ ] **Module layout**: each [modules/local/*/main.nf](modules/local/) needs sibling `environment.yml` + `meta.yml` (currently main.nf only) — fails `modules_structure`
  - [ ] **Legacy Python files**: decide fate of top-level legacy pipeline (`make_chains.py`, `constants.py`, `install_dependencies.py`, `version.py`, `parallelization/`, `steps_implementations/`) — lint will flag as unexpected files
  - [ ] **Bootstrap step**: `pip install nf-core && nf-core pipelines lint` to get the authoritative report; cross-reference against an `nf-core pipelines create` throwaway dir for canonical template files
- [ ] Test checkpoint entry workflows (`FROM_FILL_CHAINS`, `FROM_CLEAN_CHAINS`) — not covered by full-run tests
- [ ] Validate issue #56 fix end-to-end on a genome >4 GB (confirm twoBitToFa path works in production)
- [ ] Output parity check — diff final `.chain.gz` from old pipeline vs new on the same genome pair
- [ ] Smoke test `make_chains.py` backward-compat entry point still launches correctly

---

## Original pipeline

### Mandatory
- Documentation
- ~~Full scale test~~
- ~~get rid of negatively scored chains~~
- ~~Organise cat step better~~
- ~~Get rid of all magic numbers and strings~~
- ~~Check for output presence after each step~~
- ~~Nextflow manager class~~ → dedicated class for NF config
- ~~Double check the pipeline default parameters~~
- ~~Fix the install dependencies script~~
- ~~Logging messages~~
- ~~For all subprocesses → error handling~~
- ~~Check for absent expected files~~

### Nice to do
- Handle `missing *.so` errors from Kent binaries more gracefully: https://github.com/hillerlab/make_lastz_chains/issues/34
- QC module: https://github.com/hillerlab/make_lastz_chains/issues/33
- Clarify what `lastz_q` does and whether it is needed
- Implement `seq1_limit` / `seq2_limit` sequence length filtering in `bin/partition.py` (accepted as params in the old CLI but never applied in either pipeline)
- ~~Refactor HL kent dependencies~~ → not split anymore
- ~~Refactor chain gap filler: get rid of chainExtractID dependency~~
- ~~Read parameters from config file~~
- ~~Temp files location~~ https://github.com/hillerlab/make_lastz_chains/issues/20

### Ideas for additional features
- Self chains: https://github.com/hillerlab/make_lastz_chains/issues/31

### Very minor
- `install_dependencies.py` crash `FileNotFoundError: [Errno 2] No such file or directory: 'wget'` → show a better error suggesting to install wget
