/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    make_lastz_chains — main pipeline workflow (nf-core style)

    Steps:
    0. Validate required parameters
    1. Prepare reference and query genomes (FASTA→2bit if needed, chrom.sizes)
    2. Alignment, either backend (--aligner):
         lastz    — partition → LASTZ N×K → PSL files
         kegalign — GPU seeding → batched CPU LASTZ → AXT+ → PSL
    3. Chain building (sort → bundle → axtChain → merge)
    4. Fill chains (optional)
    5. Clean chains (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PREPARE_GENOMES as PREPARE_REFERENCE_GENOME } from '../subworkflows/local/prepare_genomes/main'
include { PREPARE_GENOMES as PREPARE_QUERY_GENOME } from '../subworkflows/local/prepare_genomes/main'
include { LASTZ_ALIGNMENT    } from '../subworkflows/local/lastz_alignment/main'
include { KEGALIGN_ALIGNMENT } from '../subworkflows/local/kegalign_alignment/main'
include { HSPZ_ALIGNMENT     } from '../subworkflows/local/hspz_alignment/main'
include { CHAIN_BUILD        } from '../subworkflows/local/chain_build/main'
include { FILL_CLEAN_CHAINS  } from '../subworkflows/local/fill_clean_chains/main'

workflow MAKE_LASTZ_CHAINS {
    take:
    reference_name     // val
    query_name      // val, or a list of names (--array)
    reference_genome   // val: path string
    query_genome    // val: path string, or a list matching query_name (--array)

    main:
    ch_versions = Channel.empty()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    // Per-chromosome FASTA extraction feeds LASTZ_ALIGNMENT (per-partition
    // tasks) and the hspZ CPU extension stage (LASTZ_SEGMENTED) — both read
    // v1 .2bit through those FASTAs. KegAlign gets one whole-genome FASTA
    // from TWO_BIT_TO_FA instead, so skip it for that backend.
    def extract_chroms = params.aligner in ['lastz', 'hspz']

    PREPARE_REFERENCE_GENOME (
        reference_name,
        reference_genome,
        extract_chroms
    )
    PREPARE_QUERY_GENOME (
        query_name,
        query_genome,
        extract_chroms
    )

    ch_versions = ch_versions.mix(
        PREPARE_REFERENCE_GENOME.out.versions,
        PREPARE_QUERY_GENOME.out.versions
    )

    // INFO: (reference_name, reference_twobit, reference_chrom_sizes)
    reference_prepared = PREPARE_REFERENCE_GENOME.out.prepared
    query_prepared  = PREPARE_QUERY_GENOME.out.prepared

    // INFO: (reference_name, dir/) — populated for v1 .2bit, empty for v0
    reference_chroms_dir = PREPARE_REFERENCE_GENOME.out.chroms_dir
    query_chroms_dir  = PREPARE_QUERY_GENOME.out.chroms_dir

    // The genomes chaining, fill and clean read: the prepared ones, unless the
    // lastz backend's --window_masking_recovery or the hspz backend's
    // --dense_windows filter replaced them with masked ones.
    ch_chain_reference = reference_prepared.map { _n, tb, _cs -> tb }.first()
    ch_chain_query     = query_prepared

    // ── 2. Alignment (backend selected by --aligner) ────────────────────────
    switch (params.aligner) {
        case 'hspz':
            HSPZ_ALIGNMENT (
                reference_prepared,
                query_prepared,
                reference_chroms_dir,
                query_chroms_dir
            )
            // already split by reference chromosome: no PSLTOOLS_SPLIT pass
            ch_alignment_psl = Channel.empty()
            ch_psl_by_chrom  = HSPZ_ALIGNMENT.out.psl_by_chrom
            ch_versions      = ch_versions.mix(HSPZ_ALIGNMENT.out.versions)
            // --dense_windows filter: the genomes with the arrays soft-masked
            ch_chain_reference = HSPZ_ALIGNMENT.out.chain_reference_twobit
            ch_chain_query     = HSPZ_ALIGNMENT.out.chain_query_prepared
            break

        case 'kegalign':
            KEGALIGN_ALIGNMENT (
                reference_prepared,
                query_prepared
            )
            ch_alignment_psl = KEGALIGN_ALIGNMENT.out.psl_gz
            ch_psl_by_chrom  = Channel.empty()
            ch_versions      = ch_versions.mix(KEGALIGN_ALIGNMENT.out.versions)
            break

        case 'lastz':
            LASTZ_ALIGNMENT (
                reference_prepared,
                query_prepared,
                reference_chroms_dir,
                query_chroms_dir
            )
            ch_alignment_psl = LASTZ_ALIGNMENT.out.psl_gz
            ch_psl_by_chrom  = Channel.empty()
            ch_versions      = ch_versions.mix(LASTZ_ALIGNMENT.out.versions)
            // --window_masking_recovery: the masked genomes after a recovery
            ch_chain_reference = LASTZ_ALIGNMENT.out.chain_reference_twobit
            ch_chain_query     = LASTZ_ALIGNMENT.out.chain_query_prepared
            break

        default:
            throw new Exception("Invalid aligner: ${params.aligner}")
    }

    // ── 3. Chain building (one bubble per query, keyed by meta.query) ───────
    reference_chrom_sz_val   = reference_prepared.map { _n, _tb, cs -> cs }.first()

    CHAIN_BUILD (
        ch_alignment_psl,
        ch_psl_by_chrom,
        ch_chain_reference,
        reference_chrom_sz_val,
        ch_chain_query
    )
    ch_versions = ch_versions.mix(CHAIN_BUILD.out.versions)

    // ── 4 & 5. Fill and clean chains (optional) ────────────────────────────
    FILL_CLEAN_CHAINS (
        CHAIN_BUILD.out.merged_chain,
        ch_chain_reference,
        reference_chrom_sz_val,
        ch_chain_query
    )
    ch_versions = ch_versions.mix(FILL_CLEAN_CHAINS.out.versions)

    emit:
    final_chain = FILL_CLEAN_CHAINS.out.final_chain
    versions    = ch_versions
}
