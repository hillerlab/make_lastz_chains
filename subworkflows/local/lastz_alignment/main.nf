/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_ALIGNMENT subworkflow
    1. Partition reference and query genomes into chunks
    2. Create N×K alignment pairs via channel.combine()
    3. Run LASTZ on each pair in parallel
    4. Collect all PSL outputs into a single channel

    Emits: psl — all .psl files ready for chromosome split/bundle
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PARTITION as PARTITION_REFERENCE } from '../../../modules/local/partition/main'
include { PARTITION as PARTITION_QUERY  } from '../../../modules/local/partition/main'
include { LASTZ     } from '../../../modules/local/lastz/main'

workflow LASTZ_ALIGNMENT {
    take:
    reference_prepared    // tuple: (reference_name, reference_twobit, reference_chrom_sizes)
    query_prepared        // tuple: (query_name,  query_twobit,  query_chrom_sizes)
    reference_chroms_dir  // tuple: (reference_name, dir/) — pre-extracted v1 FASTAs
    query_chroms_dir      // tuple: (query_name,  dir/) — pre-extracted v1 FASTAs

    main:
    // ── Partition ───────────────────────────────────────────────────────────
    PARTITION_REFERENCE (
        reference_prepared,
        'reference',
        params.seq1_chunk,
        params.seq1_lap
    )
    PARTITION_QUERY (
        query_prepared,
        'query',
        params.seq2_chunk,
        params.seq2_lap
    )

    // ── Emit individual partition strings as channel items ──────────────────
    reference_parts_ch = PARTITION_REFERENCE.out.partitions
        .map { _name, part_file -> part_file }
        .splitText()      // one line per channel item
        .map { it.trim() }
        .filter { it }    // drop empty lines

    query_parts_ch = PARTITION_QUERY.out.partitions
        .map { _name, part_file -> part_file }
        .splitText()
        .map { it.trim() }
        .filter { it }

    // ── Cross-product N×K pairs ─────────────────────────────────────────────
    // Materialise the full pair list so we can both count it (for the
    // post-LASTZ integrity check) and feed it to LASTZ without consuming the
    // channel twice.
    pairs_list  = reference_parts_ch.combine(query_parts_ch).collect(flat: false)
    expected_n  = pairs_list.map { it.size() }
    pairs_ch    = pairs_list.flatMap { it }
    // pairs_ch emits: (reference_partition_str, query_partition_str)

    // ── LASTZ alignment ─────────────────────────────────────────────────────
    reference_twobit_ch       = reference_prepared.map { _n, tb, _cs -> tb }
    reference_chrom_sz_ch     = reference_prepared.map { _n, _tb, cs -> cs }
    reference_chroms_dir_ch   = reference_chroms_dir.map { _n, d -> d }
    reference_name            = reference_prepared.map { n, _tb, _cs -> n.toString() }

    query_twobit_ch        = query_prepared.map  { _n, tb, _cs -> tb }
    query_chrom_sz_ch      = query_prepared.map  { _n, _tb, cs -> cs }
    query_chroms_dir_ch    = query_chroms_dir.map  { _n, d -> d }
    query_name             = query_prepared.map  { n, _tb, _cs -> n.toString() }

    LASTZ (
        pairs_ch,
        reference_twobit_ch.first(),
        query_twobit_ch.first(),
        reference_chrom_sz_ch.first(),
        query_chrom_sz_ch.first(),
        reference_chroms_dir_ch.first(),
        query_chroms_dir_ch.first(),
        params.lastz_k,
        params.lastz_h,
        params.lastz_l,
        params.lastz_y,
    )

    // ── Integrity check: every expected pair must have completed ───────────
    // versions.yml is emitted by every successful LASTZ task (no `optional`),
    // so its count equals the number of tasks that ran to completion. With
    // the strict errorStrategy in nextflow.config, a permanently-failed task
    // already aborts the workflow before reaching this point; this assertion
    // is the last-line defence against a Nextflow channel bug or a process
    // that exits 0 without writing versions.yml.
    actual_n = LASTZ.out.versions.count()
    expected_n.combine( actual_n ).map { exp, got ->
        if (exp != got) {
            error "LASTZ integrity check failed: expected ${exp} alignment tasks, " +
                  "only ${got} produced output. ${exp - got} pair(s) were lost silently. " +
                  "Aborting before downstream chain building reads incomplete data."
        }
        log.info "LASTZ integrity check passed: ${got}/${exp} pair tasks completed"
        return got
    }

    // ── Collect all PSL files into a single channel ───────────────────────────────────
    // Feed LASTZ's raw per-partition PSLs straight to the chromosome split/bundle step:
    // PSLTOOLS_SPLIT --by reference already consolidates across query partitions, and
    // axtChain sorts its block list internally, so the per-bucket PSLTOOLS_MERGE was
    // redundant (one extra full pass over all alignment data).
    ch_psl_files = LASTZ.out.psl
        .map { reference_part, psl -> psl }
        .collect()
        .map { psl_files -> [psl_files] }
        .combine(reference_name)
        .combine(query_name)
        .map { psl_files, ref, query ->
            [ [ id: "${ref}.${query}.all.psl" ], psl_files ]
        }

    emit:
    psl_gz   = ch_psl_files
    versions = PARTITION_REFERENCE.out.versions.mix(PARTITION_QUERY.out.versions, LASTZ.out.versions)
}
