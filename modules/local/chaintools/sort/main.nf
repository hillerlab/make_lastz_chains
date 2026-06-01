/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAINTOOLS_SORT — Sort chains by chain score/target/query.
    Sorts input chains by chain score/target/query according to the 
    specified sort order. Output is a sorted chain file.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAINTOOLS_SORT {
    tag "$chain.baseName"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/alejandrogzi/chaintools:latest' }"

    input:
    tuple val(meta), path(chain)

    output:
    tuple val(meta), path("*.sorted.chain")       , optional: true, emit: chain
    tuple val(meta), path("*.sorted.chain.gz")    , optional: true, emit: chain_gz
    path "versions.yml"                           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args ?: ''
    def prefix    = task.ext.prefix ?: "${chain.baseName}"
    """
    chaintools sort \\
        $args \\
        --chain $chain \\
        --threads ${task.cpus} \\
        --out-chain ${prefix}.sorted.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${chain.baseName}"
    """
    touch ${prefix}.sorted.chain
    touch ${prefix}.sorted.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """
}
