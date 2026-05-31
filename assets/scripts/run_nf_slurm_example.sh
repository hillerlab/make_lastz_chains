#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Example SLURM submission script for make_lastz_chains (nf-core pipeline)
#
# Each array task runs one target × query genome pair. Nextflow itself is the
# "main job" — it submits all compute work as child SLURM jobs and only needs
# a small memory footprint.
#
# MANIFEST FILE FORMAT (species_list)
# ─────────────────────────────────────
# A tab-separated file with one pair per line, no header:
#
#   <target_name>  <target_genome_path>  <query_name>  <query_genome_path>
#
# Example:
#   Human   /data/genomes/hg38.fa       Mouse   /data/genomes/mm39.fa
#   Human   /data/genomes/hg38.fa       Rat     /data/genomes/rn7.fa
#
# Genome files can be FASTA (.fa / .fasta) or 2bit (.2bit).
# Paths must be absolute. Scaffold names must not contain spaces or dots
# (rename NC_000001.1 → NC_000001 or NC_000001__1 if needed).
#
# USAGE
# ─────
# Edit the four path variables below, then submit with:
#   sbatch --array=1-<N> run_nf_slurm_example.sh
# where <N> is the number of lines in your manifest file.
# ─────────────────────────────────────────────────────────────────────────────

#SBATCH --job-name=makeChains
#SBATCH --array=1-10        # set upper bound to number of lines in species_list
#SBATCH -t 2-0
#SBATCH --output=/path/to/logs/%A.%a.out
#SBATCH --error=/path/to/logs/%A.%a.err
#SBATCH --mem=20G           # memory for the Nextflow process itself (not compute jobs)
#SBATCH -p public
#SBATCH -q public

# ── Load required modules (adjust to your cluster's module system) ────────────
module load nextflow
module load openjdk

# ── Environment ───────────────────────────────────────────────────────────────
export SLURM_SKIP_EPILOG=1

# Directory where Apptainer caches pulled container images
export NXF_APPTAINER_CACHEDIR=/scratch/$USER/make_lastz_chains/apptainer

# Optional: pre-build a named SIF to avoid the auto-derived cache filename.
# Build once with:
#   apptainer build $NXF_APPTAINER_CACHEDIR/make_lastz_chains.sif \
#       docker://nilablueshirt/make_lastz_chains:latest-amd64
# Then uncomment:
# export NXF_CONTAINER_IMAGE=$NXF_APPTAINER_CACHEDIR/make_lastz_chains.sif

# Give Nextflow's JVM enough heap for large runs (thousands of jobs)
export NXF_OPTS="-Xms4g -Xmx16g"

# ── Paths — edit these ────────────────────────────────────────────────────────
species_list="/path/to/manifest.tsv"   # tab-separated manifest (see format above)
working_dir="/path/to/output"          # one subdirectory per pair will be created here
pipeline_dir="/path/to/make_lastz_chains"  # cloned pipeline repo

# ── Parse manifest line for this array task ───────────────────────────────────
pair=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$species_list")
target_name=$(echo "$pair" | cut -f1)
target_fa=$(echo "$pair"   | cut -f2)
query_name=$(echo "$pair"  | cut -f3)
query_fa=$(echo "$pair"    | cut -f4)

if [[ -z "$target_name" || -z "$target_fa" || -z "$query_name" || -z "$query_fa" ]]; then
    echo "ERROR: could not parse line ${SLURM_ARRAY_TASK_ID} of ${species_list}" >&2
    exit 1
fi

# ── Per-pair working directory ─────────────────────────────────────────────────
pair_dir="${working_dir}/${target_name}_${query_name}_chains"
mkdir -p "${pair_dir}/logs"

# ── Write params.json for this pair ───────────────────────────────────────────
# Scientific parameters go here; infrastructure stays in nextflow.config.
cat > "${pair_dir}/params.json" <<EOF
{
    "target_name":   "${target_name}",
    "query_name":    "${query_name}",
    "target_genome": "${target_fa}",
    "query_genome":  "${query_fa}",
    "outdir":        "${pair_dir}/results",

    "seq1_chunk": 175000000,
    "seq2_chunk": 50000000,
    "seq1_lap":   0,
    "seq2_lap":   10000,

    "lastz_y": 9400,
    "lastz_h": 2000,
    "lastz_l": 3000,
    "lastz_k": 2400,
    "lastz_q": null,

    "min_chain_score":      1000,
    "chain_linear_gap":     "loose",
    "bundle_psl_max_bases": 1000000,

    "skip_fill_chains":            false,
    "skip_fill_unmask":            false,
    "num_fill_jobs":               1000,
    "fill_insert_chain_min_score": 5000,
    "fill_gap_max_size_t":         20000,
    "fill_gap_max_size_q":         20000,
    "fill_gap_min_size_t":         30,
    "fill_gap_min_size_q":         30,
    "fill_lastz_k":                2000,
    "fill_lastz_l":                3000,

    "skip_clean_chain":       false,
    "clean_chain_parameters": "-LRfoldThreshold=2.5 -doPairs -LRfoldThresholdPairs=10 -maxPairDistance=10000 -maxSuspectScore=100000 -minBrokenChainScore=75000",

    "lastz_path":      "lastz",
    "axt_to_psl_path": "axtToPsl"
}
EOF

# cd into pair_dir so each run's .nextflow.log is saved there
cd "$pair_dir"

nextflow run "${pipeline_dir}/main.nf" \
    -params-file "${pair_dir}/params.json" \
    -profile     apptainer,slurm \
    -w           "${pair_dir}/work"
