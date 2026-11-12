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
    writes chains sorted by score, so chainSort is not needed. Query records
    without anchors are left out: lastz would seed them against the whole shard.
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
        # A gap's mini chain must pair its own two records, as RepeatFiller's
        # per-gap lastz does; the shared [multiple] target lets lastz pair a
        # query with another gap's record (HLmyoMyot9A x HLmyoDau2: a 33 bp TA
        # repeat with another gap's, and two gaps whose 38 bp sides are the
        # same sequence, each a cross-gap mini chain FILL_SPLICE rejects).
        # 1. Only query records that have anchors, in file order (the segments
        #    follow it): lastz seeds an anchorless query record itself,
        #    against every target record. A gap without an hspZ anchor has no
        #    HSP at K, so RepeatFiller would not align it either.
        # 2. Drop blocks whose target and query records differ: with several
        #    target records, lastz also reports an anchor's match on another
        #    record holding the same sequence. Each forms its own pair in
        #    axtChain, so the gaps' own chains do not change.
        awk -F'\\t' 'NR == FNR { keep[\$4] = 1; next }
                     /^>/      { p = (substr(\$1, 2) in keep) }
                     p' ${segments} ${queries} > ${shard}.anchored.q.fa
        lastz \\
          "${targets}[multiple]" \\
          ${shard}.anchored.q.fa \\
          --segments=${segments} \\
          --format=axt \\
          --gappedthresh=${lastz_l} \\
          --strand=plus \\
        | awk 'NF >= 9 && \$1 ~ /^[0-9]+\$/ { keep = (\$2 == \$5); if (!keep) dropped++ }
               keep || /^#/
               END { if (dropped) printf "LASTZ_FILL: dropped %d cross-gap block(s)\\n", dropped > "/dev/stderr" }' \\
          > ${shard}.axt
        axtChain -linearGap=loose -faT -faQ ${shard}.axt ${targets} ${shard}.anchored.q.fa ${shard}.mini.chain
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
