/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_CHAINS_HSPZ subworkflow (--repeat_filler_engine hspz)
    RepeatFiller's logic with the per-gap seeding moved to the GPU.

    Steps:
    1. FILL_GAPS        — one record pair per fillable gap, cut into shards
    2. HSPZ_FILL        — hspZ --paired: seeds + HSP filter for every gap (GPU)
    3. LASTZ_FILL       — per shard: lastz --segments extension + axtChain
    4. FILL_SPLICE      — best mini chain per gap into the merged chain
    5. CHAINTOOLS_SCORE + CHAINTOOLS_MERGE_FILLED_CHAINS, as on the lastz engine

    One item per query flows through (meta.query keys it); the shards of a
    query are released together (groupKey) as soon as its own are done.
    ponytail: one HSPZ_FILL task per query in --array runs; one --paired run
    over every query (query-prefixed gap ids) is the upgrade path.

    Emits: chain_gz — *.filled.all.chain.gz, one per query (same as lastz)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FILL_GAPS        } from '../../../modules/local/fill_gaps/main'
include { HSPZ_FILL        } from '../../../modules/local/hspz/fill/main'
include { LASTZ_FILL       } from '../../../modules/local/lastz_fill/main'
include { FILL_SPLICE      } from '../../../modules/local/fill_splice/main'
include { CHAINTOOLS_SCORE } from '../../../modules/local/chaintools/score/main'
include { CHAINTOOLS_MERGE as CHAINTOOLS_MERGE_FILLED_CHAINS } from '../../../modules/local/chaintools/merge/main'

workflow FILL_CHAINS_HSPZ {
    take:
    merged_chain      // tuple per query: (meta(id, query), *.all.chain.gz)
    reference_twobit  // path
    query_genomes     // tuple per query: (query_name, twobit, chrom_sizes)

    main:
    ch_versions = Channel.empty()

    ch_extract = merged_chain
        .map { meta, chain -> [ meta.query, meta, chain ] }
        .combine( query_genomes, by: 0 )
        .multiMap { _q, meta, chain, twobit, _sizes ->
            chain:  [ meta, chain ]
            twobit: twobit
        }

    FILL_GAPS (
        ch_extract.chain,
        reference_twobit,
        ch_extract.twobit,
        params.min_chain_score,
        params.fill_gap_max_size_t,
        params.fill_gap_max_size_q,
        params.fill_gap_min_size_t,
        params.fill_gap_min_size_q,
        params.fill_hspz_shards,
        params.skip_fill_unmask,
    )

    HSPZ_FILL (
        FILL_GAPS.out.shards,
        params.fill_lastz_k,
    )

    // One item per shard — its two FASTAs and its anchors — keyed by query/shard.
    // A glob matching one file is a Path, not a List, hence the flatten.
    def per_shard = { meta, files, ext ->
        [ files ].flatten().collect { f -> [ "${meta.query}/${f.name - ext}".toString(), meta, f ] }
    }
    ch_lastz = FILL_GAPS.out.shards
        .flatMap { meta, t, _q -> per_shard(meta, t, '.t.fa') }
        .join( FILL_GAPS.out.shards.flatMap { meta, _t, q -> per_shard(meta, q, '.q.fa') } )
        .join( HSPZ_FILL.out.segments.flatMap { meta, s -> per_shard(meta, s, '.segments') } )
        .map { key, meta, t, _m2, q, _m3, s -> [ meta, key.tokenize('/')[-1], t, q, s ] }

    LASTZ_FILL (
        ch_lastz,
        params.fill_lastz_l,
    )

    // A query's mini chains, released once all of its shards are in.
    ch_shard_counts = FILL_GAPS.out.shards
        .map { meta, t, _q -> [ meta.query, [ t ].flatten().size() ] }
    ch_minis = LASTZ_FILL.out.chain
        .map { meta, chain -> [ meta.query, chain ] }
        .combine( ch_shard_counts, by: 0 )
        .map { q, chain, n -> [ groupKey(q, n), chain ] }
        .groupTuple()
        .map { q, chains -> [ q.toString(), chains ] }

    FILL_SPLICE (
        merged_chain
            .map { meta, chain -> [ meta.query, meta, chain ] }
            .join( FILL_GAPS.out.gaps.map { meta, gaps -> [ meta.query, gaps ] } )
            .join( ch_minis )
            .map { _q, meta, chain, gaps, minis -> [ meta, chain, gaps, minis ] },
        params.fill_insert_chain_min_score,
    )

    ch_score = FILL_SPLICE.out.chain
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

    CHAINTOOLS_MERGE_FILLED_CHAINS (
        CHAINTOOLS_SCORE.out.chain
            .map { meta, chain -> [ meta + [ id: meta.id + '.filled' ], [ chain ] ] }
    )

    ch_versions = ch_versions.mix(FILL_GAPS.out.versions)
    ch_versions = ch_versions.mix(HSPZ_FILL.out.versions)
    ch_versions = ch_versions.mix(LASTZ_FILL.out.versions)
    ch_versions = ch_versions.mix(FILL_SPLICE.out.versions)
    ch_versions = ch_versions.mix(CHAINTOOLS_SCORE.out.versions)
    ch_versions = ch_versions.mix(CHAINTOOLS_MERGE_FILLED_CHAINS.out.versions)

    emit:
    chain_gz = CHAINTOOLS_MERGE_FILLED_CHAINS.out.chain_gz
    versions = ch_versions
}
