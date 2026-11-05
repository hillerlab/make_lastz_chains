/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_FILL — gapped extension + chaining of one shard of fill gaps.

    RepeatFiller's per-gap `lastz ... K= L= --strand | axtChain -linearGap=loose
    | chainSort`, minus the seeding (HSPZ_FILL did it) and run once per shard:
    the gap records are a [multiple] target, every anchor names its own record,
    and lastz never extends across records. axtChain reads the shard FASTAs
    (-faT/-faQ) instead of reloading whole chromosomes from the .2bit for every
    gap, which was 80-91 ms of RepeatFiller's ~87 ms per gap; it also already
    writes chains sorted by score, so chainSort is not needed.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process LASTZ_FILL {
    tag "${meta.id}:${shard}"
    label 'process_fast'

    conda "${projectDir}/environment.yml"
    // REPEAT_FILLER's image: the same lastz (1.04.60) and axtChain builds as
    // the lastz engine, so the two engines differ only in seeding. The
    // pipeline image also has both, but ships lastz 1.04.52 until it is rebuilt.
    container 'ghcr.io/hillerlab/repeat_filler:latest'

    input:
    tuple val(meta), val(shard), path(targets), path(queries), path(segments)
    val   lastz_l                        // fill_lastz_l = --gappedthresh

    output:
    tuple val(meta), path("${shard}.mini.chain"), emit: chain
    path  "versions.yml",                        emit: versions

    script:
    """
    if [ -s ${segments} ]; then
        lastz \\
          "${targets}[multiple]" \\
          ${queries} \\
          --segments=${segments} \\
          --format=axt \\
          --gappedthresh=${lastz_l} \\
          --strand=plus \\
          > ${shard}.axt
        axtChain -linearGap=loose -faT -faQ ${shard}.axt ${targets} ${queries} ${shard}.mini.chain
    else
        : > ${shard}.mini.chain
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        axtChain: 482
    END_VERSIONS
    """

    stub:
    """
    : > ${shard}.mini.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        axtChain: 482
    END_VERSIONS
    """
}
