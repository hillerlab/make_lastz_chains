# Make Lastz Chains

[![made-with-Nextflow](https://img.shields.io/badge/Made%20with-Nextflow-23aa62.svg)](https://www.nextflow.io/)

Portable Hillerlab solution for generating pairwise genome alignment chains.
These chains can be used as input for [TOGA](https://github.com/hillerlab/TOGA) or for generating multiz alignments.

![Abstract Chains](readme_images/abstract_chains.png)

Chains explained: http://genomewiki.ucsc.edu/index.php/Chains_Nets

Chain format specification: https://genome.ucsc.edu/goldenPath/help/chain.html

---

## Table of Contents

- [Proper RepeatMasking is crucial](#proper-repeatmasking-is-crucial)
- [Input genomes](#input-genomes)
- [1. Running the original Python pipeline](#1-running-the-original-python-pipeline-make_chainspy)
- [2. Running the nf-core pipeline locally](#2-running-the-nf-core-pipeline-on-your-local-computer)
- [3. Running the nf-core pipeline on HPC (SLURM)](#3-running-the-nf-core-pipeline-on-hpc-slurm)
- [Citation](#citation)

---

## Proper RepeatMasking is crucial

Before running the pipeline, please make sure that $${\color{red}both \space reference}$$ and $${\color{red}query}$$ genome is properly repeatMasked. This is the most common problem that many users encountered. Masking that is produced by NCBI is $${\color{red}NOT}$$ sufficient.

We therefore highly recommend running RepeatModeler 2 on the reference genome, generating a consensus.fa repeat library for this genome and using this library to softmask (lower case; do NOT hardmask) the reference genome.

The same procedure should be done for the query genome (generating an independent repeat library for it).

In case you still get excessive lastz job run times that could indicate still insufficient masking, try the following:
* Split your reference and query into smaller chunks using `--seq1_chunk` / `--seq2_chunk`. This will give more but smaller jobs.
* Run WindowMasker on the reference and query genome and add the windowMask to the softmask. We have seen cases where satellite repeats (e.g. likely in centromeres) are not properly masked by RepeatMasker. WindowMasker does a good job in masking these satellites.

Important: Over-excessive masking will lead to missed alignments, because lastz only seeds in non-masked regions.

---

## Input genomes

Genome sequences can be provided in either `fasta` or `twobit` formats.
Please find the 2bit file format specification [here](https://genome.ucsc.edu/FAQ/FAQformat.html#format7).

⚠️ If your scaffold names contain dots (e.g. `NC_00000.1`), consider removing the version number
(rename to `NC_00000` or `NC_00000__1`). The chain format does not allow spaces in scaffold names —
if the pipeline detects spaces in chain headers, it will crash.

If you wish to rename chromosomes back to their original names after the run, use
`standalone_scripts/rename_chromosomes_back.py`.

---

## 1. Running the original Python pipeline (`make_chains.py`)

<details>
<summary>Click to expand</summary>

The original Python-orchestrated pipeline is preserved for backward compatibility.

### Requirements

- Python 3
- Nextflow (used as a generic parallel job runner)
- UCSC Kent tools, LASTZ, RepeatFiller installed on `$PATH`
- `py2bit` Python package (`pip install py2bit`)

### Installation

```bash
git clone https://github.com/hillerlab/make_lastz_chains.git
cd make_lastz_chains
pip install -r requirements.txt   # if present, otherwise: pip install py2bit
```

### Usage

```bash
python make_chains.py \
    --project_dir    /path/to/output \
    --target_genome  /path/to/target.fa \
    --query_genome   /path/to/query.fa \
    --target_name    hg38 \
    --query_name     mm39
```

Key optional flags:

| Flag | Default | Description |
|------|---------|-------------|
| `--seq1_chunk` | 175000000 | Target partition size (bp) |
| `--seq2_chunk` | 300000000 | Query partition size (bp) |
| `--lastz_q` | (none) | Path to lastz scoring matrix |
| `--continue_from_step` | (none) | Resume from a named step |

Pass all parameters from a file:
```bash
python make_chains.py --params_from_file my_params.yaml
```

</details>

---

## 2. Running the nf-core pipeline on your local computer

<details>
<summary>Click to expand</summary>

### Requirements

- Nextflow ≥ 23.10.0
- Docker or Apptainer/Singularity
- Java runtime (required by Nextflow)

### Installation

```bash
git clone https://github.com/hillerlab/make_lastz_chains.git
cd make_lastz_chains
```

The container image (`nilablueshirt/make_lastz_chains:latest-amd64`) includes all tools.
To build it locally:
```bash
docker buildx build --platform linux/amd64 -t nilablueshirt/make_lastz_chains:latest-amd64 .
```

### Quick start

Scientific parameters (genome paths, alignment settings) are configured in `params.json`.
Edit it for your run, then pass it with `-params-file`:

```bash
# 1. Edit params.json — set target_name, query_name, target_genome, query_genome
vi params.json

# 2a. Run with Docker
nextflow run main.nf -params-file params.json -profile docker

# 2b. Run with Apptainer/Singularity
nextflow run main.nf -params-file params.json -profile apptainer
```

`nextflow.config` only needs editing to change compute resource limits or the container image URI.

### Test run

```bash
nextflow run main.nf -profile test,apptainer
```

### Checkpoint entry points

For mid-run recovery after a failure, Nextflow's built-in `-resume` is sufficient:
```bash
nextflow run main.nf -params-file params.json -profile apptainer -resume
```

To restart from a published intermediate file, set the checkpoint fields in your `params.json`
(or pass them as extra flags) and use the appropriate entry alias:

```bash
# Skip LASTZ + chain build — start from *.all.chain.gz
nextflow run main.nf -entry FROM_FILL_CHAINS -params-file params.json \
    --merged_chain       results/chain_merge/hg38.mm39.all.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer

# Skip LASTZ + chain build + fill — start from *.filled.chain.gz
nextflow run main.nf -entry FROM_CLEAN_CHAINS -params-file params.json \
    --filled_chain       results/fill_chains/hg38.mm39.filled.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer
```

### Output structure

```
results/
├── genome_prep/      target.2bit, query.2bit, *.chrom.sizes
├── partition/        *_partitions.txt
├── chain_merge/      *.all.chain.gz        ← checkpoint for FROM_FILL_CHAINS
├── fill_chains/      *.filled.chain.gz     ← checkpoint for FROM_CLEAN_CHAINS
├── final/            *.final.chain.gz      ← final output
└── pipeline_info/    execution timeline, trace, DAG (HTML)
```

</details>

---

## 3. Running the nf-core pipeline on HPC (SLURM)

<details>
<summary>Click to expand</summary>

### Requirements

- Nextflow ≥ 23.10.0
- Apptainer/Singularity (recommended for HPC)
- Java runtime
- SLURM scheduler

### Quick start

```bash
# Edit params.json first, then:
nextflow run main.nf -params-file params.json -profile apptainer,slurm
```

Nextflow itself should be run from a login node or a long-running session (e.g. `tmux`, `screen`,
or an interactive node). It submits all compute jobs as SLURM batch jobs.

### SLURM partition routing

Jobs are automatically routed based on wall-time — no manual queue selection needed:

| Label | Steps | Time | SLURM partition | QOS |
|-------|-------|------|-----------------|-----|
| `process_fast` | genome prep, partition, cat, bundle, filter | 2 h | `htc` | `public` |
| `process_single` | LASTZ, repeat filler | 48 h | `public` | `public` |
| `process_medium` | PSL sort, axtChain, merge | 48 h | `public` | `public` |
| `process_high` | chainCleaner | 48 h | `public` | `public` |

### SLURM job arrays

LASTZ, AXT_CHAIN, and REPEAT_FILLER submit tasks as **SLURM job arrays** (Nextflow ≥ 23.10.0),
reducing scheduler overhead for large genome pairs (thousands of individual jobs).

Array sizes: LASTZ=500, AXT_CHAIN=100, REPEAT_FILLER=500.

### Resource limits

The pipeline caps all resource requests against `max_memory`, `max_cpus`, and `max_time`
in `nextflow.config`. Defaults match the public partition:

```groovy
max_memory = '248.GB'
max_cpus   = 52
max_time   = '240.h'
```

Override on the command line if your cluster has different limits:
```bash
nextflow run main.nf -params-file params.json --max_memory 122.GB --max_cpus 28 -profile apptainer,slurm
```

### Checkpoint entry points

```bash
# Resume from a failed run
nextflow run main.nf -params-file params.json -resume -profile apptainer,slurm

# Restart from *.all.chain.gz
nextflow run main.nf -entry FROM_FILL_CHAINS -params-file params.json \
    --merged_chain       results/chain_merge/hg38.mm39.all.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer,slurm

# Restart from *.filled.chain.gz
nextflow run main.nf -entry FROM_CLEAN_CHAINS -params-file params.json \
    --filled_chain       results/fill_chains/hg38.mm39.filled.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer,slurm
```

### Configuration

| File | Purpose |
|------|---------|
| `params.json` | Scientific parameters — edit this for every run |
| `nextflow.config` | Infrastructure — compute tiers, SLURM settings, container image |

`nextflow.config` is organised into five sections:
1. `params {}` — output dir, resource ceilings, nf-core boilerplate
2. `withLabel` — compute resource tiers (memory, time per attempt)
3. `withName` — per-step container, conda, publishDir
4. `profiles {}` — executor and environment selection
5. Reporting — execution timeline, trace, DAG

See `CHANGES_nfcore_refactor.md` for a full description of design decisions.

</details>

---

## Citation

- Kirilenko BM, Munegowda C, Osipova E, Jebb D, Sharma V, Blumer M, Morales A, Ahmed AW, Kontopoulos DG, Hilgers L, Lindblad-Toh K, Karlsson EK, Zoonomia Consortium, Hiller M. [Integrating gene annotation with orthology inference at scale.](https://www.science.org/stoken/author-tokens/ST-1161/full), Science, 380, 2023
- Osipova E, Hecker N, Hiller M. [RepeatFiller newly identifies megabases of aligning repetitive sequences and improves annotations of conserved non-exonic elements.](https://academic.oup.com/gigascience/article/8/11/giz132/5631861) GigaScience, 8(11), giz132, 2019
- Suarez H, Langer BE, Ladde P, Hiller M. [chainCleaner improves genome alignment specificity and sensitivity.](https://academic.oup.com/bioinformatics/article/33/11/1596/2929344) Bioinformatics, 33(11), 1596-1603, 2017
- Kent WJ, Baertsch R, Hinrichs A, Miller W, Haussler D. [Evolution's cauldron: Duplication, deletion, and rearrangement in the mouse and human genomes](https://www.pnas.org/doi/10.1073/pnas.1932072100) PNAS, 100(20):11484-9, 2003
- Mu NT, Dizon W, Otero G, Battelle T. [Optimizing Nextflow-based Software on Shared HPC Resources: A Case Study with make_lastz_chains.](https://doi.org/10.5281/zenodo.17118383) US Research Software Engineering Conference (USRSE'25), Philadelphia, PA, 2025
