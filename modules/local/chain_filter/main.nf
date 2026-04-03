/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_FILTER — Filter chains by minimum score and compress the final result.
    This is the last step of the pipeline; output is the final .chain.gz file.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAIN_FILTER {
    tag "$cleaned_chain.name"
    label 'process_fast'

    // TODO: conda "bioconda::ucsc-chainfilter=377 conda-forge::gzip=1.12"
    // TODO: container 'path/to/ucsc_tools.sif'

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
