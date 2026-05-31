/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHROMSIZE — Generate chromosome size files from genome FASTA.
    Extracts sequence lengths from a FASTA genome and outputs a chrom.sizes
    file required by many UCSC tools.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHROMSIZE {
    tag "$genome"
    label 'process_low'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' : 
        'ghcr.io/alejandrogzi/chromsize:latest' }"

    input:
    tuple val(genome_name), path(genome)

    output:
    tuple val(genome_name), path("${genome_name}/${genome_name}.chrom.sizes"), emit: chrom_sizes
    path "versions.yml"           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: genome_name
    """
    chromsize \\
        $args \\
        -s $genome \\
        -o ${prefix}

    mv ${prefix}/chrom.sizes ${prefix}/${prefix}.chrom.sizes
        
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chromsize: \$(chromsize --version | sed -e "s/chromsize v//g")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${genome_name}"
    """
    touch ${prefix}
    touch ${prefix}/${prefix}.chrom.sizes

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        chromsize: \$(chromsize --version | sed -e "s/chromsize v//g")
    END_VERSIONS
    """
}
