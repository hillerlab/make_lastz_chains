/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PSL_BUNDLE — Group chromosome-sorted PSL files into bundles by total base count.
    Calls bin/psl_bundle.py. Each output bundle (bundle.N.psl) will be processed
    independently by AXT_CHAIN.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process PSL_BUNDLE {
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.8.0--2' :
        'biocontainers/python:3.11' }"

    input:
    path psl_files, stageAs: "sorted_psl/*"
    path reference_chrom_sizes
    val  max_bases

    output:
    path "split_psl/*.psl", emit: bundles
    path "versions.yml",    emit: versions

    script:
    """
    mkdir -p split_psl

    psl_bundle.py \\
        --input_dir sorted_psl/ \\
        --chrom_sizes ${reference_chrom_sizes} \\
        --output_dir split_psl \\
        --max_bases ${max_bases}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
