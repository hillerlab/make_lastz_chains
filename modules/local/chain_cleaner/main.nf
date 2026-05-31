/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_CLEANER — Remove weak and suspicious chains using chainCleaner.
    chainCleaner requires additional Kent binaries (chainNet, NetFilterNonNested.perl)
    in PATH; these are handled by the container/conda environment.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAIN_CLEANER {
    tag "$input_chain_gz.name"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-chaincleaner:455--h1536b3f_1' :
        'ghcr.io/hillerlab/chaincleaner:latest' }"

    input:
    tuple val(meta), path(input_chain_gz) // filled.chain.gz or all.chain.gz
    path target_twobit
    path query_twobit
    path target_chrom_sizes
    path query_chrom_sizes
    val  chain_linear_gap
    val  clean_chain_parameters

    output:
    tuple val(meta), path("cleaned_intermediate.chain"), emit: cleaned_chain
    tuple val(meta), path("removed_suspects.bed"),       emit: suspects_bed
    path "versions.yml",               emit: versions

    script:
    def clean_args = clean_chain_parameters.split()

    meta.id = input_chain_gz.baseName + '.cleaned'
    """
    chainCleaner \\
        ${input_chain_gz} \\
        ${target_twobit} \\
        ${query_twobit} \\
        cleaned_intermediate.chain \\
        removed_suspects.bed \\
        -linearGap=${chain_linear_gap} \\
        -tSizes=${target_chrom_sizes} \\
        -qSizes=${query_chrom_sizes} \\
        ${clean_chain_parameters}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-chaincleaner: \$(chainCleaner 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
