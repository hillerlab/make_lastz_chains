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
    VALIDATE & PRINT PARAMETER SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Print help and exit
if (params.help) {
    log.info """
    ╔══════════════════════════════════════════════════════════════════════════╗
    ║                       make_lastz_chains  v${workflow.manifest.version}                       ║
    ╠══════════════════════════════════════════════════════════════════════════╣
    ║  Pipeline to create chain-formatted pairwise genome alignments.         ║
    ╚══════════════════════════════════════════════════════════════════════════╝

    Usage:
        nextflow run main.nf \\
            --target_name  hg38 \\
            --query_name   mm39 \\
            --target_genome /path/to/hg38.fa \\
            --query_genome  /path/to/mm39.fa \\
            --outdir        results/ \\
            -profile        conda   # or apptainer, slurm, test …

    Required parameters:
        --target_name     STRING  Target genome identifier (e.g. hg38)
        --query_name      STRING  Query genome identifier (e.g. mm39)
        --target_genome   PATH    Target genome file (FASTA or .2bit)
        --query_genome    PATH    Query genome file (FASTA or .2bit)

    Optional parameters (common):
        --outdir          PATH    Output directory [default: ./results]
        --seq1_chunk      INT     Target chunk size in bp [default: 175000000]
        --seq2_chunk      INT     Query chunk size in bp  [default: 50000000]
        --lastz_y         INT     LASTZ gap extension penalty [default: 9400]
        --lastz_h         INT     LASTZ seed hit count [default: 2000]
        --lastz_k         INT     LASTZ minimum anchor score [default: 2400]
        --lastz_l         INT     LASTZ step length [default: 3000]
        --min_chain_score INT     Minimum chain score [default: 1000]
        --chain_linear_gap STR    linearGap model: loose|medium [default: loose]
        --skip_fill_chains        Skip the fill-chains step
        --skip_clean_chain        Skip the chain-cleaning step
        --chaining_memory INT     GB per axtChain job [default: 50]
        --fill_memory     INT     GB per repeat-filler job [default: 16]
        --chain_clean_memory INT  GB for chainCleaner [default: 100]

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

// Validate required parameters
def validateParams() {
    def errors = []
    if (!params.target_name)   errors << "  --target_name is required"
    if (!params.query_name)    errors << "  --query_name is required"
    if (!params.target_genome) errors << "  --target_genome is required"
    if (!params.query_genome)  errors << "  --query_genome is required"
    if (params.chain_linear_gap !in ['loose', 'medium']) {
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    }
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

validateParams()

// Print pipeline summary
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

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { MAKE_LASTZ_CHAINS } from './workflows/make_lastz_chains'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    NAMED WORKFLOW FOR PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow {
    MAKE_LASTZ_CHAINS (
        params.target_name,
        params.query_name,
        params.target_genome,
        params.query_genome
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
