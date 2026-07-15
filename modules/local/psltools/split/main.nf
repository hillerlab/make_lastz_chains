/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PSLTOOLS_SPLIT — Split PSL files into multiple PSL files.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process PSLTOOLS_SPLIT {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/alejandrogzi/psltools:latest' }"

    input:
    tuple val(meta), path(psl)

    output:
    tuple val(meta), path("*.psl")       , optional: true, emit: psl
    tuple val(meta), path("*.psl.gz")    , optional: true, emit: psl_gz
    path "versions.yml"                  , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args ?: ''
    def prefix    = task.ext.prefix ?: "${meta.id}"
    """
    ls *.psl > psl.list

    psltools split \\
        $args \\
        --file psl.list \\
        --by reference

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        psltools: \$( psltools --version | sed 's/psltools //g' )
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch *.psl
    touch *.psl.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        psltools: \$( psltools --version | sed 's/psltools //g' )
    END_VERSIONS
    """
}
