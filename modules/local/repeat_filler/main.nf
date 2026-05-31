/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    REPEAT_FILLER — Fill gaps in one chain chunk using chain_gap_filler.py,
    then re-score and re-sort.
    Equivalent to one job in the fill-chains Nextflow step of the original pipeline.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process REPEAT_FILLER {
    tag "$chain_chunk.name"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' : 
        'ghcr.io/hillerlab/repeat_filler:latest' }"

    input:
    path chain_chunk         // one infill_chain_N file
    path target_twobit
    path query_twobit
    val  chain_min_score
    val  fill_gap_max_size_t
    val  fill_gap_max_size_q
    val  fill_insert_chain_min_score
    val  fill_gap_min_size_t
    val  fill_gap_min_size_q
    val  fill_lastz_k
    val  fill_lastz_l
    val  chain_linear_gap
    val  skip_fill_unmask

    output:
    path "${chain_chunk.name}.filled.chain", emit: filled_chain
    path "versions.yml",                      emit: versions

    script:
    def unmask_arg = skip_fill_unmask ? '' : '--unmask'
    def out_chain  = "${chain_chunk.name}.filled.chain"
    """
    repeat_filler \\
        --chain ${chain_chunk} \\
        --T2bit ${target_twobit} \\
        --Q2bit ${query_twobit} \\
        --workdir ./ \\
        --chainMinScore ${chain_min_score} \\
        --gapMaxSizeT ${fill_gap_max_size_t} \\
        --gapMaxSizeQ ${fill_gap_max_size_q} \\
        --scoreThreshold ${fill_insert_chain_min_score} \\
        --gapMinSizeT ${fill_gap_min_size_t} \\
        --gapMinSizeQ ${fill_gap_min_size_q} \\
        --lastzParameters "K=${fill_lastz_k} L=${fill_lastz_l}" \\
        --verbose \\
        ${unmask_arg} > ${out_chain}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        python: \$(python --version 2>&1 | awk '{print \$2}')
        axtChain: 482
        chainSort: 482
    END_VERSIONS
    """

    stub:
    def out_chain  = "${chain_chunk.name}.filled.chain"
    """
    touch ${out_chain}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        python: \$(python --version 2>&1 | awk '{print \$2}')
        axtChain: 482
        chainSort: 482
    END_VERSIONS
    """
}
