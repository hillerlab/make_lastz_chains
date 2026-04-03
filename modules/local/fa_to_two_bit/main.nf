/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FA_TO_TWO_BIT — Convert FASTA genome to UCSC .2bit format
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process FA_TO_TWO_BIT {
    tag "$genome_name"
    label 'process_fast'

    // TODO: conda "bioconda::ucsc-fatotwobit=377"
    // TODO: container 'path/to/ucsc_tools.sif'

    input:
    tuple val(genome_name), path(genome_fa)

    output:
    tuple val(genome_name), path("${genome_name}.2bit"), emit: twobit
    path "versions.yml",                                  emit: versions

    script:
    """
    faToTwoBit -long ${genome_fa} ${genome_name}.2bit

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-fatotwobit: \$(faToTwoBit 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
