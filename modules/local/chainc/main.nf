/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAINC — Remove chain-breaking alignments using chain/net files.
    A Rust implementation of UCSC chainCleaner. When no NET is supplied the chains
    are netted in memory, so --net (and the size files) are optional.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAINC {
    tag "$meta.id"
    label 'process_medium'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/hillerlab/chainc:latest' }"

    input:
    tuple val(meta), path(chain), path(net)
    path reference
    path query
    path reference_sizes
    path query_sizes
    val  chain_linear_gap

    output:
    tuple val(meta), path("*.chain")              , emit: chain
    tuple val(meta), path("*.removed.bed")        , emit: removed_bed
    tuple val(meta), path("*.new_chain_ids.txt")  , emit: new_chain_ids
    path "versions.yml"                            , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def net_arg = net ? "--net $net" : ''
    def ref_sizes = reference_sizes ? "--reference-sizes $reference_sizes" : ''
    def qry_sizes = query_sizes ? "--query-sizes $query_sizes" : ''
    """
    chainc \\
        --chains $chain \\
        $net_arg \\
        --reference $reference \\
        --query $query \\
        --output ${prefix}.chain \\
        --removed-bed ${prefix}.removed.bed \\
        --new-chain-id-dict ${prefix}.new_chain_ids.txt \\
        --linear-gap $chain_linear_gap \\
        $ref_sizes \\
        $qry_sizes \\
        --threads $task.cpus \\
        $args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chainc: \$(chainc --version | sed 's/chainc //g')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.chain
    touch ${prefix}.removed.bed
    touch ${prefix}.new_chain_ids.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chainc: \$(chainc --version | sed 's/chainc //g')
    END_VERSIONS
    """
}
