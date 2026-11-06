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

    Emits: psl_by_chrom — (meta(id, query), reference chromosome, psl.gz), one
           item per file, the CHAIN_BUILD input that skips PSLTOOLS_SPLIT.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { LASTZ_SEGMENTED } from '../../../modules/local/lastz_segmented/main'

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
    expected_n = ch_segments.count()

    // Each segments file rides with its own query's .2bit, sizes and chroms
    // dir; multiMap keeps the separate process inputs paired item for item.
    ch_lastz = ch_segments
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
    // versions.yml is written by every task that completed; the PSL output is
    // optional (no alignments, no file), so it cannot be the count.
    actual_n = LASTZ_SEGMENTED.out.versions.count()

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
    psl_by_chrom = ch_psl_by_chrom
    versions     = LASTZ_SEGMENTED.out.versions
}
