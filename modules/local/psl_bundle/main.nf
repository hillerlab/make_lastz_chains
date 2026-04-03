/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PSL_BUNDLE — Group chromosome-sorted PSL files into bundles by total base count.
    Calls bin/psl_bundle.py. Each output bundle (bundle.N.psl) will be processed
    independently by AXT_CHAIN.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process PSL_BUNDLE {
    label 'process_fast'

    // TODO: conda "conda-forge::python=3.10"
    // TODO: container 'path/to/python.sif'

    input:
    path sorted_psl_dir       // directory output of PSL_SORT_ACC
    path target_chrom_sizes
    val  max_bases

    output:
    path "split_psl/*.psl", emit: bundles
    path "versions.yml",    emit: versions

    script:
    """
    mkdir -p split_psl

    psl_bundle.py \\
        --input_dir ${sorted_psl_dir} \\
        --chrom_sizes ${target_chrom_sizes} \\
        --output_dir split_psl \\
        --max_bases ${max_bases}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
