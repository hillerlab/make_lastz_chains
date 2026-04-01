/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    make_lastz_chains — main pipeline workflow (nf-core style)

    Steps:
    0. Validate required parameters
    1. Prepare target and query genomes (FASTA→2bit if needed, chrom.sizes)
    2. LASTZ alignment (partition → align → concatenate PSL files)
    3. Chain building (sort → bundle → axtChain → merge)
    4. Fill chains (optional)
    5. Clean chains (optional)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PREPARE_GENOMES                      } from '../subworkflows/local/prepare_genomes/main'
include { PREPARE_GENOMES as PREPARE_QUERY_GENOME } from '../subworkflows/local/prepare_genomes/main'
include { LASTZ_ALIGNMENT    } from '../subworkflows/local/lastz_alignment/main'
include { CHAIN_BUILD        } from '../subworkflows/local/chain_build/main'
include { FILL_CLEAN_CHAINS  } from '../subworkflows/local/fill_clean_chains/main'

workflow MAKE_LASTZ_CHAINS {
    take:
    target_name     // val
    query_name      // val
    target_genome   // val: path string
    query_genome    // val: path string

    main:
    ch_versions = Channel.empty()

    // ── 1. Prepare genomes ─────────────────────────────────────────────────
    PREPARE_GENOMES (
        target_name,
        target_genome
    )
    PREPARE_QUERY_GENOME (
        query_name,
        query_genome
    )

    ch_versions = ch_versions.mix(
        PREPARE_GENOMES.out.versions,
        PREPARE_QUERY_GENOME.out.versions
    )

    target_prepared = PREPARE_GENOMES.out.prepared
        // (target_name, target_twobit, target_chrom_sizes)
    query_prepared  = PREPARE_QUERY_GENOME.out.prepared

    // ── 2. LASTZ alignment ─────────────────────────────────────────────────
    LASTZ_ALIGNMENT (
        target_prepared,
        query_prepared
    )
    ch_versions = ch_versions.mix(LASTZ_ALIGNMENT.out.versions)

    // ── 3. Chain building ──────────────────────────────────────────────────
    target_twobit_val     = target_prepared.map { _n, tb, _cs -> tb }.first()
    query_twobit_val      = query_prepared.map  { _n, tb, _cs -> tb }.first()
    target_chrom_sz_val   = target_prepared.map { _n, _tb, cs -> cs }.first()

    CHAIN_BUILD (
        LASTZ_ALIGNMENT.out.psl_gz,
        target_twobit_val,
        query_twobit_val,
        target_chrom_sz_val,
        target_name,
        query_name
    )
    ch_versions = ch_versions.mix(CHAIN_BUILD.out.versions)

    // ── 4 & 5. Fill and clean chains (optional) ────────────────────────────
    query_chrom_sz_val = query_prepared.map { _n, _tb, cs -> cs }.first()

    FILL_CLEAN_CHAINS (
        CHAIN_BUILD.out.merged_chain,
        target_twobit_val,
        query_twobit_val,
        target_chrom_sz_val,
        query_chrom_sz_val,
        target_name,
        query_name
    )
    ch_versions = ch_versions.mix(FILL_CLEAN_CHAINS.out.versions)

    emit:
    final_chain = FILL_CLEAN_CHAINS.out.final_chain
    versions    = ch_versions
}
