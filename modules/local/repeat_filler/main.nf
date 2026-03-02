/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    REPEAT_FILLER — Fill gaps in one chain chunk using chain_gap_filler.py,
    then re-score and re-sort.
    Equivalent to one job in the fill-chains Nextflow step of the original pipeline.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process REPEAT_FILLER {
    tag "$chain_chunk.name"
    label 'process_single'

    errorStrategy 'retry'
    maxRetries    3

    // TODO: conda "bioconda::lastz bioconda::ucsc-axtchain bioconda::ucsc-chainscore bioconda::ucsc-chainsort conda-forge::python=3.10"
    // TODO: container 'path/to/repeat_filler.sif'

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
    val  lastz_path

    output:
    path "${chain_chunk.name}.filled.chain", emit: filled_chain
    path "versions.yml",                      emit: versions

    script:
    def unmask_arg = skip_fill_unmask ? '' : '--unmask'
    def out_chain  = "${chain_chunk.name}.filled.chain"
    """
    chain_gap_filler.py \\
        --chain ${chain_chunk} \\
        --T2bit ${target_twobit} \\
        --Q2bit ${query_twobit} \\
        --workdir ./ \\
        --lastz ${lastz_path} \\
        --axtChain axtChain \\
        --chainSort chainSort \\
        --chainMinScore ${chain_min_score} \\
        --gapMaxSizeT ${fill_gap_max_size_t} \\
        --gapMaxSizeQ ${fill_gap_max_size_q} \\
        --scoreThreshold ${fill_insert_chain_min_score} \\
        --gapMinSizeT ${fill_gap_min_size_t} \\
        --gapMinSizeQ ${fill_gap_min_size_q} \\
        --lastzParameters "K=${fill_lastz_k} L=${fill_lastz_l}" \\
        ${unmask_arg} \\
    | chainScore \\
        -linearGap=${chain_linear_gap} \\
        stdin \\
        ${target_twobit} \\
        ${query_twobit} \\
        stdout \\
    | chainSort stdin ${out_chain}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
