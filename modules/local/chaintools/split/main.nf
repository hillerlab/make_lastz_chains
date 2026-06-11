/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAINTOOLS_SPLIT — Split chains into multiple chain files/chunks.
    Splits input chains into multiple chain files/chunks according to the 
    specified number of chunks/files. Output is always under chains/ directory.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAINTOOLS_SPLIT {
    tag "$meta.id"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/alejandrogzi/chaintools:latest' }"

    input:
    tuple val(meta), path(chain)
    val  num_chunks

    output:
    tuple val(meta), path("chains/*.chain")        , optional: true, emit: chains
    tuple val(meta), path("chains/*.chain.gz")     , optional: true, emit: chains_gz
    path "versions.yml"                            , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args ?: ''
    """
    chaintools split \\
        $args \\
        --chain $chain \\
        --files $num_chunks \\
        --outdir . \\
        --randomize \\
        --threads ${task.cpus}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """

    stub:
    """
    touch chains/*.chain
    touch chains/*.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """
}
