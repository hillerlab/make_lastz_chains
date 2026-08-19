/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    AXT_TO_PSL — Convert AXT+ alignments to PSL.

    Same AXT+ → PSL convention the LASTZ backend uses inside bin/run_lastz.py,
    so both backends hand CHAIN_BUILD identical PSL semantics.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process AXT_TO_PSL {
    tag "${reference_name} vs ${query_name}"
    label 'process_medium'

    conda "${projectDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-axttopsl:482--h0b57e2e_0' :
        'quay.io/biocontainers/ucsc-axttopsl:482--h0b57e2e_0' }"

    input:
    tuple val(reference_name), val(query_name), path(axt)
    path  reference_chrom_sizes
    path  query_chrom_sizes

    output:
    tuple val(reference_name), val(query_name), path("*.psl"), emit: psl
    path "versions.yml",                                       emit: versions

    script:
    // Named after the AXT, so the one-task-per-keg fan-out under
    // --kegalign_mps_workers > 1 cannot collide in 02_kegalign_psl/. A single
    // keg keeps the ${reference}.${query}.psl name it has always had.
    """
    axtToPsl \\
        ${axt} \\
        ${reference_chrom_sizes} \\
        ${query_chrom_sizes} \\
        ${axt.baseName}.psl

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-axttopsl: \$(axtToPsl 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """

    stub:
    """
    touch ${axt.baseName}.psl

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-axttopsl: 'stub'
    END_VERSIONS
    """
}
