# Make Lastz Chains

[![made-with-Nextflow](https://img.shields.io/badge/Made%20with-Nextflow-23aa62.svg)](https://www.nextflow.io/)

Pairwise genome alignment chains. Inputs to [TOGA](https://github.com/hillerlab/TOGA) and multiz.

![Abstract Chains](readme_images/abstract_chains.png)

- Chain format: https://genome.ucsc.edu/goldenPath/help/chain.html
- Chains overview: http://genomewiki.ucsc.edu/index.php/Chains_Nets

---

## Before you run

- **Softmask both genomes** (lowercase, do NOT hardmask). RepeatModeler 2 per genome is recommended; add WindowMasker if you see runaway LASTZ runtimes.
- **Scaffold names**: no spaces; avoid dots (rename `NC_00000.1` → `NC_00000`). Restore originals with `standalone_scripts/rename_chromosomes_back.py`.
- Inputs accepted: `.fasta` or `.2bit`.

---

## 1. Original Python pipeline (`make_chains.py`)

<details>
<summary>Click to expand</summary>

```bash
git clone https://github.com/hillerlab/make_lastz_chains.git
cd make_lastz_chains
mamba env create -f environment.yml
mamba activate make_lastz_chains

python make_chains.py \
    --project_dir    /path/to/output \
    --target_genome  /path/to/target.fa \
    --query_genome   /path/to/query.fa \
    --target_name    hg38 \
    --query_name     mm39
```

Or pass all parameters from a file:
```bash
python make_chains.py --params_from_file my_params.yaml
```

</details>

---

## 2. nf-core pipeline — local (Docker / Apptainer)

<details>
<summary>Click to expand</summary>

Requirements: Nextflow ≥ 25.04.6, Docker or Apptainer, Java.

```bash
git clone https://github.com/hillerlab/make_lastz_chains.git
cd make_lastz_chains
```

Edit `params.json` (set `target_name`, `query_name`, `target_genome`, `query_genome`), then:

```bash
# Docker
nextflow run main.nf -params-file params.json -profile docker

# Apptainer / Singularity
nextflow run main.nf -params-file params.json -profile apptainer
```

Build the image locally (optional):
```bash
docker buildx build --platform linux/amd64 -t nilablueshirt/make_lastz_chains:latest-amd64 .
```

Use a pre-built Apptainer SIF (optional):
```bash
apptainer build make_lastz_chains.sif docker://nilablueshirt/make_lastz_chains:latest-amd64
export NXF_CONTAINER_IMAGE=/path/to/make_lastz_chains.sif
```

Smoke test:
```bash
nextflow run main.nf -profile test,apptainer
```

</details>

---

## 3. nf-core pipeline — HPC (SLURM)

<details>
<summary>Click to expand</summary>

Requirements: Nextflow ≥ 25.04.6, Apptainer, Java, SLURM cluster.

```bash
git clone https://github.com/hillerlab/make_lastz_chains.git
cd make_lastz_chains
```

Edit the path variables at the top of `run_nf_slurm_example.sh` (cache dir, container image, manifest path), then submit:

```bash
sbatch --array=1-<N> run_nf_slurm_example.sh
```

Each array task spawns one Nextflow head job that submits all compute as child SLURM jobs.

LASTZ, AXT_CHAIN, and REPEAT_FILLER run as SLURM job arrays. Partition routing, array sizes, and resource tiers are documented inline in `nextflow.config` — edit there to match your cluster.

</details>

---

## Checkpoint resumes

```bash
# Resume from failure
nextflow run main.nf -params-file params.json -profile apptainer -resume

# Restart from *.all.chain.gz
nextflow run main.nf -entry FROM_FILL_CHAINS -params-file params.json \
    --merged_chain       results/chain_merge/hg38.mm39.all.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer

# Restart from *.filled.chain.gz
nextflow run main.nf -entry FROM_CLEAN_CHAINS -params-file params.json \
    --filled_chain       results/fill_chains/hg38.mm39.filled.chain.gz \
    --target_twobit      results/genome_prep/target.2bit \
    --query_twobit       results/genome_prep/query.2bit \
    --target_chrom_sizes results/genome_prep/target.chrom.sizes \
    --query_chrom_sizes  results/genome_prep/query.chrom.sizes \
    -profile apptainer
```

For SLURM, add `,slurm` to the `-profile` flag.

---

## Output

```
results/
├── genome_prep/      target.2bit, query.2bit, *.chrom.sizes
├── partition/        *_partitions.txt
├── chain_merge/      *.all.chain.gz        ← checkpoint for FROM_FILL_CHAINS
├── fill_chains/      *.filled.chain.gz     ← checkpoint for FROM_CLEAN_CHAINS
├── final/            *.final.chain.gz      ← final output
└── pipeline_info/    timeline, trace, DAG
```

---

## Where to edit

| File | What |
|------|------|
| `params.json` | Genome paths, alignment settings — per run |
| `nextflow.config` | Compute resources, profiles, container, SLURM — rarely |
| `run_nf_slurm_example.sh` | SLURM submission wrapper for multi-pair runs |

Design rationale and root-cause writeups: [CHANGES_nfcore_refactor.md](CHANGES_nfcore_refactor.md).

---

## Citation

- Kirilenko BM, Munegowda C, Osipova E, Jebb D, Sharma V, Blumer M, Morales A, Ahmed AW, Kontopoulos DG, Hilgers L, Lindblad-Toh K, Karlsson EK, Zoonomia Consortium, Hiller M. [Integrating gene annotation with orthology inference at scale.](https://www.science.org/stoken/author-tokens/ST-1161/full) Science, 380, 2023
- Osipova E, Hecker N, Hiller M. [RepeatFiller newly identifies megabases of aligning repetitive sequences and improves annotations of conserved non-exonic elements.](https://academic.oup.com/gigascience/article/8/11/giz132/5631861) GigaScience, 8(11), giz132, 2019
- Suarez H, Langer BE, Ladde P, Hiller M. [chainCleaner improves genome alignment specificity and sensitivity.](https://academic.oup.com/bioinformatics/article/33/11/1596/2929344) Bioinformatics, 33(11), 1596-1603, 2017
- Kent WJ, Baertsch R, Hinrichs A, Miller W, Haussler D. [Evolution's cauldron: Duplication, deletion, and rearrangement in the mouse and human genomes.](https://www.pnas.org/doi/10.1073/pnas.1932072100) PNAS, 100(20):11484-9, 2003
- Mu NT, Dizon W, Otero G, Battelle T. [Optimizing Nextflow-based Software on Shared HPC Resources: A Case Study with make_lastz_chains.](https://doi.org/10.5281/zenodo.17118383) US Research Software Engineering Conference (USRSE'25), Philadelphia, PA, 2025
