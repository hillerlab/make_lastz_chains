/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_ALIGNMENT subworkflow
    1. Partition target and query genomes into chunks
    2. Create N×K alignment pairs via channel.combine()
    3. Run LASTZ on each pair in parallel
    4. Group PSL outputs by target-partition bucket
    5. Concatenate + compress each bucket (CAT_PSL)

    Emits: psl_gz — all .psl.gz files ready for PSL_SORT_ACC
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PARTITION as PARTITION_TARGET } from '../../../modules/local/partition/main'
include { PARTITION as PARTITION_QUERY  } from '../../../modules/local/partition/main'
include { LASTZ     } from '../../../modules/local/lastz/main'
include { CAT_PSL   } from '../../../modules/local/cat_psl/main'

// Derive the bucket key from a target partition string.
// Regular: "target.2bit:chr1:0-175000000"  → "bucket_ref_chr1_in_0_175000000"
// Bulk:    "BULK_1:target.2bit:chr1:chr2"  → "bucket_ref_bulk_1"
def get_bucket_key(String partition) {
    if (partition.startsWith("BULK")) {
        def bulk_num = partition.split(":")[0].split("_")[1]
        return "bucket_ref_bulk_${bulk_num}"
    } else {
        def parts    = partition.split(":")
        def chrom    = parts[1]
        def startEnd = parts[2].split("-")
        return "bucket_ref_${chrom}_in_${startEnd[0]}_${startEnd[1]}"
    }
}

workflow LASTZ_ALIGNMENT {
    take:
    target_prepared    // tuple: (target_name, target_twobit, target_chrom_sizes)
    query_prepared     // tuple: (query_name,  query_twobit,  query_chrom_sizes)
    target_chroms_dir  // tuple: (target_name, dir/) — pre-extracted v1 FASTAs
    query_chroms_dir   // tuple: (query_name,  dir/) — pre-extracted v1 FASTAs

    main:
    // ── Partition ───────────────────────────────────────────────────────────
    PARTITION_TARGET (
        target_prepared,
        'target',
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
    target_parts_ch = PARTITION_TARGET.out.partitions
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
    pairs_list  = target_parts_ch.combine(query_parts_ch).collect(flat: false)
    expected_n  = pairs_list.map { it.size() }
    pairs_ch    = pairs_list.flatMap { it }
    // pairs_ch emits: (target_partition_str, query_partition_str)

    // ── LASTZ alignment ─────────────────────────────────────────────────────
    target_twobit_ch       = target_prepared.map { _n, tb, _cs -> tb }
    query_twobit_ch        = query_prepared.map  { _n, tb, _cs -> tb }
    target_chrom_sz_ch     = target_prepared.map { _n, _tb, cs -> cs }
    query_chrom_sz_ch      = query_prepared.map  { _n, _tb, cs -> cs }
    target_chroms_dir_ch   = target_chroms_dir.map { _n, d -> d }
    query_chroms_dir_ch    = query_chroms_dir.map  { _n, d -> d }

    LASTZ (
        pairs_ch,
        target_twobit_ch.first(),
        query_twobit_ch.first(),
        target_chrom_sz_ch.first(),
        query_chrom_sz_ch.first(),
        target_chroms_dir_ch.first(),
        query_chroms_dir_ch.first(),
        params.lastz_k,
        params.lastz_h,
        params.lastz_l,
        params.lastz_y,
        params.axt_to_psl_path
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

    // ── Group PSL outputs by target bucket, then CAT_PSL ───────────────────
    bucketed_ch = LASTZ.out.psl
        .map { target_part, psl_file ->
            def bucket = get_bucket_key(target_part)
            [ bucket, psl_file ]
        }
        .groupTuple()    // (bucket_key, [psl_file, psl_file, ...])

    CAT_PSL ( bucketed_ch )

    emit:
    psl_gz   = CAT_PSL.out.psl_gz     // all .psl.gz files for PSL_SORT_ACC
    versions = PARTITION_TARGET.out.versions.mix(PARTITION_QUERY.out.versions, LASTZ.out.versions, CAT_PSL.out.versions)
}
