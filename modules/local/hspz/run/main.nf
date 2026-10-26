/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HSPZ — GPU-accelerated high-scoring ungapped alignment pair backend

    Runs upstream hspZ, resulting in per-block LASTZ workload as .segments.
    This procees runs on GPU, so the CPU gapped-extension stage downstream is
    unchanged.

    One query (the default) runs exactly as before: hspZ -q, segments/*.segments.
    --array runs every query in ONE hspZ --query-list batch (hspZ >= 0.0.4):
    each reference bin is built once for the whole list, while each query's
    output stays byte-identical to its standalone run. Job directories are
    renamed after their query, so segments/<query>/*.segments keys downstream.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process HSPZ {
    tag "${reference_name} vs ${query_names.size() == 1 ? query_names[0] : query_names.size() + ' queries'}"
    label 'process_gpu'

    conda "bioconda::hspz=0.0.4"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/hillerlab/hspz:0.0.4' }"

    input:
    tuple val(reference_name), path(reference_sequence)                 // fa|gz|2bit
    tuple val(query_names), path(query_sequences, stageAs: 'queries/*') // one query, or every --array query, as <name>.fa
    val   lastz_k                                                       // K = --hspthresh (hspZ -H is THIS, not BLASTZ H)

    output:
    tuple val(reference_name), val(query_names), path(params.array ? "segments/*/*.segments" : "segments/*.segments"), emit: segments, optional: true
    path "segments/queries.tsv",                                                                                       emit: queries, optional: true
    path "plan.tsv*",                                                                                                  emit: plan, optional: true
    path "versions.yml",                                                                                               emit: versions

    script:
    def args = task.ext.args ?: ''
    if (params.array)
    """
    printf '%s\\n' ${query_sequences} > queries.txt

    hspZ \\
      run \\
      $args \\
      --hspthresh ${lastz_k} \\
      -r ${reference_sequence} \\
      --query-list queries.txt \\
      -o batch \\
      -D \\
      --time \\
      --dump-plan plan.tsv

    # hspZ writes queries.tsv only after every job succeeded, one row per query
    # in list order; name each job directory after its query's FASTA.
    test "\$(tail -n +2 batch/queries.tsv | wc -l)" -eq "\$(wc -l < queries.txt)" || {
        echo "hspZ --query-list: batch/queries.tsv does not list every query of queries.txt" >&2
        exit 1
    }
    mkdir segments
    mv batch/queries.tsv segments/
    tail -n +2 segments/queries.tsv | while IFS=\$'\\t' read -r job fasta _; do
        mv "batch/\${job}" "segments/\$(basename "\${fasta}" .fa)"
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """
    else
    """
    hspZ \\
      run \\
      $args \\
      --hspthresh ${lastz_k} \\
      -r ${reference_sequence} \\
      -q ${query_sequences} \\
      -o segments \\
      -D \\
      --time \\
      --dump-plan plan.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """

    stub:
    def dirs = params.array ? query_names.collect { "segments/${it}" } : [ 'segments' ]
    """
    for dir in ${dirs.join(' ')}; do
        mkdir -p \$dir
        touch \$dir/tmp1.block0.r0.plus.segments
    done
    touch plan.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """
}
