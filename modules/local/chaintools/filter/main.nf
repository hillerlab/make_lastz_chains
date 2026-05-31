/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAINTOOLS_FILTER — Filter chains by chain score/target/query.
    Filters input chains by chain score/target/query/gap/strand/id according 
    to the specified filter criteria. Output is a filtered chain file.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAINTOOLS_FILTER {
    tag "$meta.id"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/alejandrogzi/chaintools:latest' }"

    input:
    tuple val(meta), path(chain)
    val  min_chain_score

    output:
    tuple val(meta), path("*.chain")       , optional: true, emit: chain
    tuple val(meta), path("*.chain.gz")    , optional: true, emit: chain_gz
    path "versions.yml"                             , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args ?: ''
    def prefix    = task.ext.prefix ?: "${meta.id}.filtered"
    """
    chaintools filter \\
        $args \\
        --chain $chain \\
        --threads ${task.cpus} \\
        --min-score ${min_chain_score} \\
        --gzip \\
        --out-chain ${prefix}.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.chain
    touch ${prefix}.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """
}
