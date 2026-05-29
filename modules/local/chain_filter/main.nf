/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_FILTER — Filter chains by minimum score and compress the final result.
    This is the last step of the pipeline; output is the final .chain.gz file.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAIN_FILTER {
    tag "$cleaned_chain.name"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc_tools:332--1' : 
        'quay.io/biocontainers/ucsc_tools:332--1' }"

    input:
    path cleaned_chain     // cleaned_intermediate.chain from CHAIN_CLEANER
    val  min_chain_score
    val  target_name
    val  query_name

    output:
    path "${target_name}.${query_name}.final.chain.gz", emit: final_chain
    path "versions.yml",                                 emit: versions

    script:
    """
    chainFilter -minScore=${min_chain_score} ${cleaned_chain} \\
    | gzip -c > ${target_name}.${query_name}.final.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-chainfilter: \$(chainFilter 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
