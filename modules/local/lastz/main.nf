/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ — Pairwise sequence alignment for one target × query partition pair
    Uses run_lastz_intermediate_layer.py (from standalone_scripts/) to handle
    both regular and BULK partitions. A minimal params JSON is written per job.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process LASTZ {
    tag "${target_part} vs ${query_part}"
    label 'process_fast'


    // TODO: conda "bioconda::lastz=1.04.22 bioconda::ucsc-axttopsl=377 conda-forge::python=3.10"
    // TODO: container 'path/to/lastz.sif'

    input:
    tuple val(target_part), val(query_part)
    path  target_twobit                     // staged as its basename, e.g. target.2bit
    path  query_twobit
    path  target_chrom_sizes
    path  query_chrom_sizes
    val   lastz_k
    val   lastz_h
    val   lastz_l
    val   lastz_y
    val   axt_to_psl_path

    output:
    tuple val(target_part), path("*.psl"), optional: true, emit: psl
    path  "versions.yml",                                   emit: versions

    script:
    // Derive a safe output filename from the partition strings
    def t_safe = target_part.replaceAll('[:/]', '_')
    def q_safe = query_part.replaceAll('[:/]', '_')
    def out_psl = "${t_safe}__${q_safe}.psl"
    """
    # Write minimal pipeline params JSON so run_lastz* scripts can read chrom.sizes
    cat > params.json << 'JSONEOF'
    {
        "seq_1_len": "${target_chrom_sizes.name}",
        "seq_2_len": "${query_chrom_sizes.name}",
        "lastz_k": ${lastz_k},
        "lastz_h": ${lastz_h},
        "lastz_l": ${lastz_l},
        "lastz_y": ${lastz_y}
    }
    JSONEOF

    run_lastz_intermediate_layer.py \\
        '${target_part}' \\
        '${query_part}' \\
        params.json \\
        ${out_psl} \\
        run_lastz.py \\
        --output_format psl \\
        --axt_to_psl ${axt_to_psl_path}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1 | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
