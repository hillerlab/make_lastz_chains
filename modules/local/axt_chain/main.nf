/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    AXT_CHAIN — Convert PSL alignments to chains.
    Runs axtChain piped through chainAntiRepeat for one PSL bundle.
    Optional substitution score matrix (lastz_q) is supported.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process AXT_CHAIN {
    tag "$bundle_psl.name"
    label 'process_medium'


    // TODO: conda "bioconda::ucsc-axtchain=377 bioconda::ucsc-chainantirepeat=377"
    // TODO: container 'path/to/ucsc_tools.sif'

    input:
    path bundle_psl          // one bundle.N.psl file
    path target_twobit
    path query_twobit
    val  min_chain_score
    val  chain_linear_gap
    val  lastz_q             // path to score matrix file, or empty string ''

    output:
    path "*.chain",      emit: chain
    path "versions.yml", emit: versions

    script:
    def out_chain = "${bundle_psl.baseName}.chain"
    def matrix_arg = lastz_q ? "-scoreScheme=${lastz_q}" : ''
    """
    axtChain \\
        -psl \\
        -verbose=0 \\
        -minScore=${min_chain_score} \\
        -linearGap=${chain_linear_gap} \\
        ${matrix_arg} \\
        ${bundle_psl} \\
        ${target_twobit} \\
        ${query_twobit} \\
        stdout \\
    | chainAntiRepeat \\
        ${target_twobit} \\
        ${query_twobit} \\
        stdin \\
        ${out_chain}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-axtchain: \$(axtChain 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
