/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_GAPS — one record pair per fillable chain gap (--repeat_filler_engine hspz).

    Picks exactly the gaps REPEAT_FILLER would patch and writes each as a target
    and a query record with the same name, gap-local, plus strand (the query is
    reverse-complemented for '-' chains) and uppercased unless skip_fill_unmask
    (RepeatFiller's lastz [unmask]). Gaps, not chains, are cut into
    min(shards, gaps) shards (--fill_hspz_shards), so one dominant chain no longer holds a
    whole fill task. At least one (possibly empty) shard is always written.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process FILL_GAPS {
    tag "${meta.id}"
    label 'process_medium'

    conda "${projectDir}/environment.yml"
    // The pipeline image: it carries both python and twoBitToFa.
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(meta), path(merged_chain)   // *.all.chain.gz
    path  reference_twobit
    path  query_twobit
    val   chain_min_score
    val   fill_gap_max_size_t
    val   fill_gap_max_size_q
    val   fill_gap_min_size_t
    val   fill_gap_min_size_q
    val   shards
    val   skip_fill_unmask

    output:
    tuple val(meta), path("gaps.tsv"),                           emit: gaps
    tuple val(meta), path("shards/*.t.fa"), path("shards/*.q.fa"), emit: shards
    path  "versions.yml",                                         emit: versions

    script:
    def unmask = skip_fill_unmask ? '' : '--unmask'
    """
    fill_gaps.py extract \\
        --chain ${merged_chain} \\
        --t2bit ${reference_twobit} \\
        --q2bit ${query_twobit} \\
        --chain-min-score ${chain_min_score} \\
        --gap-min-t ${fill_gap_min_size_t} \\
        --gap-max-t ${fill_gap_max_size_t} \\
        --gap-min-q ${fill_gap_min_size_q} \\
        --gap-max-q ${fill_gap_max_size_q} \\
        --shards ${shards} \\
        ${unmask}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
        twoBitToFa: 482
    END_VERSIONS
    """

    stub:
    """
    mkdir -p shards
    touch gaps.tsv shards/shard_00000.t.fa shards/shard_00000.q.fa

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
        twoBitToFa: 482
    END_VERSIONS
    """
}
