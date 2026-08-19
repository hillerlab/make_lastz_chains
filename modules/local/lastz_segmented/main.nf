/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_SEGMENTED — Pairwise sequence alignment for one reference x query segment
    coming from hspZ high-scoring ungapped alignment. It skips indexing, seeding, 
    gap-free extension or chaining.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process LASTZ_SEGMENTED {
    tag "${meta.reference} vs ${meta.query}"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/lastz:1.04.52--h7b50bb2_1' :
        'ghcr.io/hillerlab/pylastz:latest' }"

    input:
    tuple val(meta), path(segment)
    path  reference_twobit
    path  query_twobit
    val   lastz_h
    val   lastz_l
    val   lastz_y

    output:
    tuple val(meta.reference), val(meta.query), path("*.axt"), emit: axt
    path  "versions.yml",                                      emit: versions

    script:
    """
    lastz \\
      --segments=${segment} \\
      --format=axt+ \\
      --traceback=800.0M \\
      --gappedthresh=${lastz_h} \\
      --inner=${lastz_h} \\
      --ydrop=${lastz_y} \\
      --output=${meta.id}.axt \\
      --rdotplot=${meta.id}.rdot \\
      ${reference_twobit}[multiple] ${query_twobit}[multiple]

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
    END_VERSIONS
    """

    stub:
    """
    touch ${meta.id}.axt
    touch ${meta.id}.rdot

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
    END_VERSIONS
    """
}
