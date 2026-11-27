/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SEGMENTS_TO_PSL subworkflow — CPU extension of hspZ .segments
    Shared by HSPZ_ALIGNMENT (GPU → segments → this) and FROM_SEGMENTS
    (pre-generated segments → this). Runs one LASTZ_SEGMENTED per segments
    file; each pipes lastz into axtToPsl and writes gzipped PSL per reference
    chromosome, so CHAIN_BUILD needs no split pass.

    The chroms_dir inputs carry the pre-extracted per-chrom FASTAs for v1
    .2bit genomes (empty sentinel dir for v0), mirroring LASTZ_ALIGNMENT.

    Segments of any number of queries can flow through at once: each item's
    meta.query picks its own query genome files.

    --dense_windows (default report): DENSE_WINDOWS first reads each query's
    segments for satellite arrays shared by both genomes (a 100 kb x 100 kb
    block with >= 100k anchors, then 10 kb windows along each genome).
      report — log a warning and publish the report; lastz is not held back
      filter — drop the anchors inside the regions, and soft-mask the regions
               into the genomes chaining, fill and clean read (DENSE_MASK_*)
      fail   — stop the run before any lastz job starts
      off    — skip it
    A query without a dense block keeps its own segments in every mode.
    --mask_reference_regions_bed: reference regions whose anchors are dropped
    in every mode (also off), triggered or not, and which the later steps read
    soft-masked. Every query then waits for DENSE_WINDOWS and takes its kept
    files. REFERENCE_MASK_BED soft-masks the BED into the reference once per
    run (it does not depend on the queries, so --reference_cache_dir keeps it);
    with filter, DENSE_MASK_REFERENCE adds the found regions on top.
    --lastz_segments_per_job N: N segments files per LASTZ_SEGMENTED task
    instead of one; each file runs as it does alone, so the PSL is the same.

    Emits: psl_by_chrom — (meta(id, query), reference chromosome, psl.gz), one
           item per file, the CHAIN_BUILD input that skips PSLTOOLS_SPLIT.
           chain_reference_twobit / chain_query_prepared — the genomes the
           later steps read: the masked ones after --dense_windows filter
           found arrays, the inputs otherwise.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { LASTZ_SEGMENTED } from '../../../modules/local/lastz_segmented/main'
