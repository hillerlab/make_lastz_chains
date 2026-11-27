/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    DENSE_WINDOWS — satellite arrays shared by both genomes, found in the hspZ
    anchors before lastz extends them (--dense_windows; bin/dense_windows.py).

    One task per query reads all of its .segments:
      1. Trigger: a 100 kb x 100 kb block (reference chrom x query chrom x
         strand) with >= 100k anchors. hg38 x mm39 peaks at 13,581, Myotis bat
         pairs at 1.5-3.4 M. Without a trigger nothing else happens.
      2. Regions: anchors per 10 kb window along each genome, summed over all
         partner chromosomes; >= 100k seeds a region, which grows through
         adjacent windows with >= 10k.
    With --dense_windows filter, the anchors inside the regions are dropped
    (kept/<same file name>), close to soft-masking the regions before hspZ.

    --mask_reference_regions_bed: reference regions whose anchors are dropped
    in every mode, triggered or not (arrays whose anchors are too sparse to
    trigger, while lastz extends each through megabases of soft-masked
    satellite). Every file then goes to kept/, and what was dropped to
    <reference>.<query>.mask_{reference,query}.bed for DENSE_MASK_*. With
    --dense_windows off, only the BED is applied.

    Output: status 'yes' (triggered) or 'no'; <reference>.<query>.dense_windows.tsv;
    the regions as <reference>.<query>.{reference,query}.bed when triggered;
    kept/*.segments when filtering a triggered query or with the BED; the BED
    plus the filtered regions as <reference>.<query>.mask_{reference,query}.bed.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process DENSE_WINDOWS {
    tag "${reference_name} vs ${query}"
    label 'process_low'

    conda "${projectDir}/environment.yml"
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(query), val(reference_name), path(segments, stageAs: 'segments/*'), path(query_sizes, stageAs: 'query.sizes')
    path reference_sizes, stageAs: 'reference.sizes'
    val  mode                                                       // off | report | filter | fail
    path mask_reference_bed                                         // --mask_reference_regions_bed, or []

    output:
    tuple val(query), env('DENSE_TRIGGERED'),                                        emit: status
    tuple val(query), path("*.dense_windows.tsv"),                                   emit: report
    tuple val(query), val(reference_name), path("*.reference.bed"), path("*.query.bed"), emit: regions, optional: true
    tuple val(query), val(reference_name), path("kept/*.segments"),                  emit: kept, optional: true
    tuple val(query), val(reference_name), path("*.mask_reference.bed"), path("*.mask_query.bed"), emit: mask, optional: true
    path "versions.yml",                                                             emit: versions

    script:
    def args = task.ext.args ?: ''
    def mask = mask_reference_bed ? "--mask-reference-bed ${mask_reference_bed}" : ''
    """
    DENSE_TRIGGERED=\$(dense_windows.py \\
        --mode ${mode} ${mask} \\
        --reference-sizes reference.sizes \\
        --query-sizes query.sizes \\
        --prefix ${reference_name}.${query} \\
        --out kept \\
        --threads ${task.cpus} \\
        ${args} \\
        segments)

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """

    stub:
    """
    DENSE_TRIGGERED=no
    printf 'mode\\t%s\\ntriggered\\tno\\n' ${mode} > ${reference_name}.${query}.dense_windows.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: 'stub'
    END_VERSIONS
    """
}
