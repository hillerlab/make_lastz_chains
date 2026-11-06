/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_ALIGNMENT subworkflow
    1. Partition reference and query genomes into chunks
    2. Create N×K alignment pairs via channel.combine()
    3. Run LASTZ on each pair in parallel
    4. Collect all PSL outputs into a single channel

    5. --window_masking_recovery: re-run the pairs whose anchors overflowed lastz
       (unmasked satellite arrays of close species) with WindowMasker + sdust
       added to both genomes, each split 5x5 (a BULK bin's chromosomes are split
       too) — what the old Hiller lab pipeline did for its crashed jobs. As there,
       the masked genomes then replace the originals for every later step.
       Without an overflow nothing changes.

    Emits: psl_gz — all .psl files ready for chromosome split/bundle
           chain_reference_twobit / chain_query_prepared — the genomes the later
           steps read: the WindowMasker-masked ones after a recovery, else the
           originals
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PARTITION as PARTITION_REFERENCE } from '../../../modules/local/partition/main'
include { PARTITION as PARTITION_QUERY  } from '../../../modules/local/partition/main'
include { LASTZ                            } from '../../../modules/local/lastz/main'
include { LASTZ as LASTZ_RECOVER           } from '../../../modules/local/lastz/main'
include { TWO_BIT_TO_FA as REFERENCE_TO_FA } from '../../../modules/local/two_bit_to_fa/main'
include { TWO_BIT_TO_FA as QUERY_TO_FA     } from '../../../modules/local/two_bit_to_fa/main'
include { WINDOWMASKER as WINDOWMASKER_REFERENCE } from '../../../modules/local/windowmasker/main'
include { WINDOWMASKER as WINDOWMASKER_QUERY     } from '../../../modules/local/windowmasker/main'
include { MASK_GENOME as MASK_GENOME_REFERENCE   } from '../../../modules/local/mask_genome/main'
include { MASK_GENOME as MASK_GENOME_QUERY       } from '../../../modules/local/mask_genome/main'
include { MASKED_CHROMS as MASKED_CHROMS_REFERENCE } from '../../../modules/local/masked_chroms/main'
include { MASKED_CHROMS as MASKED_CHROMS_QUERY     } from '../../../modules/local/masked_chroms/main'

// Chromosomes named by a partition string: '<2bit>:<chrom>:<start>-<end>', or
// 'BULK_<n>:<2bit>:<chrom>:<chrom>...' for bins of small scaffolds.
def partitionChroms(String part) {
    def fields = part.split(':')
    return part.startsWith('BULK') ? fields[2..-1] : [ fields[1] ]
}

// A ranged partition cut into n consecutive ranges, each extended by `lap` bp
// (the partition overlap).
def splitRange(String part, int n, long lap) {
    def (twobit, chrom, range) = part.split(':')
    def (start, end) = range.split('-').collect { it as long }
    long step = Math.max(1L, (long) Math.ceil((end - start) / (double) n))
    def pieces = []
    for (long a = start; a < end; a += step) {
        pieces << "${twobit}:${chrom}:${a}-${Math.min(end, a + step + lap)}".toString()
    }
    return pieces
}

// A partition cut into about n pieces for a recovery re-run. A BULK bin (every
// chromosome under 45% of the chunk size, so most chromosomes at the 175 Mb
// default) is expanded: chromosomes longer than 1/n of the bin are cut into
// pieces of that length, and the shorter ones stay together as one bin.
def splitPartition(String part, int n, long lap, Map sizes) {
    if (!part.startsWith('BULK')) return splitRange(part, n, lap)
    def fields = part.split(':')
    def twobit = fields[1]
    def chroms = fields[2..-1]
    long piece = Math.max(1L, (long) Math.ceil(chroms.sum { sizes[it] as long } / (double) n))
    def pieces = []
    def small  = []
    chroms.each { c ->
        long len = sizes[c] as long
        if (len > piece) pieces += splitRange("${twobit}:${c}:0-${len}".toString(), (int) Math.ceil(len / (double) piece), lap)
        else small << c
    }
    if (small) pieces << "${fields[0]}r:${twobit}:${small.join(':')}".toString()
    return pieces
}

def readSizes(path) {
    path.readLines().findAll { it.trim() }.collectEntries { l -> def f = l.split('\t'); [ (f[0]): f[1] as long ] }
}

