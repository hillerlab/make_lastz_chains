/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_SPLICE — puts each gap's best mini chain into the merged chain.

    For every gap, the first (best-scoring) mini chain is inserted when it
    scores at least fill_insert_chain_min_score, exactly as RepeatFiller's
    insert_chain_content does. Chain headers keep their old scores;
    CHAINTOOLS_SCORE rescores next, as on the lastz engine. Fails on a mini
    chain that crosses gaps or strands, names no gap, or leaves its record.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process FILL_SPLICE {
    tag "${meta.id}"
    label 'process_medium'

    conda "${projectDir}/environment.yml"
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(meta), path(merged_chain), path(gaps), path(minis, stageAs: 'mini/*')
    val   fill_insert_chain_min_score

    output:
    tuple val(meta), path("${meta.id}.filled.chain"), emit: chain
    path  "versions.yml",                            emit: versions

    script:
    """
    fill_gaps.py splice \\
        --chain ${merged_chain} \\
        --gaps ${gaps} \\
        --min-score ${fill_insert_chain_min_score} \\
        --out ${meta.id}.filled.chain \\
        mini/*.mini.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """

    stub:
    """
    touch ${meta.id}.filled.chain

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
