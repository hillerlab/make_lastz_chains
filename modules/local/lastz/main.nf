/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ — Pairwise sequence alignment for one reference × query partition pair
    Uses run_lastz_intermediate_layer.py (from standalone_scripts/) to handle
    both regular and BULK partitions. A minimal params JSON is written per job.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process LASTZ {
    tag "${reference_part} vs ${query_part}"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/lastz:1.04.52--h7b50bb2_1' :
        'ghcr.io/hillerlab/pylastz:latest' }"

    input:
    tuple val(reference_part), val(query_part)
    path  reference_twobit                     // staged as its basename, e.g. reference.2bit
    path  query_twobit
    path  reference_chrom_sizes
    path  query_chrom_sizes
    path  reference_chroms_dir                 // dir of pre-extracted <chrom>.fa (v1) or empty (v0)
    path  query_chroms_dir
    val   lastz_k
    val   lastz_h
    val   lastz_l
    val   lastz_y

    output:
    tuple val(reference_part), path("*.psl"), optional: true, emit: psl
    path  "versions.yml",                                   emit: versions

    script:
    // Build a short, stable identifier from each partition string. BULK partitions
    // can list up to 100 scaffold names — using the full string as a filename
    // overflows the 255-byte filesystem limit and run_lastz.py crashes with
    // "OSError: [Errno 36] File name too long". Mirror the old pipeline's
    // _get_lastz_out_fname_part: BULK → "BULK_<n>"; regular → "<chrom>_<start>-<end>".
    def safe_part = { String p ->
        if (p.startsWith("BULK")) {
            return p.split(":")[0]
        }
        def parts = p.split(":")
        return "${parts[1]}_${parts[2]}"
    }
    def t_safe = safe_part(reference_part)
    def q_safe = safe_part(query_part)
    def out_psl = "${t_safe}__${q_safe}.psl"
    """
    # Write minimal pipeline params JSON so run_lastz* scripts can read chrom.sizes
    cat > params.json << 'JSONEOF'
    {
        "seq_1_len": "${reference_chrom_sizes.name}",
        "seq_2_len": "${query_chrom_sizes.name}",
        "lastz_k": ${lastz_k},
        "lastz_h": ${lastz_h},
        "lastz_l": ${lastz_l},
        "lastz_y": ${lastz_y}
    }
    JSONEOF

    run_lastz_intermediate_layer.py \\
        --reference '${reference_part}' \\
        --query '${query_part}' \\
        --params_json params.json \\
        --output ${out_psl} \\
        --run_lastz_script run_lastz.py \\
        --output_format psl \\
        --reference_chrom_dir ${reference_chroms_dir} \\
        --query_chrom_dir ${query_chroms_dir}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        python: \$(python --version 2>&1 | awk '{print \$2}')
        axtToPsl: 482
    END_VERSIONS
    """
}
