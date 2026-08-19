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
    query_name      // val
    reference_genome   // val: path string
    query_genome    // val: path string

    main:
    ch_versions = Channel.empty()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    // Per-chromosome FASTA extraction only feeds LASTZ_ALIGNMENT; KegAlign gets
    // one whole-genome FASTA instead, so skip it for that backend.
    def extract_chroms = params.aligner == 'lastz'

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

    // ── 2. Alignment (backend selected by --aligner) ────────────────────────
    switch (params.aligner) {
        case 'hspz':
            HSPZ_ALIGNMENT (
                reference_prepared,
                query_prepared
            )
            ch_alignment_psl = HSPZ_ALIGNMENT.out.psl_gz
            ch_versions      = ch_versions.mix(HSPZ_ALIGNMENT.out.versions)
            break

        case 'kegalign':
            KEGALIGN_ALIGNMENT (
                reference_prepared,
                query_prepared
            )
            ch_alignment_psl = KEGALIGN_ALIGNMENT.out.psl_gz
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
            ch_versions      = ch_versions.mix(LASTZ_ALIGNMENT.out.versions)
            break

        default:
            throw new Exception("Invalid aligner: ${params.aligner}")
    }

    // ── 3. Chain building ──────────────────────────────────────────────────
    reference_twobit_val     = reference_prepared.map { _n, tb, _cs -> tb }.first()
    query_twobit_val      = query_prepared.map  { _n, tb, _cs -> tb }.first()
    reference_chrom_sz_val   = reference_prepared.map { _n, _tb, cs -> cs }.first()

    CHAIN_BUILD (
        ch_alignment_psl,
        reference_twobit_val,
        query_twobit_val,
        reference_chrom_sz_val,
        reference_name,
        query_name
    )
    ch_versions = ch_versions.mix(CHAIN_BUILD.out.versions)

    // ── 4 & 5. Fill and clean chains (optional) ────────────────────────────
    query_chrom_sz_val = query_prepared.map { _n, _tb, cs -> cs }.first()

    FILL_CLEAN_CHAINS (
        CHAIN_BUILD.out.merged_chain,
        reference_twobit_val,
        query_twobit_val,
        reference_chrom_sz_val,
        query_chrom_sz_val,
        reference_name,
        query_name
    )
    ch_versions = ch_versions.mix(FILL_CLEAN_CHAINS.out.versions)

    emit:
    final_chain = FILL_CLEAN_CHAINS.out.final_chain
    versions    = ch_versions
}
