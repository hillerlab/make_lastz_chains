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

include { PARTITION } from '../../../modules/local/partition/main'
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

    main:
    // ── Partition ───────────────────────────────────────────────────────────
    PARTITION (
        target_prepared,
        'target',
        params.seq1_chunk,
        params.seq1_lap
    )
    PARTITION (
        query_prepared,
        'query',
        params.seq2_chunk,
        params.seq2_lap
    )

    // ── Emit individual partition strings as channel items ──────────────────
    target_parts_ch = PARTITION.out.partitions
        .map { _name, part_file -> part_file }
        .first()          // only one target partition file
        .splitText()      // one line per channel item
        .map { it.trim() }
        .filter { it }    // drop empty lines

    query_parts_ch = PARTITION.out.partitions
        .map { _name, part_file -> part_file }
        .last()           // only one query partition file
        .splitText()
        .map { it.trim() }
        .filter { it }

    // ── Cross-product N×K pairs ─────────────────────────────────────────────
    pairs_ch = target_parts_ch.combine(query_parts_ch)
    // pairs_ch emits: (target_partition_str, query_partition_str)

    // ── LASTZ alignment ─────────────────────────────────────────────────────
    target_twobit_ch     = target_prepared.map { _n, tb, _cs -> tb }
    query_twobit_ch      = query_prepared.map  { _n, tb, _cs -> tb }
    target_chrom_sz_ch   = target_prepared.map { _n, _tb, cs -> cs }
    query_chrom_sz_ch    = query_prepared.map  { _n, _tb, cs -> cs }

    LASTZ (
        pairs_ch,
        target_twobit_ch.first(),
        query_twobit_ch.first(),
        target_chrom_sz_ch.first(),
        query_chrom_sz_ch.first(),
        params.lastz_k,
        params.lastz_h,
        params.lastz_l,
        params.lastz_y,
        params.axt_to_psl_path
    )

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
    versions = PARTITION.out.versions.mix(LASTZ.out.versions, CAT_PSL.out.versions)
}
