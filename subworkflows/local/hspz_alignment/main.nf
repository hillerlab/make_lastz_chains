/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HSPZ_ALIGNMENT subworkflow — GPU alignment backend
    1. GPU seeding + HSP filtering, packaged as tarballs ("kegs"):
         KEGALIGN     — one instance, one keg  (--kegalign_mps_workers 1)
         KEGALIGN_MPS — N instances sharing one GPU through NVIDIA MPS, one keg
                        per reference-bin × query-bin pair  (workers > 1)
    2. CPU gapped extension of those packages, either executor:
         batched     — KEGALIGN_LASTZ (one task, lastZ's own pool) → AXT+ → PSL
         distributed — KEGALIGN_EXPAND → one KEG_LASTZ task per partition → PSL
       Both consume the identical lastZ package, so they are directly
       comparable; only the execution loop differs.

    lastZ does its own reference/query partitioning, so this subworkflow
    deliberately does not reuse PARTITION_REFERENCE / PARTITION_QUERY, and never
    repartitions or merges the .segments files it produced.

    Emits: psl_gz — same (meta, psl_files) contract LASTZ_ALIGNMENT emits, so
    CHAIN_BUILD and everything downstream cannot tell the backends apart.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { AXT_TO_PSL                       } from '../../../modules/local/axt_to_psl/main'
include { HSPZ                             } from '../../../modules/local/hspz/run/main'
include { LASTZ_SEGMENTED                  } from '../../../modules/local/lastz_segmented/main'

workflow HSPZ_ALIGNMENT {
    take:
    reference_prepared    // tuple: (reference_name, reference_twobit, reference_chrom_sizes)
    query_prepared        // tuple: (query_name,     query_twobit,     query_chrom_sizes)

    main:
    ch_versions = Channel.empty()

    reference_sizes_ch     = reference_prepared.map { _n, _tb, cs -> cs }.first()
    query_sizes_ch         = query_prepared.map     { _n, _tb, cs -> cs }.first()
    reference_twobit_val   = reference_prepared.map { _n, tb, _cs -> tb }.first()
    query_twobit_val       = query_prepared.map     { _n, tb, _cs -> tb }.first()

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
    expected_n = ch_segments.count()

    LASTZ_SEGMENTED(
        ch_segments,
        reference_twobit_val,
        query_twobit_val,
        params.lastz_h,
        params.lastz_l,
        params.lastz_y
    )
    actual_n = LASTZ_SEGMENTED.out.axt.count()

    // Every partition must have run exactly once — §10's requirement, and the
    // same last-line defence LASTZ_ALIGNMENT keeps over its N×K pair list.
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
        reference_sizes_ch,
        query_sizes_ch
    )
    ch_psl_list = AXT_TO_PSL.out.psl.map { _r, _q, psl -> psl }.collect()

    // Shape it exactly like LASTZ_ALIGNMENT.out.psl_gz: (meta, [psl files]).
    // The PSLs go to CHAIN_BUILD as-is — PSLTOOLS_SPLIT already consolidates
    // many inputs, so concatenating them first would be a wasted pass.
    reference_name_ch = reference_prepared.map { n, _tb, _cs -> n.toString() }
    query_name_ch     = query_prepared.map     { n, _tb, _cs -> n.toString() }

    ch_psl_files = ch_psl_list
        .map { psl_files -> [ psl_files ] }
        .combine(reference_name_ch)
        .combine(query_name_ch)
        .map { psl_files, ref, query ->
            [ [ id: "${ref}.${query}.all.psl" ], psl_files ]
        }

    emit:
    psl_gz   = ch_psl_files
    versions = HSPZ.out.versions
                 .mix(LASTZ_SEGMENTED.out.versions, AXT_TO_PSL.out.versions)
}
