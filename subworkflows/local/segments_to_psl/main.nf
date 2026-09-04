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

    Emits: psl_gz — same (meta, psl_files) contract LASTZ_ALIGNMENT emits.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { AXT_TO_PSL      } from '../../../modules/local/axt_to_psl/main'
include { LASTZ_SEGMENTED } from '../../../modules/local/lastz_segmented/main'

workflow SEGMENTS_TO_PSL {
    take:
    ch_segments          // tuple: [ meta, segment ]
    reference_twobit     // path: reference .2bit
    query_twobit         // path: query .2bit
    reference_chroms_dir // path: dir of pre-extracted <chrom>.fa (v1) or empty dir (v0)
    query_chroms_dir     // path: dir of pre-extracted <chrom>.fa (v1) or empty dir (v0)
    reference_sizes      // path: reference chrom.sizes
    query_sizes          // path: query chrom.sizes
    reference_name       // val
    query_name           // val
    lastz_h              // val
    lastz_l              // val
    lastz_y              // val

    main:
    expected_n = ch_segments.count()

    LASTZ_SEGMENTED(
        ch_segments,
        reference_twobit,
        query_twobit,
        reference_chroms_dir,
        query_chroms_dir,
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

    AXT_TO_PSL (
        LASTZ_SEGMENTED.out.axt,
        reference_sizes,
        query_sizes
    )
    ch_psl_list = AXT_TO_PSL.out.psl.map { _r, _q, psl -> psl }.collect()

    // Shape it exactly like LASTZ_ALIGNMENT.out.psl_gz: (meta, [psl files]).
    // The PSLs go to CHAIN_BUILD as-is -- PSLTOOLS_SPLIT already consolidates
    // many inputs, so concatenating them first would be a wasted pass.
    ch_psl_files = ch_psl_list
        .map { psl_files -> [ [ id: "${reference_name}.${query_name}.all.psl" ], psl_files ] }

    emit:
    psl_gz   = ch_psl_files
    versions = LASTZ_SEGMENTED.out.versions
                 .mix( AXT_TO_PSL.out.versions )
}