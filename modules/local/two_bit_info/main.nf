/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    TWO_BIT_INFO — Generate chrom.sizes from a .2bit genome file
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process TWO_BIT_INFO {
    tag "$genome_name"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-twobitinfo:482--hdc0a859_0' :
        'quay.io/biocontainers/ucsc-twobitinfo:482--hdc0a859_0' }"

    input:
    tuple val(genome_name), path(twobit)

    output:
    tuple val(genome_name), path("${genome_name}.chrom.sizes"), emit: chrom_sizes
    path "versions.yml",                                          emit: versions

    script:
    """
    twoBitInfo ${twobit} ${genome_name}.chrom.sizes

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-twobitinfo: \$(twoBitInfo 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
