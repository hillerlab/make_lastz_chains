/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HSPZ_ALIGNMENT subworkflow — GPU alignment backend
    1. .2bit → whole-genome FASTA for both genomes: hspZ's bundled twobit reader
       only parses v0 .2bit, so v1 genomes would fail there. twoBitToFa handles
       both versions, so the conversion runs unconditionally.
    2. GPU seeding + HSP filtering returned as .segments:
         HSPZ     — GPU backend; one task for every query (--array: one
                    hspZ --query-list batch), returns segments
    3. CPU gapped extension of those segments, one executor only:
         LASTZ_SEGMENTED → one lastZ task per partition → PSL
       Scoring matches KegAlign: lastz_k → hspZ --hspthresh, then LASTZ
       --gappedthresh/--inner/--ydrop/--strand from lastz_l/h/y + partition.

    lastZ does its own reference/query partitioning, so this subworkflow
    deliberately does not reuse PARTITION_REFERENCE / PARTITION_QUERY, and never
    repartitions or merges the .segments files it produced.

    Emits: psl_gz — same (meta, psl_files) contract LASTZ_ALIGNMENT emits, so
    CHAIN_BUILD and everything downstream cannot tell the backends apart.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { TWO_BIT_TO_FA as REFERENCE_TO_FA } from '../../../modules/local/two_bit_to_fa/main'
include { TWO_BIT_TO_FA as QUERY_TO_FA     } from '../../../modules/local/two_bit_to_fa/main'
include { HSPZ            } from '../../../modules/local/hspz/run/main'
include { SEGMENTS_TO_PSL } from '../segments_to_psl/main'

workflow HSPZ_ALIGNMENT {
    take:
    reference_prepared    // tuple: (reference_name, reference_twobit, reference_chrom_sizes)
    query_prepared        // tuple per query: (query_name, query_twobit, query_chrom_sizes)
    reference_chroms_dir  // tuple: (reference_name, dir/) — pre-extracted v1 FASTAs, empty dir for v0
    query_chroms_dir      // tuple per query: (query_name, dir/)

    main:
    reference_sizes_ch   = reference_prepared.map { _n, _tb, cs -> cs }.first()
    reference_twobit_val = reference_prepared.map { _n, tb, _cs -> tb }.first()
    reference_chroms_val = reference_chroms_dir.map { _n, d -> d }.first()

    // ── .2bit → FASTA ───────────────────────────────────────────────────────
    REFERENCE_TO_FA ( reference_prepared.map { n, tb, _cs -> [ n, tb ] } )
    QUERY_TO_FA     ( query_prepared.map     { n, tb, _cs -> [ n, tb ] } )

    // ── hspZ [GPU stage] ───────────────────────────────────────────────────────────────
    // Every query goes to the one HSPZ task as ([names], [FASTAs]), sorted so
    // the task hash (and -resume) does not depend on which FASTA came first.
    HSPZ (
      REFERENCE_TO_FA.out.fasta,
      QUERY_TO_FA.out.fasta
        .toSortedList { a, b -> a[0] <=> b[0] }
        .map { queries -> [ queries*.getAt(0), queries*.getAt(1) ] },
      params.lastz_k
    )

    // ── CPU gapped extension (GPU already released) ─────────────────────────
    // hspZ returns all segments as [ ref, [queries], [segments] ]: one query's
    // segments sit in segments/, --array names each job directory after its
    // query (segments/<query>/). A glob output that matched exactly one file
    // arrives as a single Path, not a list, so normalise it first.
    ch_segments = HSPZ.out.segments.flatMap { r, queries, segments ->
        [ segments ].flatten().collect { segment ->
            def q = params.array ? segment.parent.name : queries[0]
            tuple( [ id: segment.baseName, reference: r, query: q ], segment )
        }
    }

    SEGMENTS_TO_PSL (
        ch_segments,
        reference_twobit_val,
        reference_chroms_val,
        reference_sizes_ch,
        query_prepared.join( query_chroms_dir ),
        params.lastz_h,
        params.lastz_l,
        params.lastz_y
    )

    emit:
    psl_gz   = SEGMENTS_TO_PSL.out.psl_gz
    versions = REFERENCE_TO_FA.out.versions
                .mix( QUERY_TO_FA.out.versions, HSPZ.out.versions, SEGMENTS_TO_PSL.out.versions )
}
