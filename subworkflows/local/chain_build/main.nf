/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_BUILD subworkflow
    1. PSL_SORT_ACC — sort all PSL files by target chromosome
    2. PSL_BUNDLE  — group sorted PSL files into chromosome bundles
    3. AXT_CHAIN   — convert each PSL bundle to chains (parallel)
    4. CHAIN_MERGE_SORT — merge all chain files into one compressed chain

    Emits: merged_chain — *.all.chain.gz
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { PSL_SORT_ACC     } from '../../../modules/local/psl_sort_acc/main'
include { PSL_BUNDLE       } from '../../../modules/local/psl_bundle/main'
include { AXT_CHAIN        } from '../../../modules/local/axt_chain/main'
include { CHAIN_MERGE_SORT } from '../../../modules/local/chain_merge_sort/main'

workflow CHAIN_BUILD {
    take:
    psl_gz_files        // channel of .psl.gz files from LASTZ_ALIGNMENT
    target_twobit       // path
    query_twobit        // path
    target_chrom_sizes  // path
    target_name         // val
    query_name          // val

    main:
    // ── Sort all PSL files by chromosome ───────────────────────────────────
    PSL_SORT_ACC (
        psl_gz_files.collect()
    )

    // ── Bundle sorted PSL files by chromosome for parallel axtChain ────────
    PSL_BUNDLE (
        PSL_SORT_ACC.out.sorted_psl_dir,
        target_chrom_sizes,
        params.bundle_psl_max_bases
    )

    // ── Run axtChain on each bundle in parallel ─────────────────────────────
    AXT_CHAIN (
        PSL_BUNDLE.out.bundles.flatten(),  // one channel item per bundle file
        target_twobit,
        query_twobit,
        params.min_chain_score,
        params.chain_linear_gap,
        params.lastz_q ?: ''
    )

    // ── Merge all chain files into one ─────────────────────────────────────
    CHAIN_MERGE_SORT (
        AXT_CHAIN.out.chain.collect(),
        target_name,
        query_name
    )

    emit:
    merged_chain = CHAIN_MERGE_SORT.out.merged_chain
    versions     = PSL_SORT_ACC.out.versions
                     .mix( PSL_BUNDLE.out.versions,
                           AXT_CHAIN.out.versions,
                           CHAIN_MERGE_SORT.out.versions )
}
