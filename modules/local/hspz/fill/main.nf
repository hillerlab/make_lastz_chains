/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    HSPZ_FILL — GPU seeding + HSP filtering of every fill gap of one query.

    hspZ run --paired (>= 0.0.6) compares record i of the targets only with
    record i of the queries, so cross-gap repeat hits are never computed; per
    pair its output equals a standalone hspZ run of that pair. K is
    fill_lastz_k, RepeatFiller's lastz K. Record names are <shard>_<gap> and
    pairs come out in input order, so each shard's lines are contiguous and are
    split back into one .segments file per shard (an empty one when a shard has
    no anchors) for LASTZ_FILL.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process HSPZ_FILL {
    tag "${meta.id}"
    label 'process_gpu'

    conda "bioconda::hspz=0.0.6"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        '' :
        'ghcr.io/hillerlab/hspz:latest' }"

    input:
    tuple val(meta), path(targets, stageAs: 'shards/*'), path(queries, stageAs: 'shards/*')
    val   lastz_k                        // fill_lastz_k = --hspthresh

    output:
    tuple val(meta), path("segments/*.segments"), emit: segments
    path  "versions.yml",                         emit: versions

    script:
    def args = task.ext.args ?: ''
    """
    cat \$(ls shards/*.t.fa | sort) > targets.fa
    cat \$(ls shards/*.q.fa | sort) > queries.fa
    mkdir segments
    for t in shards/*.t.fa; do : > "segments/\$(basename "\$t" .t.fa).segments"; done

    if [ -s queries.fa ]; then
        hspZ \\
          run \\
          $args \\
          --paired \\
          -S plus \\
          --hspthresh ${lastz_k} \\
          -r targets.fa \\
          -q queries.fa \\
          -o out \\
          --time

        awk '{ split(\$1, a, "_"); f = "segments/shard_" a[1] ".segments"
               if (f != prev) { if (prev != "") close(prev); prev = f }
               print >> f }' out/paired.segments
        test "\$(cat segments/*.segments | wc -l)" -eq "\$(wc -l < out/paired.segments)" || {
            echo "HSPZ_FILL: split segments do not add up to out/paired.segments" >&2
            exit 1
        }
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """

    stub:
    """
    mkdir segments
    for t in shards/*.t.fa; do : > "segments/\$(basename "\$t" .t.fa).segments"; done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        hspZ: \$( hspZ --version | sed 's/hspZ //g' )
    END_VERSIONS
    """
}
