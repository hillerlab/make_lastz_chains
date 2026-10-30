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
    Authors: Alejandro Gonzales-Irribarren, Nil Mu, Bogdan M. Kirilenko, Michael Hiller
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
    > make_lastz_chains v${workflow.manifest.version}
    > Portable solution to generate genome alignment chains using lastz
    > The Hiller Lab at the Senckenberg Gesellschaft für Naturforschung

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
        -entry FROM_SEGMENTS      Start from hspZ *.segments  (skips GPU stage)

        Required extra params for FROM_FILL_CHAINS (--from fill_chains):
            --merged_chain           PATH  Path to *.all.chain.gz

        Required extra params for FROM_CLEAN_CHAINS (--from clean_chains):
            --filled_chain           PATH  Path to *.filled.chain.gz

        Required extra params for FROM_SEGMENTS (--from segments):
            --segments_path          PATH  Path to directory with *.segments


    Pass all parameters from a JSON file (replaces old --params_from_file):
        nextflow run main.nf -params-file my_params.json

    Required parameters (full run + fill/clean):
        --reference_name     STRING  Reference genome identifier (e.g. hg38)
        --query_name         STRING  Query genome identifier (e.g. mm39)
        --reference_genome   PATH    Reference genome file (FASTA or .2bit)
        --query_genome       PATH    Query genome file (FASTA or .2bit)

    Many queries, one reference (--aligner hspz only, full run only):
        --array              PATH    File with one query genome path per line; replaces
                                     --query_genome/--query_name. All queries share ONE
                                     hspZ --query-list GPU batch, then each runs its own
                                     chain/fill/clean steps into <outdir>/<query>/.
                                     Queries are named after their files.

    Optional parameters (common):
        --outdir              PATH    Output directory [default: ./results]
        --aligner             STR     Alignment backend: lastz|kegalign|hspz [default: lastz]
                                      kegalign is GPU-only — add -profile gpu
        --kegalign_executor   STR     KegAlign CPU stage: batched|distributed [default: batched]
                                      distributed = one Nextflow task per KegAlign partition
        --kegalign_mps_workers INT    Concurrent KegAlign instances on the one allocated
                                      GPU via NVIDIA MPS, 1-4 [default: 1 = no MPS]
                                      > 1 needs --kegalign_executor batched and 12-16 GiB
                                      VRAM per worker
        --seq1_chunk          INT     reference chunk size in bp [default: 175000000]
        --seq2_chunk          INT     Query chunk size in bp  [default: 50000000]
        --lastz_y             INT     LASTZ Y = --ydrop, y-drop threshold [default: 9400]
        --lastz_h             INT     LASTZ H = --inner, HSP interpolation threshold [default: 2000]
        --lastz_k             INT     LASTZ K = --hspthresh, ungapped HSP threshold [default: 2400]
        --lastz_l             INT     LASTZ L = --gappedthresh, gapped alignment threshold [default: 3000]
        --min_chain_score     INT     Minimum chain score [default: 1000]
        --chain_linear_gap    STR     linearGap model: loose|medium [default: loose]
        --skip_fill_chains            Skip the fill-chains step
        --skip_clean_chain            Skip the chain-cleaning step
        --annotation          PATH    BED/GTF/GFF annotation for chain coverage QC (optional, skipped when unset)

    Profiles:
        local       Run on local machine (default)
        slurm       Submit jobs to SLURM cluster
        conda       Use conda environments
        apptainer   Use Apptainer containers
        singularity Use Singularity containers
        docker      Use Docker containers
        gpu         Expose host GPUs to containers (required by --aligner kegalign)
        zluda       Local dev on an AMD GPU via ZLUDA: runs the KegAlign stages
                    natively (see assets/tests/ci/zluda_setup.sh), rest in containers
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
include { CHAINC } from './modules/local/chainc/main'
include { CHAINTOOLS_FILTER as CHAINTOOLS_FILTER_CLEANED_CHAINS } from './modules/local/chaintools/filter/main'
include { PREPARE_GENOMES as PREPARE_REFERENCE_GENOME } from './subworkflows/local/prepare_genomes/main'
include { PREPARE_GENOMES as PREPARE_QUERY_GENOME } from './subworkflows/local/prepare_genomes/main'
include { SEGMENTS_TO_PSL } from './subworkflows/local/segments_to_psl/main'
include { CHAIN_BUILD } from './subworkflows/local/chain_build/main'
include { CHAINTOOLS_ANTIREPEAT } from './modules/local/chaintools/antirepeat/main'
include { CHAINTOOLS_MERGE } from './modules/local/chaintools/merge/main'
include { CHAINTOOLS_STATS } from './modules/local/chaintools/stats/main'
include { CHAINTOOLS_COVERAGE } from './modules/local/chaintools/coverage/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATION FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def validateAligner() {
    // Returns error strings; the KegAlign backend is GPU-only by design — a
    // silent fallback to CPU LASTZ would hide a misconfigured runtime.
    def errors = []
    if (!(['lastz', 'kegalign', 'hspz'].contains(params.aligner))) {
        errors << "  --aligner must be 'lastz' or 'kegalign' or 'hspz' (got '${params.aligner}')"
    }
    else if (params.aligner == 'kegalign' && !(['gpu', 'zluda'].intersect(workflow.profile.tokenize(',')))) {
        errors << "  --aligner kegalign requires the gpu or zluda profile (e.g. -profile docker,gpu/zluda or apptainer,gpu/zluda)."
        errors << "  Clusters that grant GPU access through their own config should still include -profile gpu."
    } 
    else if (params.aligner == 'hspz' && !(['gpu', 'zluda'].intersect(workflow.profile.tokenize(',')))) {
        errors << "  --aligner hspz requires the gpu or zluda profile (e.g. -profile docker,gpu or docker,zluda)."
        errors << "  Clusters that grant GPU access through their own config should still include -profile gpu or zluda."
    }

    if (!(['batched', 'distributed'].contains(params.kegalign_executor))) {
        errors << "  --kegalign_executor must be 'batched' or 'distributed' (got '${params.kegalign_executor}')"
    }

    // MPS shares one GPU between concurrent KegAlign instances. The 4 ceiling is
    // upstream's VRAM guidance, not a hard limit — raise it once benchmarked.
    def mps = params.kegalign_mps_workers.toString()
    if (!mps.isInteger() || mps.toInteger() < 1 || mps.toInteger() > 4) {
        errors << "  --kegalign_mps_workers must be an integer 1..4 (got '${params.kegalign_mps_workers}')"
    }
    else if (mps.toInteger() > 1) {
        if (params.aligner != 'kegalign') {
            errors << "  --kegalign_mps_workers > 1 only applies to --aligner kegalign"
        }
        if (params.kegalign_executor != 'batched') {
            errors << "  --kegalign_mps_workers > 1 requires --kegalign_executor batched:"
            errors << "  the distributed CPU stage expands a single keg, while MPS emits one per chunk pair."
        }
    }

    return errors
}

