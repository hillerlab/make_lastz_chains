/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    KEGALIGN_EXPAND — Unpack a KegAlign package into one job record per partition.

    Emits the extracted package plus jobs.tsv (job_id, segments filename), one
    line per KegAlign diagonal partition, which KEGALIGN_ALIGNMENT fans out into
    independent KEG_LASTZ tasks.

    Job ids are assigned in .segments-filename order, not commands.json order:
    KegAlign writes commands.json from parallel workers, so its line order is not
    reproducible and ids derived from it would break Nextflow's resume caching.

    Partition boundaries are read, never recomputed — KegAlign stays the sole
    authority for HSP partitioning.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process KEGALIGN_EXPAND {
    tag "${reference_name} vs ${query_name}"
    label 'process_fast'

    conda "${projectDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/python:3.8.0--2' :
        'quay.io/biocontainers/python:3.8.0--2' }"

    input:
    tuple val(reference_name), val(query_name), path(tarball)

    output:
    tuple val(reference_name), val(query_name), path("package"), emit: expanded
    path "jobs.tsv",                                             emit: jobs
    path "versions.yml",                                         emit: versions

    script:
    """
    mkdir -p package
    tar -xzf ${tarball} -C package

    test -s package/galaxy/commands.json || {
        echo "KegAlign package has no galaxy/commands.json: ${tarball}" >&2
        exit 1
    }

    # One --segments= per LASTZ command, and it is the partition's identity.
    grep -o '"--segments=[^"]*"' package/galaxy/commands.json \\
        | sed 's/^"--segments=//; s/"\$//' \\
        | sort > segments.txt

    test -s segments.txt || {
        echo "KegAlign package declares no partitions: ${tarball}" >&2
        exit 1
    }
    if [ "\$(sort -u segments.txt | wc -l)" -ne "\$(wc -l < segments.txt)" ]; then
        echo "Duplicate --segments= across KegAlign commands — job ids would collide." >&2
        exit 1
    fi

    awk '{ printf "keg_%06d\\t%s\\n", NR, \$0 }' segments.txt > jobs.tsv
    echo "KegAlign partitions: \$(wc -l < jobs.tsv)" >&2

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        tar: \$(tar --version | head -1 | awk '{print \$NF}')
    END_VERSIONS
    """
}
