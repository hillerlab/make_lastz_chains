/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    KEG_LASTZ — CPU gapped extension of ONE KegAlign diagonal partition.

    Distributed counterpart of KEGALIGN_LASTZ: Nextflow schedules one task per
    KegAlign partition instead of one task running all of them through KegAlign's
    process pool, so each partition caches, retries, and escalates on its own and
    the workload spreads across nodes.

    LASTZ and axtToPsl run in the same task on purpose — splitting them would
    double the scheduler job count for no gain.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process KEG_LASTZ {
    tag "${job_id}"

    conda "${projectDir}/environment.yml"
    // The pipeline image, not a granular one: this must run the SAME lastz build
    // as KEGALIGN_LASTZ (kegalign-full ships 1.04.52) or the batched and
    // distributed executors stop being comparable, and it is the only image
    // carrying both that lastz and axtToPsl. ghcr :latest drifts — if a rebuild
    // moves lastz off 1.04.52, pin both here and in modules/local/kegalign*.
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(job_id), val(segments)
    path  expanded                      // extracted KegAlign package (staged once, symlinked)
    path  reference_chrom_sizes
    path  query_chrom_sizes

    output:
    path "${job_id}.psl", emit: psl
    path "versions.yml",  emit: versions

    script:
    // the whole package directory is staged per task (one symlink) so
    // the KegAlign-generated LASTZ arguments can be used verbatim. Same pattern
    // the LASTZ module already uses for its per-chromosome FASTA directories.
    // Stage only the partition's own files if profiling shows this hurts.
    """
    run_keg_lastz.py \\
        --package ${expanded} \\
        --segments ${segments} \\
        --reference-sizes ${reference_chrom_sizes} \\
        --query-sizes ${query_chrom_sizes} \\
        --output ${job_id}.psl

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        ucsc-axttopsl: \$(axtToPsl 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