// --array: one query genome path per line ('#' and blank lines skipped; relative
// paths resolve against the list's directory, as hspZ --query-list does). Each
// query is named after its file minus .gz and .fa/.fasta/.fna/.2bit; the name
// keys every per-query channel, file and output directory.
def arrayQueries() {
    def list = file(params.array.toString())
    list.readLines()*.trim().findAll { it && !it.startsWith('#') }.collect { line ->
        def genome = list.parent.resolve(line)
        [ genome.name.replaceFirst(/\.gz$/, '').replaceFirst(/\.(fa|fasta|fna|2bit)$/, ''), genome.toString() ]
    }
}

def validateArray() {
    def errors = []
    if (params.query_genome || params.query_name)
        errors << "  --array replaces --query_genome/--query_name (queries are named after their files)"
    if (params.aligner != 'hspz')
        errors << "  --array runs every query through one hspZ --query-list batch: it needs --aligner hspz"
    if (params.annotation && params.annotation_side == 'query')
        errors << "  --array: --annotation_side query cannot describe several query species"
    // A bare --array (or --array '') arrives as Boolean true, not a path.
    if (!(params.array instanceof CharSequence) || !file(params.array.toString()).isFile()) {
        errors << "  --array must be a file with one query genome path per line (got '${params.array}')"
        return errors
    }
    def names = []
    arrayQueries().each { name, genome ->
        if (!file(genome).exists())        errors << "  --array: query genome not found: ${genome}"
        if (!(name ==~ /[A-Za-z0-9_.-]+/)) errors << "  --array: '${name}' is not a file-name-safe query name"
        if (name in names || name == params.reference_name.toString())
            errors << "  --array: query name '${name}' is used twice (or is the reference's name)"
        names << name
    }
    if (!names) errors << "  --array lists no query genome"
    return errors
}

