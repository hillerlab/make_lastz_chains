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
    // -long writes a 64-bit v1 .2bit (required for genomes whose .2bit would
    // exceed the 32-bit offset limit, ~4 GB file ≈ 16 Gbp). lastz cannot read
    // v1 directly, so we only enable -long for large genomes; smaller ones get
    // v0 and bin/run_lastz.py reads the .2bit natively (matches upstream).
    // Threshold: 4 GB of FASTA (~1 GB v0 .2bit) leaves a wide safety margin.
    def use_long = genome_fa.size() > 4L * 1024 * 1024 * 1024 ? '-long' : ''
    """
    faToTwoBit ${use_long} ${genome_fa} ${genome_name}.2bit

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-fatotwobit: \$(faToTwoBit 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
