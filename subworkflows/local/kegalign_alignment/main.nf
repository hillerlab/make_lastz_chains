/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    KEGALIGN_ALIGNMENT subworkflow — GPU alignment backend
    1. .2bit → FASTA for both genomes (KegAlign's GPU stage reads FASTA)
    2. GPU seeding + HSP filtering, packaged as tarballs ("kegs"):
         KEGALIGN     — one instance, one keg  (--kegalign_mps_workers 1)
         KEGALIGN_MPS — N instances sharing one GPU through NVIDIA MPS, one keg
                        per reference-bin × query-bin pair  (workers > 1)
    3. CPU gapped extension of those packages, either executor:
         batched     — KEGALIGN_LASTZ (one task, KegAlign's own pool) → AXT+ → PSL
         distributed — KEGALIGN_EXPAND → one KEG_LASTZ task per partition → PSL
       Both consume the identical KegAlign package, so they are directly
       comparable; only the execution loop differs.

    KegAlign does its own reference/query partitioning, so this subworkflow
    deliberately does not reuse PARTITION_REFERENCE / PARTITION_QUERY, and never
    repartitions or merges the .segments files it produced.

    Emits: psl_gz — same (meta, psl_files) contract LASTZ_ALIGNMENT emits, so
    CHAIN_BUILD and everything downstream cannot tell the backends apart.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { TWO_BIT_TO_FA as REFERENCE_TO_FA } from '../../../modules/local/two_bit_to_fa/main'
include { TWO_BIT_TO_FA as QUERY_TO_FA     } from '../../../modules/local/two_bit_to_fa/main'
include { KEGALIGN                         } from '../../../modules/local/kegalign/main'
include { KEGALIGN_MPS                     } from '../../../modules/local/kegalign_mps/main'
include { KEGALIGN_LASTZ                   } from '../../../modules/local/kegalign_lastz/main'
include { AXT_TO_PSL                       } from '../../../modules/local/axt_to_psl/main'
include { KEGALIGN_EXPAND                  } from '../../../modules/local/kegalign_expand/main'
include { KEG_LASTZ                        } from '../../../modules/local/keg_lastz/main'

workflow KEGALIGN_ALIGNMENT {
    take:
    reference_prepared    // tuple: (reference_name, reference_twobit, reference_chrom_sizes)
    query_prepared        // tuple: (query_name,     query_twobit,     query_chrom_sizes)

    main:
    reference_sizes_ch = reference_prepared.map { _n, _tb, cs -> cs }.first()
    query_sizes_ch     = query_prepared.map     { _n, _tb, cs -> cs }.first()

    // ── .2bit → FASTA ───────────────────────────────────────────────────────
    REFERENCE_TO_FA ( reference_prepared.map { n, tb, _cs -> [ n, tb ] } )
    QUERY_TO_FA     ( query_prepared.map     { n, tb, _cs -> [ n, tb ] } )

    // ── GPU stage ───────────────────────────────────────────────────────────
    // The same LASTZ scoring parameters the CPU backend uses. LASTZ's
    // blastz-style letters map onto KegAlign's long options one-to-one:
    // K=--hspthresh, L=--gappedthresh, H=--inner, Y=--ydrop.
    //
    // With --kegalign_mps_workers > 1 the same stage runs N KegAlign instances
    // over chromosome-bin pairs on one MPS-shared GPU, emitting one keg per pair
    // instead of one. Workers = 1 never touches MPS: it is today's execution,
    // unchanged, because run_mig.py starts an MPS daemon even for --MPS 1.
    def mps_workers = params.kegalign_mps_workers as int

    if (mps_workers > 1) {
        KEGALIGN_MPS (
            REFERENCE_TO_FA.out.fasta,
            QUERY_TO_FA.out.fasta,
            mps_workers,
            params.lastz_k,
            params.lastz_l,
            params.lastz_h,
            params.lastz_y
        )

        // One channel item per keg — the CPU stage below is per-keg either way.
        // flatten() because a glob output is a bare path when it matches once.
        ch_kegs     = KEGALIGN_MPS.out.tarball
                        .flatMap { r, q, kegs -> [ kegs ].flatten().collect { [ r, q, it ] } }
        ch_gpu_vers = KEGALIGN_MPS.out.versions
    }
    else {
        KEGALIGN (
            REFERENCE_TO_FA.out.fasta,
            QUERY_TO_FA.out.fasta,
            params.lastz_k,
            params.lastz_l,
            params.lastz_h,
            params.lastz_y
        )

        ch_kegs     = KEGALIGN.out.tarball
        ch_gpu_vers = KEGALIGN.out.versions
    }

    ch_versions = REFERENCE_TO_FA.out.versions
                    .mix( QUERY_TO_FA.out.versions, ch_gpu_vers )

    // ── CPU gapped extension (GPU already released) ─────────────────────────
    // Both executors process every keg. 'distributed' additionally assumes a
    // single keg (its job ids and package directory are global), which is why
    // main.nf rejects it together with --kegalign_mps_workers > 1.
    if (params.kegalign_executor == 'distributed') {
        KEGALIGN_EXPAND ( ch_kegs )

        // One channel item per KegAlign diagonal partition.
        jobs_list  = KEGALIGN_EXPAND.out.jobs
            .splitCsv(sep: '\t')
            .collect(flat: false)
        expected_n = jobs_list.map { it.size() }
        jobs_ch    = jobs_list.flatMap { it }   // (job_id, segments_filename)

        KEG_LASTZ (
            jobs_ch,
            KEGALIGN_EXPAND.out.expanded.map { _r, _q, dir -> dir }.first(),
            reference_sizes_ch,
            query_sizes_ch
        )

        // Every partition must have run exactly once — §10's requirement, and the
        // same last-line defence LASTZ_ALIGNMENT keeps over its N×K pair list.
        actual_n = KEG_LASTZ.out.psl.count()
        expected_n.combine( actual_n ).map { exp, got ->
            if (exp != got) {
                error "KegAlign partition integrity check failed: expected ${exp} " +
                      "LASTZ partitions, only ${got} produced a PSL. " +
                      "${exp - got} partition(s) were lost silently. " +
                      "Aborting before downstream chain building reads incomplete data."
            }
            log.info "KegAlign partition integrity check passed: ${got}/${exp} partitions completed"
            return got
        }

        ch_psl_list = KEG_LASTZ.out.psl.collect()
        ch_versions = ch_versions.mix( KEGALIGN_EXPAND.out.versions, KEG_LASTZ.out.versions )
    }
    else {
        KEGALIGN_LASTZ ( ch_kegs )

        AXT_TO_PSL (
            KEGALIGN_LASTZ.out.axt,
            reference_sizes_ch,
            query_sizes_ch
        )

        ch_psl_list = AXT_TO_PSL.out.psl.map { _r, _q, psl -> psl }.collect()
        ch_versions = ch_versions.mix( KEGALIGN_LASTZ.out.versions, AXT_TO_PSL.out.versions )
    }

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
    versions = ch_versions
}
