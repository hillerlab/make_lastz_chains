#!/usr/bin/env nextflow
/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    make_lastz_chains
    nf-core style entry point

    Pipeline to create chain-formatted pairwise genome alignments.
    Authors: Bogdan M. Kirilenko, Michael Hiller, Virag Sharma, Ekaterina Osipova
    GitHub:  https://github.com/hillerlab/make_lastz_chains
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

nextflow.enable.dsl = 2

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HELP
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

if (params.help) {
    log.info """
    ╔══════════════════════════════════════════════════════════════════════════╗
    ║                  make_lastz_chains  v${workflow.manifest.version}                            ║
    ╠══════════════════════════════════════════════════════════════════════════╣
    ║  Pipeline to create chain-formatted pairwise genome alignments.         ║
    ╚══════════════════════════════════════════════════════════════════════════╝

    Usage (full run):
        nextflow run main.nf \\
            --target_name   hg38 \\
            --query_name    mm39 \\
            --target_genome /path/to/hg38.fa \\
            --query_genome  /path/to/mm39.fa \\
            --outdir        results/ \\
            -profile        apptainer,slurm

    Checkpoint entry points (resume from a published intermediate):
        -entry FROM_FILL_CHAINS   Start from *.all.chain.gz  (skips LASTZ + chain building)
        -entry FROM_CLEAN_CHAINS  Start from *.filled.chain.gz (skips fill step)

        Required extra params for FROM_FILL_CHAINS:
            --merged_chain        PATH  Path to *.all.chain.gz
            --target_twobit       PATH  Path to target .2bit
            --query_twobit        PATH  Path to query .2bit
            --target_chrom_sizes  PATH  Path to target chrom.sizes
            --query_chrom_sizes   PATH  Path to query chrom.sizes

        Required extra params for FROM_CLEAN_CHAINS:
            --filled_chain        PATH  Path to *.filled.chain.gz
            --target_twobit       PATH  (same as above)
            --query_twobit        PATH
            --target_chrom_sizes  PATH
            --query_chrom_sizes   PATH

    Pass all parameters from a JSON file (replaces old --params_from_file):
        nextflow run main.nf -params-file my_params.json

    Required parameters (full run):
        --target_name     STRING  Target genome identifier (e.g. hg38)
        --query_name      STRING  Query genome identifier (e.g. mm39)
        --target_genome   PATH    Target genome file (FASTA or .2bit)
        --query_genome    PATH    Query genome file (FASTA or .2bit)

    Optional parameters (common):
        --outdir              PATH    Output directory [default: ./results]
        --seq1_chunk          INT     Target chunk size in bp [default: 175000000]
        --seq2_chunk          INT     Query chunk size in bp  [default: 50000000]
        --lastz_y             INT     LASTZ gap extension penalty [default: 9400]
        --lastz_h             INT     LASTZ seed hit count [default: 2000]
        --lastz_k             INT     LASTZ minimum anchor score [default: 2400]
        --lastz_l             INT     LASTZ step length [default: 3000]
        --min_chain_score     INT     Minimum chain score [default: 1000]
        --chain_linear_gap    STR     linearGap model: loose|medium [default: loose]
        --skip_fill_chains            Skip the fill-chains step
        --skip_clean_chain            Skip the chain-cleaning step

    Profiles:
        local       Run on local machine (default)
        slurm       Submit jobs to SLURM cluster
        conda       Use conda environments
        apptainer   Use Apptainer containers
        singularity Use Singularity containers
        docker      Use Docker containers
        test        Run with bundled test data

    Use --help to show this message.
    """.stripIndent()
    System.exit(0)
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT WORKFLOWS AND MODULES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { MAKE_LASTZ_CHAINS } from './workflows/make_lastz_chains'
include { FILL_CLEAN_CHAINS } from './subworkflows/local/fill_clean_chains/main'
include { CHAIN_CLEANER     } from './modules/local/chain_cleaner/main'
include { CHAIN_FILTER      } from './modules/local/chain_filter/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATION FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def validateFullRun() {
    def errors = []
    if (!params.target_name)   errors << "  --target_name is required"
    if (!params.query_name)    errors << "  --query_name is required"
    if (!params.target_genome) errors << "  --target_genome is required"
    if (!params.query_genome)  errors << "  --query_genome is required"
    if (params.chain_linear_gap !in ['loose', 'medium'])
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

def validateAliasBase() {
    // Shared required params for all entry alias workflows
    def errors = []
    if (!params.target_name)        errors << "  --target_name is required"
    if (!params.query_name)         errors << "  --query_name is required"
    if (!params.target_twobit)      errors << "  --target_twobit is required (path to target .2bit)"
    if (!params.query_twobit)       errors << "  --query_twobit is required (path to query .2bit)"
    if (!params.target_chrom_sizes) errors << "  --target_chrom_sizes is required"
    if (!params.query_chrom_sizes)  errors << "  --query_chrom_sizes is required"
    if (params.chain_linear_gap !in ['loose', 'medium'])
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    return errors
}

def validateFromFillChains() {
    def errors = validateAliasBase()
    if (!params.merged_chain) errors << "  --merged_chain is required (path to *.all.chain.gz)"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

def validateFromCleanChains() {
    def errors = validateAliasBase()
    if (!params.filled_chain) errors << "  --filled_chain is required (path to *.filled.chain.gz)"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ENTRY WORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// ── Default: full pipeline ─────────────────────────────────────────────────
workflow {
    validateFullRun()

    log.info """
    ╔══════════════════════════════════════════════════════════════╗
    ║             make_lastz_chains  v${workflow.manifest.version}                   ║
    ╚══════════════════════════════════════════════════════════════╝
      Target : ${params.target_name}  (${params.target_genome})
      Query  : ${params.query_name}   (${params.query_genome})
      Outdir : ${params.outdir}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    MAKE_LASTZ_CHAINS(
        params.target_name,
        params.query_name,
        params.target_genome,
        params.query_genome
    )
}

// ── Checkpoint: start from merged chain (skip LASTZ + chain building) ──────
// Input: results/chain_merge/*.all.chain.gz from a previous run
workflow FROM_FILL_CHAINS {
    validateFromFillChains()

    log.info """
    ╔══════════════════════════════════════════════════════════════╗
    ║   make_lastz_chains  v${workflow.manifest.version} — FROM_FILL_CHAINS          ║
    ╚══════════════════════════════════════════════════════════════╝
      Target : ${params.target_name}
      Query  : ${params.query_name}
      Input  : ${params.merged_chain}
      Outdir : ${params.outdir}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    FILL_CLEAN_CHAINS(
        file(params.merged_chain),
        file(params.target_twobit),
        file(params.query_twobit),
        file(params.target_chrom_sizes),
        file(params.query_chrom_sizes),
        params.target_name,
        params.query_name
    )
}

// ── Checkpoint: start from filled chain (skip LASTZ + chain build + fill) ──
// Input: results/fill_chains/*.filled.chain.gz from a previous run
workflow FROM_CLEAN_CHAINS {
    validateFromCleanChains()

    log.info """
    ╔══════════════════════════════════════════════════════════════╗
    ║   make_lastz_chains  v${workflow.manifest.version} — FROM_CLEAN_CHAINS         ║
    ╚══════════════════════════════════════════════════════════════╝
      Target : ${params.target_name}
      Query  : ${params.query_name}
      Input  : ${params.filled_chain}
      Outdir : ${params.outdir}
      Profile: ${workflow.profile}
    """.stripIndent()

    CHAIN_CLEANER(
        file(params.filled_chain),
        file(params.target_twobit),
        file(params.query_twobit),
        file(params.target_chrom_sizes),
        file(params.query_chrom_sizes),
        params.chain_linear_gap,
        params.clean_chain_parameters
    )

    CHAIN_FILTER(
        CHAIN_CLEANER.out.cleaned_chain,
        params.min_chain_score,
        params.target_name,
        params.query_name
    )
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION HANDLER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (workflow.success) {
        log.info "Pipeline completed successfully!"
        log.info "Final chain: ${params.outdir}/final/${params.target_name}.${params.query_name}.final.chain.gz"
        log.info "Run time   : ${workflow.duration}"
    } else {
        log.error "Pipeline FAILED — check logs in ${params.outdir}/pipeline_info/"
    }
}

workflow.onError {
    log.error "Pipeline error: ${workflow.errorMessage}"
}
