/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_CHAIN_MERGE — Merge all filled chain chunks into a single compressed chain.
    Uses chainMergeSort piped through gzip.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process FILL_CHAIN_MERGE {
    label 'process_medium'

    // TODO: conda "bioconda::ucsc-chainmergesort=377 conda-forge::gzip=1.12"
    // TODO: container 'path/to/ucsc_tools.sif'

    input:
    path filled_chain_files   // list of *.filled.chain files from REPEAT_FILLER
    val  target_name
    val  query_name

    output:
    path "${target_name}.${query_name}.filled.chain.gz", emit: filled_chain
    path "versions.yml",                                  emit: versions

    script:
    """
    mkdir -p temp_kent

    ls *.filled.chain > filled_chain_list.txt

    chainMergeSort -inputList=filled_chain_list.txt -tempDir=temp_kent \\
    | gzip -c > ${target_name}.${query_name}.filled.chain.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-chainmergesort: \$(chainMergeSort 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
