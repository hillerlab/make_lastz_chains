/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SEGMENTS_TO_PSL subworkflow — CPU extension of hspZ .segments
    Shared by HSPZ_ALIGNMENT (GPU → segments → this) and FROM_SEGMENTS
    (pre-generated segments → this). Runs one LASTZ per segments file,
    converts axt+ to PSL, and shapes the PSL channel exactly like
    LASTZ_ALIGNMENT.out.psl_gz so CHAIN_BUILD cannot tell the difference.

    The chroms_dir inputs carry the pre-extracted per-chrom FASTAs for v1
    .2bit genomes (empty sentinel dir for v0), mirroring LASTZ_ALIGNMENT.

    Segments of any number of queries can flow through at once: each item's
    meta.query picks its own query genome files, and the PSLs come out
    grouped per query.

    Emits: psl_gz — same (meta, psl_files) contract LASTZ_ALIGNMENT emits,
           one item per query.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { AXT_TO_PSL      } from '../../../modules/local/axt_to_psl/main'
include { LASTZ_SEGMENTED } from '../../../modules/local/lastz_segmented/main'

workflow SEGMENTS_TO_PSL {
    take:
    ch_segments          // tuple: [ meta(id, reference, query), segment ]
    reference_twobit     // path: reference .2bit
    reference_chroms_dir // path: dir of pre-extracted <chrom>.fa (v1) or empty dir (v0)
    reference_sizes      // path: reference chrom.sizes
    query_genomes        // tuple per query: (query_name, twobit, chrom_sizes, chroms_dir)
    lastz_h              // val
    lastz_l              // val
    lastz_y              // val

    main:
    expected_n = ch_segments.count()

    // Each segments file rides with its own query's .2bit and chroms dir;
    // multiMap keeps the separate process inputs paired item for item.
    ch_lastz = ch_segments
        .map { meta, segment -> [ meta.query, meta, segment ] }
        .combine( query_genomes, by: 0 )
        .multiMap { _q, meta, segment, twobit, _sizes, chroms_dir ->
            segment:    [ meta, segment ]
            twobit:     twobit
            chroms_dir: chroms_dir
        }

    LASTZ_SEGMENTED(
        ch_lastz.segment,
        reference_twobit,
        ch_lastz.twobit,
        reference_chroms_dir,
        ch_lastz.chroms_dir,
        lastz_h,
        lastz_l,
        lastz_y
    )
    actual_n = LASTZ_SEGMENTED.out.axt.count()

    // Every partition must have run exactly once -- the same last-line
    // defence LASTZ_ALIGNMENT keeps over its NxK pair list.
    expected_n.combine( actual_n ).map { exp, got ->
        if (exp != got) {
            error "LASTZ partition integrity check failed: expected ${exp} " +
                  "LASTZ partitions, only ${got} produced a PSL. " +
                  "${exp - got} partition(s) were lost silently. " +
                  "Aborting before downstream chain building reads incomplete data."
        }
        log.info "lastZ partition integrity check passed: ${got}/${exp} partitions completed"
        return got
    }

    ch_axt = LASTZ_SEGMENTED.out.axt
        .map { r, q, axt -> [ q, r, axt ] }
        .combine( query_genomes, by: 0 )
        .multiMap { q, r, axt, _twobit, sizes, _chroms_dir ->
            axt:   [ r, q, axt ]
            sizes: sizes
        }

    AXT_TO_PSL (
        ch_axt.axt,
        reference_sizes,
        ch_axt.sizes
    )
    // Shape it exactly like LASTZ_ALIGNMENT.out.psl_gz: (meta, [psl files]),
    // one item per query. The PSLs go to CHAIN_BUILD as-is -- PSLTOOLS_SPLIT
    // already consolidates many inputs, so concatenating them first would be a
    // wasted pass. Names come from the items, never from channel objects.
    ch_psl_files = AXT_TO_PSL.out.psl
        .map { r, q, psl -> [ [ id: "${r}.${q}".toString(), query: q ], psl ] }
        .groupTuple()

    emit:
    psl_gz   = ch_psl_files
    versions = LASTZ_SEGMENTED.out.versions
                 .mix( AXT_TO_PSL.out.versions )
}