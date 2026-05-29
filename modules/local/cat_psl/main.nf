/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CAT_PSL — Concatenate LASTZ PSL files for one target-partition bucket,
    strip PSL header lines (#…), and compress with gzip.
    Equivalent to cat_step.py in the original pipeline.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CAT_PSL {
    tag "$bucket_key"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/coreutils:9.5' :
        'quay.io/biocontainers/coreutils:9.5' }"

    input:
    tuple val(bucket_key), path(psl_files)  // psl_files is a list of .psl files

    output:
    path "${bucket_key}.psl.gz", emit: psl_gz
    path "versions.yml",          emit: versions

    script:
    """
    # Concatenate all PSL files, strip header lines (starting with #), compress
    cat ${psl_files} | grep -v '^#' | gzip -c > ${bucket_key}.psl.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        gzip: \$(gzip --version | head -1 | awk '{print \$NF}')
    END_VERSIONS
    """
}
