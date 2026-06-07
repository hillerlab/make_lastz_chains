#!/usr/bin/env nextflow

/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    make_lastz_chains
    nf-core style entry point

    Pipeline to create chain-formatted pairwise genome alignments.
    Authors: Bogdan M. Kirilenko, Alejandro Gonzales-Irribarren, Nil Mu, Virag Sharma, Ekaterina Osipova, Michael Hiller
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
    make_lastz_chains v${workflow.manifest.version}
    Pipeline to create chain-formatted pairwise genome alignments.

    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

    Usage (full run):
        nextflow run main.nf \\
            --reference_name  hg38 \\
            --query_name  mm39 \\
            --reference_genome /path/to/hg38.fa \\
            --query_genome  /path/to/mm39.fa \\
            --outdir        results/ \\
            -profile        apptainer,slurm

    Checkpoint entry points (resume from a published intermediate):
        -entry FROM_FILL_CHAINS   Start from *.all.chain.gz  (skips LASTZ + chain building)
        -entry FROM_CLEAN_CHAINS  Start from *.filled.chain.gz (skips fill step)

        Required extra params for FROM_FILL_CHAINS (--from fill_chains):
            --merged_chain           PATH  Path to *.all.chain.gz

        Required extra params for FROM_CLEAN_CHAINS (--from clean_chains):
            --filled_chain           PATH  Path to *.filled.chain.gz


    Pass all parameters from a JSON file (replaces old --params_from_file):
        nextflow run main.nf -params-file my_params.json

    Required parameters (full run + fill/clean):
        --reference_name     STRING  Reference genome identifier (e.g. hg38)
        --query_name         STRING  Query genome identifier (e.g. mm39)
        --reference_genome   PATH    Reference genome file (FASTA or .2bit)
        --query_genome       PATH    Query genome file (FASTA or .2bit)

    Optional parameters (common):
        --outdir              PATH    Output directory [default: ./results]
        --seq1_chunk          INT     reference chunk size in bp [default: 175000000]
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

include { MAKE_LASTZ_CHAINS as CHAINS } from './workflows/make_lastz_chains'
include { FILL_CLEAN_CHAINS } from './subworkflows/local/fill_clean_chains/main'
include { CHAIN_CLEANER     } from './modules/local/chain_cleaner/main'
include { CHAINTOOLS_FILTER as CHAINTOOLS_FILTER_CLEANED_CHAINS } from './modules/local/chaintools/filter/main'
include { PREPARE_GENOMES as PREPARE_REFERENCE_GENOME } from './subworkflows/local/prepare_genomes/main'
include { PREPARE_GENOMES as PREPARE_QUERY_GENOME } from './subworkflows/local/prepare_genomes/main'
include { CHAINTOOLS_ANTIREPEAT } from './modules/local/chaintools/antirepeat/main'
include { CHAINTOOLS_MERGE } from './modules/local/chaintools/merge/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATION FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def validateFullRun() {
    def errors = []
    if (!params.reference_name)   errors << "  --reference_name is required"
    if (!params.query_name)    errors << "  --query_name is required"
    if (!params.reference_genome) errors << "  --reference_genome is required"
    if (!params.query_genome)  errors << "  --query_genome is required"
    if (!(['loose', 'medium'].contains(params.chain_linear_gap)))
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

def validateAliasBase() {
    // Shared required params for all entry alias workflows
    def errors = []
    if (!params.reference_name)        errors << "  --reference_name is required"
    if (!params.query_name)         errors << "  --query_name is required"
    if (!params.reference_genome)      errors << "  --reference_twobit is required (path to reference .2bit)"
    if (!params.query_genome)       errors << "  --query_twobit is required (path to query .2bit)"
    if (!(['loose', 'medium'].contains(params.chain_linear_gap)))
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    return errors
}

