/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_CLEAN_CHAINS subworkflow
    Optionally fills gaps in chains and optionally cleans weak chains.

    Steps (both conditional on params flags):
    1. CHAINTOOLS_SPLIT       — split merged chain into N parts
    2. REPEAT_FILLER          — fill gaps in each part in parallel
    3. CHAINTOOLS_MERGE       — merge filled parts
    4. CHAINC                — remove suspicious chains
    5. CHAINTOOLS_FILTER      — apply minimum score filter → final.chain.gz

    One item per query flows through every step (meta.query keys it); each step
    reads its own query's .2bit and chrom.sizes.

    Emits: final_chain — *.allfilled.chain.gz, one per query
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { REPEAT_FILLER     } from '../../../modules/local/repeat_filler/main'
include { CHAINC } from '../../../modules/local/chainc/main'
include { CHAINTOOLS_SPLIT  } from '../../../modules/local/chaintools/split/main'
include { CHAINTOOLS_SCORE  } from '../../../modules/local/chaintools/score/main'
include { CHAINTOOLS_MERGE as CHAINTOOLS_MERGE_FILLED_CHAINS } from '../../../modules/local/chaintools/merge/main'
include { CHAINTOOLS_FILTER as CHAINTOOLS_FILTER_CLEANED_CHAINS } from '../../../modules/local/chaintools/filter/main'

workflow FILL_CLEAN_CHAINS {
    take:
    merged_chain           // tuple per query: (meta(id, query), *.all.chain.gz)
    reference_twobit       // path
    reference_chrom_sizes  // path
    query_genomes          // tuple per query: (query_name, twobit, chrom_sizes)

    main:
    ch_versions = Channel.empty()

    // ── Fill chains (optional) ──────────────────────────────────────────────
    if (!params.skip_fill_chains) {
        CHAINTOOLS_SPLIT (
            merged_chain,
            params.num_fill_jobs
        )

        // One item per chunk, riding with its query's .2bit; multiMap keeps the
        // separate process inputs paired item for item.
        ch_fill = CHAINTOOLS_SPLIT.out.chains
            .flatMap { meta, chains -> [ chains ].flatten().collect { [ meta.query, meta, it ] } }
            .combine( query_genomes, by: 0 )
            .multiMap { _q, meta, chunk, twobit, _sizes ->
                chunk:  [ meta, chunk ]
                twobit: twobit
            }

        REPEAT_FILLER (
            ch_fill.chunk,
            reference_twobit,
            ch_fill.twobit,
            params.min_chain_score,
            params.fill_gap_max_size_t,
            params.fill_gap_max_size_q,
            params.fill_insert_chain_min_score,
            params.fill_gap_min_size_t,
            params.fill_gap_min_size_q,
            params.fill_lastz_k,
            params.fill_lastz_l,
            params.chain_linear_gap,
            params.skip_fill_unmask,
        )

        ch_score = REPEAT_FILLER.out.filled_chain
            .map { meta, chain -> [ meta.query, meta, chain ] }
            .combine( query_genomes, by: 0 )
            .multiMap { _q, meta, chain, twobit, _sizes ->
                chain:  [ meta, chain ]
                twobit: twobit
            }

        CHAINTOOLS_SCORE (
            ch_score.chain,
            reference_twobit,
            ch_score.twobit
        )

        // ponytail: groupTuple is a barrier across queries, like CHAIN_BUILD's merge.
        CHAINTOOLS_MERGE_FILLED_CHAINS (
            CHAINTOOLS_SCORE.out.chain
              .groupTuple()
              .map { meta, chains -> [ meta + [ id: meta.id + '.filled' ], chains ] }
        )

        // merge --sort-by score --rename already emits score-descending chains
        // (chainc's required input order), so no separate sort step is needed.
        ch_chain_for_clean = CHAINTOOLS_MERGE_FILLED_CHAINS.out.chain_gz

        ch_versions = ch_versions.mix(CHAINTOOLS_SPLIT.out.versions)
        ch_versions = ch_versions.mix(REPEAT_FILLER.out.versions)
        ch_versions = ch_versions.mix(CHAINTOOLS_MERGE_FILLED_CHAINS.out.versions)
        ch_versions = ch_versions.mix(CHAINTOOLS_SCORE.out.versions)
    } else {
        ch_chain_for_clean = merged_chain
    }

    // ── Clean chains (optional) ─────────────────────────────────────────────
    if (!params.skip_clean_chain) {
        ch_clean = ch_chain_for_clean
            .map { meta, chain -> [ meta.query, meta, chain ] }
            .combine( query_genomes, by: 0 )
            .multiMap { _q, meta, chain, twobit, sizes ->
                chain:  [ meta, chain, [] ]
                twobit: twobit
                sizes:  sizes
            }

        CHAINC (
            ch_clean.chain,
            reference_twobit,
            ch_clean.twobit,
            reference_chrom_sizes,
            ch_clean.sizes,
            params.chain_linear_gap
        )

        CHAINTOOLS_FILTER_CLEANED_CHAINS (
            CHAINC.out.chain,
            params.min_chain_score,
        )

        ch_final = CHAINTOOLS_FILTER_CLEANED_CHAINS.out.chain_gz

        ch_versions = ch_versions.mix(CHAINC.out.versions)
        ch_versions = ch_versions.mix(CHAINTOOLS_FILTER_CLEANED_CHAINS.out.versions)
    } else {
        // Not cleaning: the filled (or merged) chain is the final chain.
        ch_final = ch_chain_for_clean
    }

    emit:
    final_chain = ch_final
    versions    = ch_versions
}
