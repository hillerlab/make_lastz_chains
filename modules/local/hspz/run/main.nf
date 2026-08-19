/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HSPZ — GPU-accelerated high-scoring ungapped alignment pair backend

    Runs upstream hspZ, resulting in per-block LASTZ workload as a tarball.
    This procees runs on GPU, so the CPU gapped-extension stage downstream is
    unchanged.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process HSPZ {
    tag "${reference_name} vs ${query_name}"
    label 'process_gpu'

    conda "bioconda::hspz=0.0.1"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/hillerlab/hspz:0.0.1' }"

    input:
    tuple val(reference_name), path(reference_sequence) // fa|gz|2bit
    tuple val(query_name),     path(query_sequence)     // fa|gz|2bit

    output:
    tuple val(reference_name), val(query_name), path("*/*.segments"),  emit: segments, optional: true
    tuple val(reference_name), val(query_name), path("segments"),      emit: segments_dir, optional: true
    tuple val(reference_name), val(query_name), path("*/*.tar.gz"),    emit: tarball, optional: true
    path "plan.tsv",                                                   emit: plan, optional: true
    path "versions.yml",                                               emit: versions

    script:
    def args = task.ext.args ?: ''
    def tar  = task.ext.tar ? "-Z" : ""

    """
    hspZ \\
      run \\
      $args \\
      -r ${reference_sequence} \\
      -q ${query_sequence} \\
      -o segments \\
      -D \\
      $tar \\
      --time \\
      --dump-plan plan.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """

    stub:
    """
    mkdir -p segments
    touch segments/*.segments
    touch segments/*.tar.gz
    touch plan.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """
}
