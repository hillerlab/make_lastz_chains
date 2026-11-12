/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    AXT_CHAIN — Convert PSL alignments to chains.
    Runs axtChain on one PSL bundle: the bundle's files (plain PSL from
    PSLTOOLS_SPLIT, or gzipped PSL from LASTZ_SEGMENTED) are streamed into it
    in bundle order, so no concatenated copy is ever written.
    Optional substitution score matrix (lastz_q) is supported.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process AXT_CHAIN {
    tag "${meta.id}:${bundle}"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-axtchain:482--h0b57e2e_2' :
        'quay.io/biocontainers/ucsc-axtchain:482--h0b57e2e_2' }"

    input:
    tuple val(meta), val(bundle), path(psl, stageAs: 'psl/*')  // bundle.N and its PSL files, in bundle order
    path target_twobit
    path query_twobit
    val  min_chain_score
    val  chain_linear_gap
    val  lastz_q             // path to score matrix file, or empty string ''

    output:
    tuple val(meta), path("*.chain"), emit: chain
    path "versions.yml",              emit: versions

    script:
    def matrix_arg = lastz_q ? "-scoreScheme=${lastz_q}" : ''
    // One line, single-quoted names: a loop is not bound by ARG_MAX, and a
    // multi-line list would defeat Nextflow's script indentation stripping.
    def psl_list = [ psl ].flatten().collect { "'${it}'" }.join(' ')
    """
    for f in ${psl_list}; do
        case "\$f" in
            *.gz) gzip -dc "\$f" ;;
            *)    cat "\$f" ;;
        esac
    done \\
    | axtChain \\
        -psl \\
        -verbose=0 \\
        -minScore=${min_chain_score} \\
        -linearGap=${chain_linear_gap} \\
        ${matrix_arg} \\
        /dev/stdin \\
        ${target_twobit} \\
        ${query_twobit} \\
        ${bundle}.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-axtchain: \$(axtChain 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
