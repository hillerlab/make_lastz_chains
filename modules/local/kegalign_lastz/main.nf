/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    KEGALIGN_LASTZ — CPU gapped-extension stage for the KegAlign backend.

    Consumes the tarball KEGALIGN produced (per-block .segments + the .2bit
    copies + one LASTZ command per block) and runs those commands with upstream
    run_lastz_tarball.py, concatenating the AXT+ output.

    Deliberately NOT a process_gpu task: the GPU is released when KEGALIGN ends.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process KEGALIGN_LASTZ {
    tag "${reference_name} vs ${query_name}"
    label 'process_medium'

    conda "bioconda::kegalign-full=0.1.2.9"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/kegalign-full:0.1.2.9--hdfd78af_0' :
        'quay.io/biocontainers/kegalign-full:0.1.2.9--hdfd78af_0' }"

    input:
    tuple val(reference_name), val(query_name), path(tarball)

    output:
    tuple val(reference_name), val(query_name), path("*.axt"), emit: axt
    path "versions.yml",                                       emit: versions

    script:
    // batched LASTZ is the intentional v1 ceiling — one Nextflow task
    // runs every block command through KegAlign's own process pool. Fan the
    // .segments workloads out as separate Nextflow tasks only if profiling shows
    // scheduler-level parallelism is materially better.
    //
    // The name comes from the keg, not from (reference, query): KEGALIGN_MPS emits
    // one keg per chromosome-bin pair, and their AXT/PSL must not collide in the
    // publish directory. One keg gives exactly today's ${reference}.${query} name.
    def prefix = tarball.baseName.replaceAll(/\.kegalign$/, '')
    """
    run_lastz_tarball.py \\
        --input ${tarball} \\
        --output ${prefix}.axt \\
        --parallel ${task.cpus}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
