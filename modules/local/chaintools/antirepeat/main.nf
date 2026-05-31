/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAINTOOLS_ANTIREPEAT — Remove chains that are primiarily the result of
    repeats of degenerated DNA. Output is a suffixed .clean.chain file.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAINTOOLS_ANTIREPEAT {
    tag "$chain.baseName"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/alejandrogzi/chaintools:latest' }"

    input:
    path chain
    path reference
    path query

    output:
    path("*.clean.chain")       , optional: true, emit: chain
    path("*.clean.chain.gz")    , optional: true, emit: chain_gz
    path "versions.yml"                             , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args ?: ''
    def prefix    = task.ext.prefix ?: "${chain.baseName}"
    """
    chaintools antirepeat \\
        $args \\
        --chain $chain \\
        --reference $reference \\
        --query $query \\
        --threads ${task.cpus} \\
        --out-chain ${prefix}.clean.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${chain.baseName}"
    """
    touch ${prefix}.clean.chain
    touch ${prefix}.clean.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chaintools: \$( chaintools --version | sed 's/chaintools //g' )
    END_VERSIONS
    """
}
