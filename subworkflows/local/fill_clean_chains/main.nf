/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_CLEAN_CHAINS subworkflow
    Optionally fills gaps in chains and optionally cleans weak chains.

    Steps (both conditional on params flags):
    1. FILL_CHAIN_SPLIT  — split merged chain into N parts
    2. REPEAT_FILLER     — fill gaps in each part in parallel
    3. FILL_CHAIN_MERGE  — merge filled parts
    4. CHAIN_CLEANER     — remove suspicious chains
    5. CHAIN_FILTER      — apply minimum score filter → final.chain.gz

    Emits: final_chain — *.final.chain.gz
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { REPEAT_FILLER     } from '../../../modules/local/repeat_filler/main'
include { FILL_CHAIN_MERGE  } from '../../../modules/local/fill_chain_merge/main'
include { CHAIN_CLEANER     } from '../../../modules/local/chain_cleaner/main'
include { CHAIN_FILTER      } from '../../../modules/local/chain_filter/main'
include { CHAINTOOLS_SPLIT  } from '../../../modules/local/chaintools/split/main'
include { CHAINTOOLS_SCORE  } from '../../../modules/local/chaintools/score/main'
include { CHAINTOOLS_MERGE as CHAINTOOLS_MERGE_FILLED_CHAINS } from '../../../modules/local/chaintools/merge/main'

workflow FILL_CLEAN_CHAINS {
    take:
    merged_chain        // path: *.all.chain.gz
    target_twobit       // path
    query_twobit        // path
    target_chrom_sizes  // path
    query_chrom_sizes   // path
    target_name         // val
    query_name          // val

    main:
    ch_versions = Channel.empty()

    // ── Fill chains (optional) ──────────────────────────────────────────────
    if (!params.skip_fill_chains) {
        CHAINTOOLS_SPLIT (
            merged_chain,
            params.num_fill_jobs
        )

        CHAINTOOLS_SPLIT.out.chains
        .map { meta, chains -> chains }
        .flatten()
        .set { ch_chains_to_fill }

        REPEAT_FILLER (
            ch_chains_to_fill,
            target_twobit,
            query_twobit,
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

        CHAINTOOLS_SCORE (
            REPEAT_FILLER.out.filled_chain,
            target_twobit,
            query_twobit
        )

        CHAINTOOLS_MERGE_FILLED_CHAINS (
            CHAINTOOLS_SCORE.out.chain
              .collect()
              .map { chains -> [ [ id: target_name + '.' + query_name + '.filled' ], chains ] }
        )

        ch_chain_for_clean = CHAINTOOLS_MERGE_FILLED_CHAINS.out.chain

        ch_versions = ch_versions.mix(CHAINTOOLS_SPLIT.out.versions)
        ch_versions = ch_versions.mix(REPEAT_FILLER.out.versions)
        ch_versions = ch_versions.mix(CHAINTOOLS_MERGE_FILLED_CHAINS.out.versions)
        ch_versions = ch_versions.mix(CHAINTOOLS_SCORE.out.versions)
    } else {
        ch_chain_for_clean = merged_chain
    }

    // ── Clean chains (optional) ─────────────────────────────────────────────
    if (!params.skip_clean_chain) {
        CHAIN_CLEANER (
            ch_chain_for_clean,
            target_twobit,
            query_twobit,
            target_chrom_sizes,
            query_chrom_sizes,
            params.chain_linear_gap,
            params.clean_chain_parameters
        )

        CHAIN_FILTER (
            CHAIN_CLEANER.out.cleaned_chain,
            params.min_chain_score,
            target_name,
            query_name
        )

        ch_final = CHAIN_FILTER.out.final_chain

        ch_versions = ch_versions.mix(CHAIN_CLEANER.out.versions)
        ch_versions = ch_versions.mix(CHAIN_FILTER.out.versions)
    } else {
        // If not cleaning, the output of the fill step is the final chain.
        // Rename for consistent output naming.
        ch_final = ch_chain_for_clean.map { chain_gz ->
            def final_name = "${target_name}.${query_name}.final.chain.gz"
            // Stage a copy with the final name
            [ chain_gz, final_name ]
        }
        // Simplify: just emit as-is; the workflow handles naming in main.nf
        ch_final = ch_chain_for_clean
    }

    emit:
    final_chain = ch_final
    versions    = ch_versions
}
