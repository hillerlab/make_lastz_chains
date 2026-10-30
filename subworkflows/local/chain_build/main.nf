/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_BUILD subworkflow
    1. PSLTOOLS_SPLIT — split all PSL files by reference chromosome
    2. PSL_BUNDLE   — group chromosome PSL files into bundles
    3. AXT_CHAIN    — convert each PSL bundle to chains (parallel)
    4. CHAINTOOLS_MERGE — merge all chain files into one compressed chain

    One item per query flows through every step (meta.query keys it, so any
    number of queries can share a run); each step reads its own query's .2bit.

    Emits: merged_chain — *.all.chain.gz, one per query
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PSL_BUNDLE       } from '../../../modules/local/psl_bundle/main'
include { AXT_CHAIN        } from '../../../modules/local/axt_chain/main'
include { CHAINTOOLS_ANTIREPEAT } from '../../../modules/local/chaintools/antirepeat/main'
include { CHAINTOOLS_MERGE } from '../../../modules/local/chaintools/merge/main'
include { PSLTOOLS_SPLIT } from '../../../modules/local/psltools/split/main'

workflow CHAIN_BUILD {
    take:
    psl_files              // tuple per query: (meta(id, query), [psl files])
    reference_twobit       // path
    reference_chrom_sizes  // path
    query_genomes          // tuple per query: (query_name, twobit, chrom_sizes)

    main:
    // ── Split all PSL files by chromosome ───────────────────────────────────
    PSLTOOLS_SPLIT (
        psl_files
    )

    // ── Bundle sorted PSL files by chromosome for parallel axtChain ────────
    PSL_BUNDLE (
        PSLTOOLS_SPLIT.out.psl,
        reference_chrom_sizes,
        params.bundle_psl_max_bases
    )

    // ── Run axtChain on each bundle in parallel ─────────────────────────────
    // One item per bundle, riding with its query's .2bit; multiMap keeps the
    // separate process inputs paired item for item.
    ch_bundles = PSL_BUNDLE.out.bundles
        .flatMap { meta, bundles -> [ bundles ].flatten().collect { [ meta.query, meta, it ] } }
        .combine( query_genomes, by: 0 )
        .multiMap { _q, meta, bundle, twobit, _sizes ->
            bundle: [ meta, bundle ]
            twobit: twobit
        }

    AXT_CHAIN (
        ch_bundles.bundle,
        reference_twobit,
        ch_bundles.twobit,
        params.min_chain_score,
        params.chain_linear_gap,
        params.lastz_q ?: ''
    )

    // ── Run anti repeat on each chain ─────────────────────────────────────────
    ch_chains = AXT_CHAIN.out.chain
        .map { meta, chain -> [ meta.query, meta, chain ] }
        .combine( query_genomes, by: 0 )
        .multiMap { _q, meta, chain, twobit, _sizes ->
            chain:  [ meta, chain ]
            twobit: twobit
        }

    CHAINTOOLS_ANTIREPEAT (
      ch_chains.chain,
      reference_twobit,
      ch_chains.twobit,
    )

    // ── Merge each query's chain files into one ──────────────────────────────
    // ponytail: groupTuple waits for every query's chains (a barrier, not a
    // stream); key it with per-query groupKey sizes if small queries idling here
    // ever matters — ANTIREPEAT's optional output makes those sizes non-trivial.
    CHAINTOOLS_MERGE (
        CHAINTOOLS_ANTIREPEAT.out.chain.groupTuple()
    )

    emit:
    merged_chain = CHAINTOOLS_MERGE.out.chain_gz
    versions     = PSL_BUNDLE.out.versions
                     .mix( AXT_CHAIN.out.versions,
                           CHAINTOOLS_ANTIREPEAT.out.versions,
                           CHAINTOOLS_MERGE.out.versions )
}