include { DENSE_WINDOWS   } from '../../../modules/local/dense_windows/main'
include { MASK_GENOME as DENSE_MASK_REFERENCE } from '../../../modules/local/mask_genome/main'
include { MASK_GENOME as REFERENCE_MASK_BED   } from '../../../modules/local/mask_genome/main'
include { MASK_GENOME as DENSE_MASK_QUERY     } from '../../../modules/local/mask_genome/main'

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
    def dense_mode         = params.dense_windows.toString()
    def mask_bed           = params.mask_reference_regions_bed ?
        file(params.mask_reference_regions_bed, checkIfExists: true) : []
    def masking            = params.mask_reference_regions_bed as boolean
    ch_versions            = Channel.empty()
    ch_query_prepared      = query_genomes.map { q, tb, cs, _d -> [ q, tb, cs ] }
    ch_extend              = ch_segments
    chain_reference_twobit = reference_twobit
    chain_query_prepared   = ch_query_prepared

    // ── --dense_windows: shared satellite arrays, one task per query ────────
    if (dense_mode != 'off' || masking) {
        DENSE_WINDOWS (
            ch_segments
                .map { meta, segment -> [ meta.query, meta.reference, segment ] }
                .groupTuple()
                .map { q, refs, segments -> [ q, refs[0], segments ] }
                .join( query_genomes.map { q, _tb, cs, _d -> [ q, cs ] } ),
            reference_sizes,
            dense_mode,
            mask_bed
        )
        ch_versions = ch_versions.mix( DENSE_WINDOWS.out.versions )

        // (query, filtered): the query's segments are replaced by its kept files.
        // The warning or error names what was found.
        ch_dense = DENSE_WINDOWS.out.status
            .join( DENSE_WINDOWS.out.report )
            .map { q, triggered, report ->
                if (triggered == 'yes') {
                    def r = report.readLines().collectEntries { l -> def f = l.split('\t', 2); [ (f[0]): f[1] ] }
                    def found = "dense_windows: ${q}: satellite arrays shared by both genomes (densest " +
                        "100 kb x 100 kb block ${r.densest_block_anchors} anchors at ${r.densest_block}; " +
                        "${r.anchors_in_regions_pct}% of ${r.anchors} anchors in ${r.reference_regions} reference " +
                        "+ ${r.query_regions} query regions, listed in 02_hspz/dense_windows/)"
                    if (dense_mode == 'fail') {
                        error "${found}. Re-run with --dense_windows filter to drop those anchors, " +
                              "or soft-mask the regions in both genomes."
                    }
                    if (dense_mode == 'report') {
                        log.warn "${found}. lastz can spend thousands of CPU hours extending them; " +
                                 "--dense_windows filter drops them."
                    } else {
                        log.warn "${found}: dropped, ${r.anchors_kept} anchors kept; chaining, fill and " +
                                 "clean read the genomes with the regions soft-masked."
                    }
                }
                if (masking) {
                    def r = report.readLines().collectEntries { l -> def f = l.split('\t', 2); [ (f[0]): f[1] ] }
                    log.info "mask_reference_regions_bed: ${q}: ${r.anchors_in_mask} anchors (${r.anchors_in_mask_pct}%) " +
                             "in ${r.mask_reference_regions} regions (${r.mask_reference_regions_bp} bp) of ${r.mask_reference_bed} dropped"
                    if ((r.mask_reference_regions as long) == 0) {
                        log.warn "mask_reference_regions_bed: none of ${r.mask_reference_bed}'s intervals is on a " +
                                 "chromosome of the reference; nothing is masked"
                    }
                }
                [ q, masking || (triggered == 'yes' && dense_mode == 'filter'), triggered == 'yes' ]
            }

        // filter / fail, or the BED: lastz waits for the verdict, and a query
        // without a dense block (and no BED) keeps its own files. report:
        // nothing waits.
        if (dense_mode != 'report' || masking) {
            ch_extend = ch_segments
                .map { meta, segment -> [ meta.query, meta, segment ] }
                .combine( ch_dense, by: 0 )
                .filter { _q, _meta, _segment, filtered, _triggered -> !filtered }
                .map { _q, meta, segment, _f, _t -> [ meta, segment ] }
        }

        if (dense_mode == 'filter' || masking) {
            // A glob output that matched one file arrives as a bare Path.
            ch_extend = ch_extend.mix(
                DENSE_WINDOWS.out.kept.flatMap { q, ref, kept ->
                    [ kept ].flatten().collect { f -> [ [ id: f.baseName, reference: ref, query: q ], f ] }
                }
            )
        }

        // The BED, soft-masked into the reference the later steps read: once per
        // run, whatever the queries are.
        if (masking) {
            REFERENCE_MASK_BED (
                reference_twobit.map { tb -> [ params.reference_name.toString(), tb, mask_bed ] }
            )
            ch_versions = ch_versions.mix( REFERENCE_MASK_BED.out.versions )
            // A value channel whether reference_twobit is one or a queue of one.
            chain_reference_twobit = REFERENCE_MASK_BED.out.twobit.collect { _n, tb -> tb }.map { tbs -> tbs[0] }
        }

        if (dense_mode == 'filter') {
            // The found regions, soft-masked into the genomes the later steps
            // read: each query gets its own, the reference the union over its
            // queries (on top of the BED's mask when there is one).
            def ch_reference_base = chain_reference_twobit
            DENSE_MASK_QUERY (
                query_genomes.map { q, tb, _cs, _d -> [ q, tb ] }
                    .join( DENSE_WINDOWS.out.regions.map { q, _ref, _rbed, qbed -> [ q, qbed ] } )
            )
            DENSE_MASK_REFERENCE (
                DENSE_WINDOWS.out.regions
                    .map { _q, ref, rbed, _qbed -> [ ref, rbed ] }
                    .groupTuple()
                    .combine( ch_reference_base )
                    .map { ref, beds, tb -> [ ref, tb, beds ] }
            )
            ch_versions = ch_versions.mix( DENSE_MASK_REFERENCE.out.versions, DENSE_MASK_QUERY.out.versions )

            // 'NONE' when no query had a dense block: the inputs stay.
            ch_masked_ref = DENSE_MASK_REFERENCE.out.twobit.map { _n, tb -> tb }.ifEmpty('NONE')
            chain_reference_twobit = ch_reference_base
                .combine( ch_masked_ref )
                .map { tb, masked -> masked == 'NONE' ? tb : masked }
                .first()
            chain_query_prepared = ch_query_prepared
                .join( DENSE_MASK_QUERY.out.twobit, remainder: true )
                .map { q, tb, cs, masked -> [ q, masked ?: tb, cs ] }
        }
    }

    expected_n = ch_extend.count()

    // --lastz_segments_per_job N: a query's files, sorted by name, are dealt
    // out over ceil(files / N) tasks in turn. Neighbouring files (the same
    // stretch of the reference) land in different tasks, so the tasks are of
    // similar length, and the batches are the same in a resumed run. 1: one
    // file per task, as the files arrive.
    def per_job = (params.lastz_segments_per_job ?: 1) as int
    if (per_job < 1) {
        error "--lastz_segments_per_job must be 1 or more (got ${params.lastz_segments_per_job})"
    }
    def ch_tasks = ch_extend
    if (per_job > 1) {
        ch_tasks = ch_extend
            .map { meta, segment -> [ meta.query, meta.reference, segment ] }
            .groupTuple()
            .flatMap { q, refs, segments ->
                def files   = segments.sort { f -> f.name }
                def n_tasks = Math.ceil(files.size() / per_job) as int
                (0..<n_tasks).collect { i ->
                    def batch = (i..<files.size()).step(n_tasks).collect { k -> files[k] }
                    [ [ id: "batch${i + 1}of${n_tasks}".toString(), reference: refs[0], query: q ], batch ]
                }
            }
    }

    // Each task's segments ride with their own query's .2bit, sizes and chroms
    // dir; multiMap keeps the separate process inputs paired item for item.
    ch_lastz = ch_tasks
        .map { meta, segment -> [ meta.query, meta, segment ] }
        .combine( query_genomes, by: 0 )
        .multiMap { _q, meta, segment, twobit, sizes, chroms_dir ->
            segment:    [ meta, segment ]
            twobit:     twobit
            sizes:      sizes
            chroms_dir: chroms_dir
        }

    LASTZ_SEGMENTED(
        ch_lastz.segment,
        reference_twobit,
        ch_lastz.twobit,
        reference_chroms_dir,
        ch_lastz.chroms_dir,
        reference_sizes,
        ch_lastz.sizes,
        lastz_h,
        lastz_l,
        lastz_y
    )
    // Every completed task reports the segments files it ran (the script
    // stops unless it ran them all); the PSL output is optional (no
    // alignments, no file), so it cannot be the count.
    actual_n = LASTZ_SEGMENTED.out.n_segments.map { n -> n as int }.reduce(0) { a, b -> a + b }

    // Every partition must have run exactly once -- the same last-line
    // defence LASTZ_ALIGNMENT keeps over its NxK pair list.
    expected_n.combine( actual_n ).map { exp, got ->
        if (exp != got) {
            error "LASTZ partition integrity check failed: expected ${exp} " +
                  "LASTZ partitions, only ${got} completed. " +
                  "${exp - got} partition(s) were lost silently. " +
                  "Aborting before downstream chain building reads incomplete data."
        }
        log.info "lastZ partition integrity check passed: ${got}/${exp} partitions completed"
        return got
    }

    // psl/<chrom>/<id>.r<n>.psl.gz: the parent directory names the reference
    // chromosome. A glob output that matched one file arrives as a bare Path.
    ch_psl_by_chrom = LASTZ_SEGMENTED.out.psl
        .flatMap { meta, psl ->
            def chain_meta = [ id: "${meta.reference}.${meta.query}".toString(), query: meta.query ]
            [ psl ].flatten().collect { f -> [ chain_meta, f.parent.name, f ] }
        }

    emit:
    psl_by_chrom           = ch_psl_by_chrom
    chain_reference_twobit = chain_reference_twobit
    chain_query_prepared   = chain_query_prepared
    versions               = LASTZ_SEGMENTED.out.versions.mix( ch_versions )
}