workflow LASTZ_ALIGNMENT {
    take:
    reference_prepared    // tuple: (reference_name, reference_twobit, reference_chrom_sizes)
    query_prepared        // tuple: (query_name,  query_twobit,  query_chrom_sizes)
    reference_chroms_dir  // tuple: (reference_name, dir/) — pre-extracted v1 FASTAs
    query_chroms_dir      // tuple: (query_name,  dir/) — pre-extracted v1 FASTAs

    main:
    // ── Partition ───────────────────────────────────────────────────────────
    PARTITION_REFERENCE (
        reference_prepared,
        'reference',
        params.seq1_chunk,
        params.seq1_lap
    )
    PARTITION_QUERY (
        query_prepared,
        'query',
        params.seq2_chunk,
        params.seq2_lap
    )

    // ── Emit individual partition strings as channel items ──────────────────
    reference_parts_ch = PARTITION_REFERENCE.out.partitions
        .map { _name, part_file -> part_file }
        .splitText()      // one line per channel item
        .map { it.trim() }
        .filter { it }    // drop empty lines

    query_parts_ch = PARTITION_QUERY.out.partitions
        .map { _name, part_file -> part_file }
        .splitText()
        .map { it.trim() }
        .filter { it }

    // ── Cross-product N×K pairs ─────────────────────────────────────────────
    // Materialise the full pair list so we can both count it (for the
    // post-LASTZ integrity check) and feed it to LASTZ without consuming the
    // channel twice.
    pairs_list  = reference_parts_ch.combine(query_parts_ch).collect(flat: false)
    expected_n  = pairs_list.map { it.size() }
    pairs_ch    = pairs_list.flatMap { it }
    // pairs_ch emits: (reference_partition_str, query_partition_str)

    // ── LASTZ alignment ─────────────────────────────────────────────────────
    reference_twobit_ch       = reference_prepared.map { _n, tb, _cs -> tb }
    reference_chrom_sz_ch     = reference_prepared.map { _n, _tb, cs -> cs }
    reference_chroms_dir_ch   = reference_chroms_dir.map { _n, d -> d }
    reference_name            = reference_prepared.map { n, _tb, _cs -> n.toString() }

    query_twobit_ch        = query_prepared.map  { _n, tb, _cs -> tb }
    query_chrom_sz_ch      = query_prepared.map  { _n, _tb, cs -> cs }
    query_chroms_dir_ch    = query_chroms_dir.map  { _n, d -> d }
    query_name             = query_prepared.map  { n, _tb, _cs -> n.toString() }

    LASTZ (
        pairs_ch,
        reference_twobit_ch.first(),
        query_twobit_ch.first(),
        reference_chrom_sz_ch.first(),
        query_chrom_sz_ch.first(),
        reference_chroms_dir_ch.first(),
        query_chroms_dir_ch.first(),
        params.lastz_k,
        params.lastz_h,
        params.lastz_l,
        params.lastz_y,
    )

    // ── Integrity check: every expected pair must have completed ───────────
    // versions.yml is emitted by every successful LASTZ task (no `optional`),
    // so its count equals the number of tasks that ran to completion. With
    // the strict errorStrategy in nextflow.config, a permanently-failed task
    // already aborts the workflow before reaching this point; this assertion
    // is the last-line defence against a Nextflow channel bug or a process
    // that exits 0 without writing versions.yml.
    actual_n = LASTZ.out.versions.count()
    expected_n.combine( actual_n ).map { exp, got ->
        if (exp != got) {
            error "LASTZ integrity check failed: expected ${exp} alignment tasks, " +
                  "only ${got} produced output. ${exp - got} pair(s) were lost silently. " +
                  "Aborting before downstream chain building reads incomplete data."
        }
        log.info "LASTZ integrity check passed: ${got}/${exp} pair tasks completed"
        return got
    }

    ch_lastz_psl = LASTZ.out.psl
    ch_versions  = PARTITION_REFERENCE.out.versions.mix(PARTITION_QUERY.out.versions, LASTZ.out.versions)

    // ── --window_masking_recovery: masked 5x5 re-run of overflowed pairs ────
    // Nothing below runs unless a LASTZ job overflowed (collect() of an empty
    // channel emits nothing), so a pair that never overflows pays nothing.
    if (params.window_masking_recovery) {
        ch_overflow = LASTZ.out.overflow.map { rp, qp, _marker -> [ rp, qp ] }
        ch_any      = ch_overflow.collect(flat: false)

        ch_any.subscribe { pairs ->
            log.warn "window_masking_recovery: ${pairs.size()} LASTZ partition pair(s) overflowed lastz's anchor " +
                     "table; re-running them with WindowMasker + sdust masking, each split 5x5"
        }

        REFERENCE_TO_FA ( reference_prepared.combine( ch_any.map { 1 } ).map { n, tb, _cs, _x -> [ n, tb ] } )
        QUERY_TO_FA     ( query_prepared.combine( ch_any.map { 1 } ).map { n, tb, _cs, _x -> [ n, tb ] } )
        WINDOWMASKER_REFERENCE ( REFERENCE_TO_FA.out.fasta )
        WINDOWMASKER_QUERY     ( QUERY_TO_FA.out.fasta )

        // The genomes with WindowMasker + sdust added; per-chromosome FASTAs of
        // them for the overflowed pairs' chromosomes only.
        MASK_GENOME_REFERENCE (
            reference_prepared.map { n, tb, _cs -> [ n, tb ] }.join( WINDOWMASKER_REFERENCE.out.bed )
        )
        MASK_GENOME_QUERY (
            query_prepared.map { n, tb, _cs -> [ n, tb ] }.join( WINDOWMASKER_QUERY.out.bed )
        )
        MASKED_CHROMS_REFERENCE (
            MASK_GENOME_REFERENCE.out.twobit
                .combine( ch_any.map { pairs -> [ pairs.collectMany { partitionChroms(it[0]) }.unique().sort() ] } )
        )
        MASKED_CHROMS_QUERY (
            MASK_GENOME_QUERY.out.twobit
                .combine( ch_any.map { pairs -> [ pairs.collectMany { partitionChroms(it[1]) }.unique().sort() ] } )
        )

        ch_sub_pairs = ch_overflow
            .combine( reference_chrom_sz_ch )
            .combine( query_chrom_sz_ch )
            .flatMap { rp, qp, rsizes, qsizes ->
                def refs = splitPartition(rp, 5, params.seq1_lap as long, readSizes(rsizes))
                def qrys = splitPartition(qp, 5, params.seq2_lap as long, readSizes(qsizes))
                [ refs, qrys ].combinations()
            }

        // Same module, without ext.mark_overflow: a masked sub-pair that still
        // overflows fails the run with the masking hint.
        LASTZ_RECOVER (
            ch_sub_pairs,
            reference_twobit_ch.first(),
            query_twobit_ch.first(),
            reference_chrom_sz_ch.first(),
            query_chrom_sz_ch.first(),
            MASKED_CHROMS_REFERENCE.out.chroms_dir.map { _n, d -> d }.first(),
            MASKED_CHROMS_QUERY.out.chroms_dir.map { _n, d -> d }.first(),
            params.lastz_k,
            params.lastz_h,
            params.lastz_l,
            params.lastz_y,
        )

        ch_lastz_psl = ch_lastz_psl.mix( LASTZ_RECOVER.out.psl )
        ch_versions  = ch_versions.mix(
            REFERENCE_TO_FA.out.versions, QUERY_TO_FA.out.versions,
            WINDOWMASKER_REFERENCE.out.versions, WINDOWMASKER_QUERY.out.versions,
            MASK_GENOME_REFERENCE.out.versions, MASK_GENOME_QUERY.out.versions,
            MASKED_CHROMS_REFERENCE.out.versions, MASKED_CHROMS_QUERY.out.versions,
            LASTZ_RECOVER.out.versions
        )

        // After a recovery the masked genomes replace the originals for every
        // later step, as in the old pipeline; 'NONE' when nothing overflowed.
        // Waiting on it costs nothing: chain building needs every LASTZ job anyway.
        ch_masked_ref = MASK_GENOME_REFERENCE.out.twobit.map { _n, tb -> tb }.ifEmpty('NONE')
        ch_masked_qry = MASK_GENOME_QUERY.out.twobit.map { _n, tb -> tb }.ifEmpty('NONE')
        chain_reference_twobit = reference_twobit_ch
            .combine( ch_masked_ref )
            .map { tb, masked -> masked == 'NONE' ? tb : masked }
            .first()
        chain_query_prepared = query_prepared
            .combine( ch_masked_qry )
            .map { n, tb, cs, masked -> [ n, masked == 'NONE' ? tb : masked, cs ] }
    }
    else {
        chain_reference_twobit = reference_twobit_ch.first()
        chain_query_prepared   = query_prepared
    }

    // ── Collect all PSL files into a single channel ───────────────────────────────────
    // Feed LASTZ's raw per-partition PSLs straight to the chromosome split/bundle step:
    // PSLTOOLS_SPLIT --by reference already consolidates across query partitions, and
    // axtChain sorts its block list internally, so the per-bucket PSLTOOLS_MERGE was
    // redundant (one extra full pass over all alignment data).
    ch_psl_files = ch_lastz_psl
        .map { reference_part, psl -> psl }
        .collect()
        .map { psl_files -> [psl_files] }
        .combine(reference_name)
        .combine(query_name)
        .map { psl_files, ref, query ->
            [ [ id: "${ref}.${query}".toString(), query: query ], psl_files ]
        }

    emit:
    psl_gz                 = ch_psl_files
    chain_reference_twobit = chain_reference_twobit
    chain_query_prepared   = chain_query_prepared
    versions               = ch_versions
}
