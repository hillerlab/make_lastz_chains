/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAINTOOLS_SCORE — Remove chains that are primiarily the result of
    repeats of degenerated DNA. Output is a suffixed .scored.chain file.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAINTOOLS_SCORE {
    tag "$chain.baseName"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/alejandrogzi/chaintools:latest' }"

    input:
    path chain
    path reference
    path query

    output:
    path "*.scored.chain"       , optional: true, emit: chain
    path "*.scored.chain.gz"    , optional: true, emit: chain_gz
    path "versions.yml"         , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args ?: ''
    def prefix    = task.ext.prefix ?: "${chain.baseName}"
    """
    chaintools score \\
        $args \\
        --chain $chain \\
        --reference $reference \\
        --query $query \\
        --threads ${task.cpus} \\
        --sort-by-score \\
        --out-chain ${prefix}.scored.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${chain.baseName}"
    """
    touch ${prefix}.scored.chain
    touch ${prefix}.scored.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """
}
