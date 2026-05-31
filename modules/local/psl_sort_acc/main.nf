/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PSL_SORT_ACC — Sort all PSL files by target chromosome using pslSortAcc.
    Input PSL files must have no header lines (produced by CAT_PSL).
    Outputs a directory where each file is named <chrom>.psl.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process PSL_SORT_ACC {
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-pslsortacc:482--h0b57e2e_0' : 
        'quay.io/biocontainers/ucsc-pslsortacc:482--h0b57e2e_0' }"

    input:
    path psl_gz_files   // list of all .psl.gz files from CAT_PSL

    output:
    path "sorted_psl/", emit: sorted_psl_dir
    path "versions.yml", emit: versions

    script:
    """
    mkdir -p sorted_psl temp_kent

    pslSortAcc nohead sorted_psl temp_kent ${psl_gz_files}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-pslsortacc: \$(pslSortAcc 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
