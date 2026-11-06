/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_BUILD subworkflow
    1. PSLTOOLS_SPLIT — split the CPU backends' PSL files by reference chromosome
                        (hspZ's LASTZ_SEGMENTED already writes them that way)
    2. bundling       — group chromosome PSL files by total base count; planned
                        here from chrom.sizes, no PSL is copied
    3. AXT_CHAIN      — stream each bundle's files into axtChain (parallel)
    4. CHAINTOOLS_MERGE — merge all chain files into one compressed chain

    One item per query flows through every step (meta.query keys it, so any
    number of queries can share a run); each step reads its own query's .2bit.

    Emits: merged_chain — *.all.chain.gz, one per query
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { AXT_CHAIN        } from '../../../modules/local/axt_chain/main'
include { CHAINTOOLS_ANTIREPEAT } from '../../../modules/local/chaintools/antirepeat/main'
include { CHAINTOOLS_MERGE } from '../../../modules/local/chaintools/merge/main'
include { PSLTOOLS_SPLIT } from '../../../modules/local/psltools/split/main'

/*
 * The grouping the old psl_bundle.py made, without copying any PSL: reference
 * chromosomes that have PSL, largest first (ties keep chrom.sizes order), fill
 * a bundle until it spans max_bases or holds more than 1,000 chromosomes.
 * Returns [ meta, 'bundle.N', [files] ] per bundle; files follow that
 * chromosome order, and a chromosome's own files are sorted by name so the
 * AXT_CHAIN hash (and -resume) does not depend on task completion order.
 */
def pslBundles(meta, chroms, files, chrom_sizes, long max_bases) {
    def by_chrom = [:]
    [ chroms, files ].transpose().each { c, f -> by_chrom.get(c, []) << f }

    def sizes = [:]
    chrom_sizes.eachLine { line ->
        def fields = line.split('\t')
        if (fields.size() > 1) sizes[fields[0]] = fields[1] as long
    }
    by_chrom.keySet().findAll { !sizes.containsKey(it) }.each { c ->
        log.warn "${meta.id}: PSL of ${c} not bundled, ${c} is not in ${chrom_sizes.name}"
    }

    def bundles = []
    def current = []
    long bases = 0
    for (c in sizes.keySet().toList().sort { a, b -> sizes[b] <=> sizes[a] }) {
        if (!by_chrom.containsKey(c)) continue
        bases += sizes[c]
        current << c
        if (bases >= max_bases || current.size() > 1000) {
            bundles << current
            current = []
            bases = 0
        }
    }
    if (current) bundles << current

    return bundles.withIndex().collect { cs, i ->
        [ meta, "bundle.${i}".toString(), cs.collectMany { c -> by_chrom[c].sort(false) { it.name } } ]
    }
}

workflow CHAIN_BUILD {
    take:
    psl_files              // tuple per query: (meta(id, query), [psl files]) — split here
    psl_by_chrom           // tuple per file:  (meta(id, query), reference chrom, psl[.gz]) — already split
    reference_twobit       // path
    reference_chrom_sizes  // path
    query_genomes          // tuple per query: (query_name, twobit, chrom_sizes)

    main:
    // ── Split the CPU backends' PSL files by chromosome ─────────────────────
    PSLTOOLS_SPLIT (
        psl_files
    )

    // PSLTOOLS_SPLIT names each output <chrom>.psl.
    ch_chrom_psl = PSLTOOLS_SPLIT.out.psl
        .flatMap { meta, psl -> [ psl ].flatten().collect { f -> [ meta, f.name - ~/\.psl$/, f ] } }
        .mix( psl_by_chrom )

    // ── Bundle chromosomes for parallel axtChain ────────────────────────────
    // groupTuple waits for every file of every query (the split was already
    // such a barrier). One item per bundle, riding with its query's .2bit;
    // multiMap keeps the separate process inputs paired item for item.
    ch_bundles = ch_chrom_psl
        .groupTuple()
        .combine( reference_chrom_sizes )
        .flatMap { meta, chroms, files, sizes ->
            pslBundles(meta, chroms, files, sizes, params.bundle_psl_max_bases as long)
        }
        .map { meta, bundle, files -> [ meta.query, meta, bundle, files ] }
        .combine( query_genomes, by: 0 )
        .multiMap { _q, meta, bundle, files, twobit, _sizes ->
            bundle: [ meta, bundle, files ]
            twobit: twobit
        }

    // ── Run axtChain on each bundle in parallel ─────────────────────────────
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
    versions     = PSLTOOLS_SPLIT.out.versions
                     .mix( AXT_CHAIN.out.versions,
                           CHAINTOOLS_ANTIREPEAT.out.versions,
                           CHAINTOOLS_MERGE.out.versions )
}
