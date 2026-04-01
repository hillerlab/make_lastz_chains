# Make Lastz Chains

[![made-with-Nextflow](https://img.shields.io/badge/Made%20with-Nextflow-23aa62.svg)](https://www.nextflow.io/)

Portable Hillerlab solution for generating pairwise genome alignment chains.
These chains can be used as input for [TOGA](https://github.com/hillerlab/TOGA) or for generating multiz alignments.

![Abstract Chains](readme_images/abstract_chains.png)

Chains explained: http://genomewiki.ucsc.edu/index.php/Chains_Nets

Chain format specification: https://genome.ucsc.edu/goldenPath/help/chain.html

## Requirements

- Nextflow ≥ 23.10.0 (required for SLURM job array support)
- Apptainer/Singularity, Docker, or conda
- Java runtime (required by Nextflow)

⚠️ Although the pipeline runs on macOS, it is strongly recommended to use it on a Linux-based machine.

## Installation

```bash
git clone https://github.com/hillerlab/make_lastz_chains.git
cd make_lastz_chains
```

All tools are bundled in the container image built from the `Dockerfile`:
- Full UCSC Kent binary distribution (via rsync)
- `NetFilterNonNested.perl` pinned to commit `fbdd299`
- LASTZ v1.04.22
- Python 3 + py2bit

```bash
docker build -t make_lastz_chains:latest .
# push to a registry, then set the URI in nextflow.config:
#   docker://ghcr.io/your-org/make_lastz_chains:latest
```

See `CHANGES_nfcore_refactor.md` for full details.

## Proper RepeatMasking is crucial

Before running the pipeline, please make sure that $${\color{red}both \space reference}$$ and $${\color{red}query}$$ genome is properly repeatMasked. This is the most common problem that many users encountered. Masking that is produced by NCBI is $${\color{red}NOT}$$ sufficient.

We therefore highly recommend running RepeatModeler 2 on the reference genome, generating a consensus.fa repeat library for this genome and using this library to softmask (lower case; do NOT hardmask) the reference genome.

The same procedure should be done for the query genome (generating an independent repeat library for it).

In case you still get excessive lastz job run times that could indicate still insufficient masking, pls try the following:
* Split your reference and query into smaller chunks using `--seq1_chunk` / `--seq2_chunk`. This will give more but smaller jobs. Many of the 'normal' jobs will now run very fast and the problematic ones may now also finish within several hours or a day.
* Run WindowMasker on the reference and query genome and add the windowMask to the softmask. We have seen cases where satellite repeats (e.g. likely in centromers) are not properly masked by RepeatMasker. WindowMasker does a good job in masking these satellites.

Important: Over-excessive masking will lead to missed alignments (that also RepeatFiller won't unearth, because we restrict it to unaligning regions of certain sizes), because lastz only seeds in non-masked regions and alignments of homologous repetitive regions are only found by extending into them.

## Input genomes

Genome sequences can be provided in either `fasta` or `twobit` formats.
Please find the 2bit file format specification [here](https://genome.ucsc.edu/FAQ/FAQformat.html#format7).

⚠️ If your scaffold names contain dots (e.g. `NC_00000.1`), consider removing the version number
(rename to `NC_00000` or `NC_00000__1`). The chain format does not allow spaces in scaffold names —
if the pipeline detects spaces in chain headers, it will crash.

If you wish to rename chromosomes back to their original names after the run, use
`standalone_scripts/rename_chromosomes_back.py`.

## Quick start

```bash
# Full run with apptainer on a SLURM cluster
nextflow run main.nf \
    --target_name   hg38 \
    --query_name    mm39 \
    --target_genome /path/to/hg38.fa \
    --query_genome  /path/to/mm39.fa \
    --outdir        results/ \
    -profile        apptainer,slurm

# Test run with bundled test data
nextflow run main.nf -profile test,apptainer,slurm

# Pass all parameters from a JSON file
nextflow run main.nf -params-file my_params.json -profile apptainer,slurm

# Print all available parameters
nextflow run main.nf --help
```

## Checkpoint entry points

If a run fails after the expensive LASTZ or fill-chains steps, you can restart from a
published intermediate rather than rerunning from scratch.

For mid-run recovery (e.g. a node failure), Nextflow's built-in `-resume` is sufficient:
```bash
nextflow run main.nf [same args as original run] -resume
```

To restart from a specific published intermediate:

```bash
# Skip LASTZ + chain build — start from *.all.chain.gz
nextflow run main.nf -entry FROM_FILL_CHAINS \
    --target_name        hg38 \
    --query_name         mm39 \
    --merged_chain       results/chain_merge/hg38.mm39.all.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer,slurm

# Skip LASTZ + chain build + fill — start from *.filled.chain.gz
nextflow run main.nf -entry FROM_CLEAN_CHAINS \
    --target_name        hg38 \
    --query_name         mm39 \
    --filled_chain       results/fill_chains/hg38.mm39.filled.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer,slurm
```

## Output structure

```
results/
├── genome_prep/      target.2bit, query.2bit, *.chrom.sizes
├── partition/        *_partitions.txt
├── chain_merge/      *.all.chain.gz        ← checkpoint for FROM_FILL_CHAINS
├── fill_chains/      *.filled.chain.gz     ← checkpoint for FROM_CLEAN_CHAINS
├── final/            *.final.chain.gz      ← final output
└── pipeline_info/    execution timeline, trace, DAG (HTML)
```

## SLURM partition routing

Jobs are automatically routed based on wall-time request — no manual queue selection needed:

| Label | Steps | Time request | SLURM partition | QOS |
|-------|-------|-------------|-----------------|-----|
| `process_fast` | genome prep, partition, cat, bundle, filter | 2 h | `htc` | `public` |
| `process_single` | LASTZ, repeat filler | 48 h | `public` | `public` |
| `process_medium` | PSL sort, axtChain, merge | 48 h | `public` | `public` |
| `process_high` | chainCleaner | 48 h | `public` | `public` |

LASTZ, AXT_CHAIN, and REPEAT_FILLER submit tasks as **SLURM job arrays**, reducing scheduler
overhead for large genome pairs (thousands of individual jobs).

## Configuration

All configuration lives in a single `nextflow.config` file organised into five sections:

1. `params {}` — scientific and I/O parameters
2. `withLabel` — compute resource tiers (memory, time per attempt)
3. `withName` — per-step container, conda, publishDir
4. `profiles {}` — executor and environment selection (`apptainer`, `slurm`, `conda`, etc.)
5. Reporting — execution timeline, trace, DAG

See `CHANGES_nfcore_refactor.md` for a full description of design decisions and differences
from the original Python pipeline.

## Citation

- Kirilenko BM, Munegowda C, Osipova E, Jebb D, Sharma V, Blumer M, Morales A, Ahmed AW, Kontopoulos DG, Hilgers L, Lindblad-Toh K, Karlsson EK, Zoonomia Consortium, Hiller M. [Integrating gene annotation with orthology inference at scale.](https://www.science.org/stoken/author-tokens/ST-1161/full), Science, 380, 2023
- Osipova E, Hecker N, Hiller M. [RepeatFiller newly identifies megabases of aligning repetitive sequences and improves annotations of conserved non-exonic elements.](https://academic.oup.com/gigascience/article/8/11/giz132/5631861) GigaScience, 8(11), giz132, 2019
- Suarez H, Langer BE, Ladde P, Hiller M. [chainCleaner improves genome alignment specificity and sensitivity.](https://academic.oup.com/bioinformatics/article/33/11/1596/2929344) Bioinformatics, 33(11), 1596-1603, 2017
- Kent WJ, Baertsch R, Hinrichs A, Miller W, Haussler D. [Evolution's cauldron: Duplication, deletion, and rearrangement in the mouse and human genomes](https://www.pnas.org/doi/10.1073/pnas.1932072100) PNAS, 100(20):11484-9, 2003
- Mu NT, Dizon W, Otero G, Battelle T. [Optimizing Nextflow-based Software on Shared HPC Resources: A Case Study with make_lastz_chains.](https://doi.org/10.5281/zenodo.17118383) US Research Software Engineering Conference (USRSE'25), Philadelphia, PA, 2025
