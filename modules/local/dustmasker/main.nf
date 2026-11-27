/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    DUSTMASKER — low-complexity tracts of a genome (--dust_masking), as BED.

    NCBI dustmasker (symmetric DUST, default window 64, level 20, linker 1) finds
    the intervals; they are joined across gaps of at most 10 bp, and tracts
    shorter than min_tract bp are dropped (0 keeps every interval). MASK_GENOME
    then soft-masks the tracts into the genome every later step reads.

    Short DUST runs sit inside ordinary sequence, where masking them would only
    cost seeds. The long tracts are simple tandem repeats that seed against every
    similar tract of the other genome: on hs1, the unmasked part of the tracts
    >= 100 bp (0.5% of the genome) held 21-96% of all hspZ anchors.

    Output: <name>.dust.bed, 0-based half-open, in genome order.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process DUSTMASKER {
    tag "$genome_name"
    label 'process_fast'

    conda "bioconda::blast=2.17.0"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/blast:2.17.0--h66d330f_0' :
        'quay.io/biocontainers/blast:2.17.0--h66d330f_0' }"

    input:
    tuple val(genome_name), path(fasta)
    val   min_tract

    output:
    tuple val(genome_name), path("${genome_name}.dust.bed"), emit: bed
    path "versions.yml",                                      emit: versions

    script:
    """
    # acclist: '>name<TAB>start<TAB>end', 0-based with an inclusive end, in input order
    dustmasker -in ${fasta} -outfmt acclist -out ${genome_name}.dust.acclist
    awk -F'\\t' -v min=${min_tract} 'BEGIN { OFS = "\\t" }
        {
            name = substr(\$1, 2); start = \$2; end = \$3 + 1
            if (name == c && start - e <= 10) { if (end > e) e = end; next }
            if (c != "" && e - s >= min) print c, s, e
            c = name; s = start; e = end
        }
        END { if (c != "" && e - s >= min) print c, s, e }' \\
        ${genome_name}.dust.acclist > ${genome_name}.dust.bed
    rm -f ${genome_name}.dust.acclist

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        dustmasker: \$(dustmasker -version 2>&1 | awk '{ print \$2; exit }')
    END_VERSIONS
    """

    stub:
    """
    : > ${genome_name}.dust.bed

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        dustmasker: 'stub'
    END_VERSIONS
    """
}
