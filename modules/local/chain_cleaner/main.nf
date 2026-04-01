/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CHAIN_CLEANER — Remove weak and suspicious chains using chainCleaner.
    chainCleaner requires additional Kent binaries (chainNet, NetFilterNonNested.perl)
    in PATH; these are handled by the container/conda environment.
    Note: on macOS, chainCleaner always returns non-zero — the script accounts for this.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process CHAIN_CLEANER {
    tag "$input_chain_gz.name"
    label 'process_medium'

    // TODO: conda "bioconda::ucsc-chaincleaner bioconda::ucsc-chainnet bioconda::ucsc-chainfilter"
    // TODO: container 'path/to/ucsc_tools.sif'

    input:
    path input_chain_gz      // filled.chain.gz or all.chain.gz
    path target_twobit
    path query_twobit
    path target_chrom_sizes
    path query_chrom_sizes
    val  chain_linear_gap
    val  clean_chain_parameters

    output:
    path "before_cleaning.chain.gz",   emit: before_clean   // kept for reference
    path "cleaned_intermediate.chain", emit: cleaned_chain
    path "removed_suspects.bed",       emit: suspects_bed
    path "versions.yml",               emit: versions

    script:
    def clean_args = clean_chain_parameters.split()
    """
    # Decompress input chain
    gunzip -c ${input_chain_gz} > before_cleaning.chain

    # Re-compress for reference output
    gzip -k before_cleaning.chain

    # Run chainCleaner (may return non-zero on macOS — tolerated)
    chainCleaner \\
        before_cleaning.chain \\
        ${target_twobit} \\
        ${query_twobit} \\
        cleaned_intermediate.chain \\
        removed_suspects.bed \\
        -linearGap=${chain_linear_gap} \\
        -tSizes=${target_chrom_sizes} \\
        -qSizes=${query_chrom_sizes} \\
        ${clean_chain_parameters} \\
        || true   # tolerate non-zero on macOS

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-chaincleaner: \$(chainCleaner 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
