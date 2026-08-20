/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HSPZ_ALIGNMENT subworkflow — GPU alignment backend
    1. GPU seeding + HSP filtering returned as .segments [optionally tarball]:
         HSPZ     — GPU backend, one/many instances, returns segments
    2. CPU gapped extension of those segments, one executor only:
         distributed — LASTZ_SEGMENTED → one lastZ task per partition → PSL
       Both consume the identical lastZ package, so they are directly
       comparable; only the execution loop differs.

    lastZ does its own reference/query partitioning, so this subworkflow
    deliberately does not reuse PARTITION_REFERENCE / PARTITION_QUERY, and never
    repartitions or merges the .segments files it produced.

    Emits: psl_gz — same (meta, psl_files) contract LASTZ_ALIGNMENT emits, so
    CHAIN_BUILD and everything downstream cannot tell the backends apart.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { HSPZ            } from '../../../modules/local/hspz/run/main'
include { SEGMENTS_TO_PSL } from '../segments_to_psl/main'

workflow HSPZ_ALIGNMENT {
    take:
    reference_prepared    // tuple: (reference_name, reference_twobit, reference_chrom_sizes)
    query_prepared        // tuple: (query_name,     query_twobit,     query_chrom_sizes)

    main:
    ch_versions = Channel.empty()

    reference_sizes_ch   = reference_prepared.map { _n, _tb, cs -> cs }.first()
    query_sizes_ch       = query_prepared.map     { _n, _tb, cs -> cs }.first()
    reference_twobit_val = reference_prepared.map { _n, tb, _cs -> tb }.first()
    query_twobit_val     = query_prepared.map     { _n, tb, _cs -> tb }.first()
    reference_name_val   = reference_prepared.map { n, _tb, _cs -> n.toString() }.first()
    query_name_val       = query_prepared.map     { n, _tb, _cs -> n.toString() }.first()

    // ── hspZ [GPU stage] ───────────────────────────────────────────────────────────────
    HSPZ (
      reference_prepared.map { n, tb, _cs -> [ n, tb ] },
      query_prepared.map     { n, tb, _cs -> [ n, tb ] }
    )

    // ── CPU gapped extension (GPU already released) ─────────────────────────
    // hspZ returns all segments as [ ref, query, [segments] ], so we need to
    // flatten the [ segments ] list and add metadata with r,q + baseName.
    // A glob output that matched exactly one file arrives as a single Path,
    // not a list, so normalise it first.
    ch_segments = HSPZ.out.segments.flatMap { r, q, segments ->
        def seg_list = segments instanceof List ? segments : [ segments ]
        seg_list.collect { segment ->
            tuple(
                [id: segment.baseName, reference: r, query: q],
                segment
            )
        }
    }

    SEGMENTS_TO_PSL (
        ch_segments,
        reference_twobit_val,
        query_twobit_val,
        reference_sizes_ch,
        query_sizes_ch,
        reference_name_val,
        query_name_val,
        params.lastz_h,
        params.lastz_l,
        params.lastz_y
    )

    emit:
    psl_gz   = SEGMENTS_TO_PSL.out.psl_gz
    versions = HSPZ.out.versions.mix(SEGMENTS_TO_PSL.out.versions)
}