def validateFullRun() {
    def errors = validateAligner()
    if (!params.reference_name)   errors << "  --reference_name is required"
    if (!params.reference_genome) errors << "  --reference_genome is required"
    if (params.array) {
        errors.addAll(validateArray())
    } else {
        if (!params.query_name)   errors << "  --query_name is required"
        if (!params.query_genome) errors << "  --query_genome is required"
    }
    if (!(['loose', 'medium'].contains(params.chain_linear_gap)))
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    if (params.annotation && !(['reference', 'query'].contains(params.annotation_side)))
        errors << "  --annotation_side must be 'reference' or 'query' (got '${params.annotation_side}')"
    if (params.annotation && !(['cds', 'exon', 'intron', 'utr'].contains(params.annotation_feature)))
        errors << "  --annotation_feature must be 'cds', 'exon', 'intron' or 'utr' (got '${params.annotation_feature}')"
    if (errors) {
        log.error "Parameter validation failed:\n${errors.join('\n')}"
        System.exit(1)
    }
}

def validateAliasBase() {
    // Shared required params for all entry alias workflows
    def errors = []
    if (params.array)                  errors << "  --array runs the full pipeline only (drop --from)"
    if (!params.reference_name)        errors << "  --reference_name is required"
    if (!params.query_name)         errors << "  --query_name is required"
    if (!params.reference_genome)      errors << "  --reference_twobit is required (path to reference .2bit)"
    if (!params.query_genome)       errors << "  --query_twobit is required (path to query .2bit)"
    if (!(['loose', 'medium'].contains(params.chain_linear_gap)))
        errors << "  --chain_linear_gap must be 'loose' or 'medium'"
    if (params.annotation && !(['reference', 'query'].contains(params.annotation_side)))
        errors << "  --annotation_side must be 'reference' or 'query' (got '${params.annotation_side}')"
    if (params.annotation && !(['cds', 'exon', 'intron', 'utr'].contains(params.annotation_feature)))
        errors << "  --annotation_feature must be 'cds', 'exon', 'intron' or 'utr' (got '${params.annotation_feature}')"
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

def validateFromSegments() {
    def errors = validateAliasBase()
    if (!params.segments_path) errors << "  --segments_path is required (path to dir with *.segments)"
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
    } else if (params.from == "segments") {
        // ── Checkpoint: start from pre-generated hspZ .segments ──────────────
        log.info "Resuming from ${params.from} checkpoint — starting at LASTZ_SEGMENTED (CPU-only)"
        FROM_SEGMENTS()
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

    // [ name, genome ] per query: the --query_name/--query_genome pair, or every --array line
    def queries = params.array ? arrayQueries() : [ [ params.query_name, params.query_genome ] ]

    log.info """
    > make_lastz_chains v${workflow.manifest.version}
    > Portable solution to generate genome alignment chains using lastz
    > The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
  
    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

      Reference : ${params.reference_name}  (${params.reference_genome})
      Query  : ${params.array ? "${queries.size()} queries from ${params.array} (one hspZ --query-list batch)" : "${params.query_name}   (${params.query_genome})"}
      Aligner: ${params.aligner}${params.aligner == 'kegalign' ? " (${params.kegalign_executor}${(params.kegalign_mps_workers as int) > 1 ? ", MPS x${params.kegalign_mps_workers}" : ''})" : ''}
      Outdir : ${params.outdir}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    CHAINS(
        params.reference_name,
        queries*.getAt(0),
        params.reference_genome,
        queries*.getAt(1)
    )

    // — stats — keep in sync across all entry workflows
    CHAINTOOLS_STATS(CHAINS.out.final_chain)

    // — coverage — same final chain, runs only when an annotation is provided.
    // .first(): a value channel, so it serves every query's chain, not just one.
    if (params.annotation) {
        CHAINTOOLS_COVERAGE(
            CHAINS.out.final_chain,
            Channel.fromPath(params.annotation, checkIfExists: true).first(),
            params.annotation_side,
            params.annotation_feature
        )
    }
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

    def pair_meta = [ id: "${params.reference_name}.${params.query_name}".toString(), query: params.query_name.toString() ]

    // ── 2. Collect all bundled chains from axtChain ───────────────────────────────────
    Channel.fromPath(params.axtchain_path, type: 'dir', checkIfExists: true, maxDepth: 1)
        .map { chain -> chain.listFiles().findAll { it.name.endsWith('.chain') } }
        .flatten()
        .map { chain -> [ pair_meta, chain ] }
        .set { ch_axtchain_chains }

    // ── 3. Run anti repeat on each chain ─────────────────────────────────────────
    CHAINTOOLS_ANTIREPEAT (
      ch_axtchain_chains,
      reference_twobit,
      query_twobit,
    )

    // ── 4. Merge all chain files into one ────────────────────────────────────────
    CHAINTOOLS_MERGE (
        CHAINTOOLS_ANTIREPEAT.out.chain.groupTuple()
    )

    FILL_CLEAN_CHAINS(
        CHAINTOOLS_MERGE.out.chain_gz,
        reference_twobit,
        reference_chrom_sizes,
        query_prepared
    )

    // — stats — keep in sync across all entry workflows
    CHAINTOOLS_STATS(FILL_CLEAN_CHAINS.out.final_chain)

    // — coverage — same final chain, runs only when an annotation is provided
    if (params.annotation) {
        CHAINTOOLS_COVERAGE(
            FILL_CLEAN_CHAINS.out.final_chain,
            Channel.fromPath(params.annotation, checkIfExists: true),
            params.annotation_side,
            params.annotation_feature
        )
    }
}

// ── Checkpoint: start from pre-generated hspZ .segments (CPU-only) ──────
// Input: results/02_hspz/segments/*.segments from a previous --aligner hspz run
workflow FROM_SEGMENTS {
    validateFromSegments()

    log.info """
    make_lastz_chains v${workflow.manifest.version} — FROM_SEGMENTS

    Authors: ${workflow.manifest.author}
    Github:  ${workflow.manifest.homePage}

      Reference : ${params.reference_name}
      Query  : ${params.query_name}
      Input  : ${params.segments_path}
      Outdir : ${params.outdir}
      Fill   : ${params.skip_fill_chains ? 'SKIPPED' : 'enabled'}
      Clean  : ${params.skip_clean_chain ? 'SKIPPED' : 'enabled'}
      Profile: ${workflow.profile}
    """.stripIndent()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    // extract=true because LASTZ_SEGMENTED needs the per-chrom FASTA dir for
    // v1 .2bit genomes, same as the hspZ backend it resumes.
    PREPARE_REFERENCE_GENOME (
        params.reference_name,
        params.reference_genome,
        true
    )
    PREPARE_QUERY_GENOME (
        params.query_name,
        params.query_genome,
        true
    )

    // INFO: (reference_name, reference_twobit, reference_chrom_sizes)
    reference_prepared    = PREPARE_REFERENCE_GENOME.out.prepared
    reference_twobit      = reference_prepared.map { _n, tb, _cs -> tb }.first()
    reference_chrom_sizes = reference_prepared.map { _n, _tb, cs -> cs }.first()
    reference_chroms_dir  = PREPARE_REFERENCE_GENOME.out.chroms_dir.map { _n, d -> d }.first()

    query_prepared    = PREPARE_QUERY_GENOME.out.prepared

    // ── 2. Collect segments ────────────────────────────────────────────────
    Channel.fromPath(params.segments_path, type: 'dir', checkIfExists: true)
        .flatMap { dir ->
            def files = []
            file(dir).eachFileRecurse { f ->
                if (f.name.endsWith('.segments')) files << f
            }
            // An --array run keeps one directory per query under segments/;
            // this entry resumes ONE query, so point it at that query's own dir.
            if (files*.parent.unique().size() > 1)
                error "--segments_path holds segments of several queries (an --array run?): " +
                      "point it at one query's directory, e.g. <outdir>/02_hspz/segments/segments/<query>"
            files
        }
        .map { segment ->
            tuple(
                [ id: segment.baseName, reference: params.reference_name, query: params.query_name.toString() ],
                segment
            )
        }
        .set { ch_segments }

    // ── 3. Segments → PSL ──────────────────────────────────────────────────
    SEGMENTS_TO_PSL (
        ch_segments,
        reference_twobit,
        reference_chroms_dir,
        reference_chrom_sizes,
        query_prepared.join( PREPARE_QUERY_GENOME.out.chroms_dir ),
        params.lastz_h,
        params.lastz_l,
        params.lastz_y
    )

    // ── 4. Chain build ─────────────────────────────────────────────────────
    CHAIN_BUILD (
        SEGMENTS_TO_PSL.out.psl_gz,
        reference_twobit,
        reference_chrom_sizes,
        query_prepared
    )

    // ── 5. Fill / clean chains ─────────────────────────────────────────────
    FILL_CLEAN_CHAINS (
        CHAIN_BUILD.out.merged_chain,
        reference_twobit,
        reference_chrom_sizes,
        query_prepared
    )

    // — stats — keep in sync across all entry workflows
    CHAINTOOLS_STATS(FILL_CLEAN_CHAINS.out.final_chain)

    // — coverage — same final chain, runs only when an annotation is provided
    if (params.annotation) {
        CHAINTOOLS_COVERAGE(
            FILL_CLEAN_CHAINS.out.final_chain,
            Channel.fromPath(params.annotation, checkIfExists: true),
            params.annotation_side,
            params.annotation_feature
        )
    }
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

    Channel.fromPath(params.merged_chain_path)
        .map { chain -> [ [ id: "${params.reference_name}.${params.query_name}".toString(), query: params.query_name.toString() ], chain ] }
        .set { ch_merged_chain }

    FILL_CLEAN_CHAINS(
        ch_merged_chain,
        reference_twobit,
        reference_chrom_sizes,
        query_prepared
    )

    // — stats — keep in sync across all entry workflows
    CHAINTOOLS_STATS(FILL_CLEAN_CHAINS.out.final_chain)

    // — coverage — same final chain, runs only when an annotation is provided
    if (params.annotation) {
        CHAINTOOLS_COVERAGE(
            FILL_CLEAN_CHAINS.out.final_chain,
            Channel.fromPath(params.annotation, checkIfExists: true),
            params.annotation_side,
            params.annotation_feature
        )
    }
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
        .map { chain -> [ [ id: "${params.reference_name}.${params.query_name}".toString(), query: params.query_name.toString() ], chain, [] ] }
        .set { ch_filled_chain }

    CHAINC(
        ch_filled_chain,
        reference_twobit,
        query_twobit,
        reference_chrom_sizes,
        query_chrom_sizes,
        params.chain_linear_gap
    )

    CHAINTOOLS_FILTER_CLEANED_CHAINS(
        CHAINC.out.chain,
        params.min_chain_score,
    )

    // — stats — keep in sync across all entry workflows
    CHAINTOOLS_STATS(CHAINTOOLS_FILTER_CLEANED_CHAINS.out.chain_gz)

    // — coverage — same final chain, runs only when an annotation is provided
    if (params.annotation) {
        CHAINTOOLS_COVERAGE(
            CHAINTOOLS_FILTER_CLEANED_CHAINS.out.chain_gz,
            Channel.fromPath(params.annotation, checkIfExists: true),
            params.annotation_side,
            params.annotation_feature
        )
    }
}



/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION HANDLER
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (workflow.success) {
        log.info "Pipeline completed successfully!"
        // --array publishes each query under <outdir>/<query>/
        def queries = params.array ? arrayQueries()*.getAt(0) : [ params.query_name ]
        queries.each { query ->
            def final_chain = file("${params.outdir}/${params.array ? query + '/' : ''}07_final/${params.reference_name}.${query}.allfilled.chain.gz")
            if (final_chain.exists()) {
                log.info "Final chain: ${final_chain}"
            } else {
                log.warn "Pipeline reported success but no final chain was produced for ${query} (${final_chain}) — check that all steps ran"
            }
        }
        log.info "Run time   : ${workflow.duration}"
    } else {
        log.error "Pipeline FAILED — ${workflow.errorMessage}"
    }
}

workflow.onError {
    log.error "Pipeline error: ${workflow.errorMessage}"
}