def validateFromChainAntirepeat() {
    def errors = validateAliasBase()
    if (!params.axtchain_path) errors << "  --axtchain_path is required (path to *.chain)"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

def validateFromFillChains() {
    def errors = validateAliasBase()
    if (!params.merged_chain_path) errors << "  --merged_chain is required (path to *.all.chain.gz)"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

def validateFromCleanChains() {
    def errors = validateAliasBase()
    if (!params.filled_chain_path) errors << "  --filled_chain is required (path to *.filled.chain.gz)"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow MAKE_LASTZ_CHAINS {
    if (params.from == "fill_chains") {
        // ── Checkpoint: start from merged chain (skip LASTZ + chain building) ──────
        log.info "Resuming from ${params.from} checkpoint — skipping LASTZ + chain building"
        FROM_FILL_CHAINS()
    } else if (params.from == "clean_chains") {
        // ── Checkpoint: start from filled chain (skip LASTZ + chain build + fill) ──
        log.info "Resuming from ${params.from} checkpoint — skipping LASTZ + fill step"
        FROM_CLEAN_CHAINS()
    } else if (params.from == "chain_antirepeat") {
        // ── Checkpoint: start from axtChain bundle outputs (skip LASTZ) ──────
        log.info "Resuming from ${params.from} checkpoint — skipping LASTZ"
        FROM_CHAIN_ANTIREPEAT()
    } else {
        // ── Default: full pipeline ─────────────────────────────────────────────────
        log.info "Starting full pipeline — skipping checkpoints"
        FULL_RUN()
    }
}

workflow {
    MAKE_LASTZ_CHAINS()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ENTRY WORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// ── Default: full pipeline ─────────────────────────────────────────────────
workflow FULL_RUN {
    validateFullRun()

    log.info """
    make_lastz_chains v${workflow.manifest.version}
  
    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

      Reference : ${params.reference_name}  (${params.reference_genome})
      Query  : ${params.query_name}   (${params.query_genome})
      Outdir : ${params.outdir}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    CHAINS(
        params.reference_name,
        params.query_name,
        params.reference_genome,
        params.query_genome
    )
}

// ── Checkpoint: start from axtChain bundle outputs (skip LASTZ) ──────
// Input: results/04_axtchain/*.chain from a previous run
workflow FROM_CHAIN_ANTIREPEAT {
    validateFromChainAntirepeat()

    log.info """
    make_lastz_chains v${workflow.manifest.version} — FROM_CHAIN_ANTIREPEAT

    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

      Reference : ${params.reference_name}
      Query  : ${params.query_name}
      Input  : ${params.merged_chain_path}
      Outdir : ${params.outdir}
      Antirepeat : ${params.skip_antirepeat ? 'SKIPPED' : 'enabled'}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    PREPARE_REFERENCE_GENOME (
        params.reference_name,
        params.reference_genome,
        false
    )
    PREPARE_QUERY_GENOME (
        params.query_name,
        params.query_genome,
        false
    )

    // INFO: (reference_name, reference_twobit, reference_chrom_sizes)
    reference_prepared    = PREPARE_REFERENCE_GENOME.out.prepared
    reference_twobit      = reference_prepared.map { _n, tb, _cs -> tb }.first()
    reference_chrom_sizes = reference_prepared.map { _n, _tb, cs -> cs }.first()

    query_prepared    = PREPARE_QUERY_GENOME.out.prepared
    query_twobit      = query_prepared.map  { _n, tb, _cs -> tb }.first()
    query_chrom_sizes = query_prepared.map { _n, _tb, cs -> cs }.first()

    // ── 2. Collect all bundled chains from axtChain ───────────────────────────────────
    Channel.fromPath(params.axtchain_path, type: 'dir', checkIfExists: true, maxDepth: 1)
        .map { chain -> chain.listFiles().findAll { it.name.endsWith('.chain') } }
        .flatten()
        // .map { chain -> [ [ id: chain.baseName ], chain ] }
        .set { ch_axtchain_chains }

    // ── 3. Run anti repeat on each chain ─────────────────────────────────────────
    CHAINTOOLS_ANTIREPEAT (
      ch_axtchain_chains,
      reference_twobit,
      query_twobit,
    )

    // ── 4. Merge all chain files into one ────────────────────────────────────────
    CHAINTOOLS_MERGE (
        CHAINTOOLS_ANTIREPEAT.out.chain
          .collect()
          .map { chains -> [ [ id: params.reference_name + '.' + params.query_name ], chains ] }
    )

    FILL_CLEAN_CHAINS(
        CHAINTOOLS_MERGE.out.chain_gz,
        reference_twobit,
        query_twobit,
        reference_chrom_sizes,
        query_chrom_sizes,
        params.reference_name,
        params.query_name
    )
}

// ── Checkpoint: start from merged chain (skip LASTZ + chain building) ──────
// Input: results/chain_merge/*.all.chain.gz from a previous run
workflow FROM_FILL_CHAINS {
    validateFromFillChains()

    log.info """
    make_lastz_chains v${workflow.manifest.version} — FROM_FILL_CHAINS

    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

      Reference : ${params.reference_name}
      Query  : ${params.query_name}
      Input  : ${params.merged_chain_path}
      Outdir : ${params.outdir}
      Antirepeat : ${params.skip_antirepeat ? 'SKIPPED' : 'enabled'}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    PREPARE_REFERENCE_GENOME (
        params.reference_name,
        params.reference_genome,
        false
    )
    PREPARE_QUERY_GENOME (
        params.query_name,
        params.query_genome,
        false
    )

    // INFO: (reference_name, reference_twobit, reference_chrom_sizes)
    reference_prepared    = PREPARE_REFERENCE_GENOME.out.prepared
    reference_twobit      = reference_prepared.map { _n, tb, _cs -> tb }.first()
    reference_chrom_sizes = reference_prepared.map { _n, _tb, cs -> cs }.first()

    query_prepared    = PREPARE_QUERY_GENOME.out.prepared
    query_twobit      = query_prepared.map  { _n, tb, _cs -> tb }.first()
    query_chrom_sizes = query_prepared.map { _n, _tb, cs -> cs }.first()

    Channel.fromPath(params.merged_chain_path)
        .map { chain -> [ [ id: params.reference_name + '.' + params.query_name ], chain ] }
        .set { ch_merged_chain }

    FILL_CLEAN_CHAINS(
        ch_merged_chain,
        reference_twobit,
        query_twobit,
        reference_chrom_sizes,
        query_chrom_sizes,
        params.reference_name,
        params.query_name
    )
}

// ── Checkpoint: start from filled chain (skip LASTZ + chain build + fill) ──
// Input: results/fill_chains/*.filled.chain.gz from a previous run
workflow FROM_CLEAN_CHAINS {
    validateFromCleanChains()

    log.info """
    make_lastz_chains v${workflow.manifest.version} — FROM_CLEAN_CHAINS

    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

      Reference : ${params.reference_name}
      Query  : ${params.query_name}
      Input  : ${params.filled_chain_path}
      Outdir : ${params.outdir}
      Profile: ${workflow.profile}
    """.stripIndent()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    PREPARE_REFERENCE_GENOME (
        params.reference_name,
        params.reference_genome,
        false
    )
    PREPARE_QUERY_GENOME (
        params.query_name,
        params.query_genome,
        false
    )

    // INFO: (reference_name, reference_twobit, reference_chrom_sizes)
    reference_prepared = PREPARE_REFERENCE_GENOME.out.prepared
    reference_twobit      = reference_prepared.map { _n, tb, _cs -> tb }.first()
    reference_chrom_sizes = reference_prepared.map { _n, _tb, cs -> cs }.first()

    query_prepared  = PREPARE_QUERY_GENOME.out.prepared
    query_twobit      = query_prepared.map  { _n, tb, _cs -> tb }.first()
    query_chrom_sizes = query_prepared.map { _n, _tb, cs -> cs }.first()

    Channel.fromPath(params.filled_chain_path)
        .map { chain -> [ [ id: params.reference_name + '.' + params.query_name ], chain ] }
        .set { ch_filled_chain }

    CHAIN_CLEANER(
        ch_filled_chain,
        reference_twobit,
        query_twobit,
        reference_chrom_sizes,
        query_chrom_sizes,
        params.chain_linear_gap,
        params.clean_chain_parameters
    )

    CHAINTOOLS_FILTER_CLEANED_CHAINS(
        CHAIN_CLEANER.out.cleaned_chain,
        params.min_chain_score,
    )
}



/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION HANDLER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (workflow.success) {
        def final_chain = file("${params.outdir}/07_final/${params.reference_name}.${params.query_name}.allfilled.chain.gz")
        log.info "Pipeline completed successfully!"
        if (final_chain.exists()) {
            log.info "Final chain: ${final_chain}"
        } else {
            log.warn "Pipeline reported success but final chain file was not produced — check that all steps ran"
        }
        log.info "Run time   : ${workflow.duration}"
    } else {
        log.error "Pipeline FAILED — ${workflow.errorMessage}"
    }
}

workflow.onError {
    log.error "Pipeline error: ${workflow.errorMessage}"
}
