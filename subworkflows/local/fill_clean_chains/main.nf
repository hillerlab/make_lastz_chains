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

include { FILL_CHAIN_SPLIT  } from '../../../modules/local/fill_chain_split/main'
include { REPEAT_FILLER     } from '../../../modules/local/repeat_filler/main'
include { FILL_CHAIN_MERGE  } from '../../../modules/local/fill_chain_merge/main'
include { CHAIN_CLEANER     } from '../../../modules/local/chain_cleaner/main'
include { CHAIN_FILTER      } from '../../../modules/local/chain_filter/main'

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
        FILL_CHAIN_SPLIT (
            merged_chain,
            params.num_fill_jobs
        )
        ch_versions = ch_versions.mix(FILL_CHAIN_SPLIT.out.versions)

        REPEAT_FILLER (
            FILL_CHAIN_SPLIT.out.chain_chunks.flatten(),
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
            params.lastz_path
        )
        ch_versions = ch_versions.mix(REPEAT_FILLER.out.versions)

        FILL_CHAIN_MERGE (
            REPEAT_FILLER.out.filled_chain.collect(),
            target_name,
            query_name
        )
        ch_versions = ch_versions.mix(FILL_CHAIN_MERGE.out.versions)

        ch_chain_for_clean = FILL_CHAIN_MERGE.out.filled_chain
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
        ch_versions = ch_versions.mix(CHAIN_CLEANER.out.versions)

        CHAIN_FILTER (
            CHAIN_CLEANER.out.cleaned_chain,
            params.min_chain_score,
            target_name,
            query_name
        )
        ch_versions = ch_versions.mix(CHAIN_FILTER.out.versions)

        ch_final = CHAIN_FILTER.out.final_chain
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
