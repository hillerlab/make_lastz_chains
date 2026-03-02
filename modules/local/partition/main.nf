/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PARTITION — Divide genome into chunks for parallel LASTZ alignment
    Calls bin/partition.py which outputs partition strings using the .2bit basename
    so they resolve correctly in Nextflow work directories.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process PARTITION {
    tag "${genome_name} (${genome_label})"
    label 'process_single'

    // TODO: conda "conda-forge::python=3.10"
    // TODO: container 'path/to/python.sif'

    input:
    tuple val(genome_name), path(twobit), path(chrom_sizes)
    val genome_label   // "target" or "query"
    val chunk_size
    val overlap

    output:
    tuple val(genome_name), path("${genome_label}_partitions.txt"), emit: partitions
    path "versions.yml",                                              emit: versions

    script:
    """
    partition.py \\
        --chrom_sizes ${chrom_sizes} \\
        --twobit_name ${twobit.name} \\
        --chunk_size ${chunk_size} \\
        --overlap ${overlap} \\
        --output ${genome_label}_partitions.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
