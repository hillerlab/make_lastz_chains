/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    TWO_BIT_INFO — Generate chrom.sizes from a .2bit genome file
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process TWO_BIT_INFO {
    tag "$genome_name"
    label 'process_single'

    // TODO: conda "bioconda::ucsc-twobitinfo=377"
    // TODO: container 'path/to/ucsc_tools.sif'

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
