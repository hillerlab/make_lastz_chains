/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CAT_PSL — Concatenate LASTZ PSL files for one target-partition bucket,
    strip PSL header lines (#…), and compress with gzip.
    Equivalent to cat_step.py in the original pipeline.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CAT_PSL {
    tag "$bucket_key"
    label 'process_single'

    // TODO: conda "conda-forge::gzip=1.12"
    // TODO: container 'path/to/coreutils.sif'

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
