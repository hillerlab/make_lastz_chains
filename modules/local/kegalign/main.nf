/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    KEGALIGN — GPU seeding / ungapped-extension / HSP filtering stage.

    Runs upstream KegAlign through its own orchestrator (runner.py) and packages
    the resulting per-block LASTZ workload as a tarball. Only this process needs
    a GPU: the gapped-extension LASTZ commands inside the tarball are run later
    by KEGALIGN_LASTZ on CPU, so the GPU allocation ends here.

    KegAlign owns its own reference/query partitioning — the pipeline's
    PARTITION_REFERENCE / PARTITION_QUERY steps are deliberately not used.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process KEGALIGN {
    tag "${reference_name} vs ${query_name}"
    label 'process_gpu'

    conda "bioconda::kegalign-full=0.1.2.9"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/kegalign-full:0.1.2.9--hdfd78af_0' :
        'quay.io/biocontainers/kegalign-full:0.1.2.9--hdfd78af_0' }"

    input:
    tuple val(reference_name), path(reference_fa)
    tuple val(query_name),     path(query_fa)
    val   lastz_k                              // K = --hspthresh
    val   lastz_l                              // L = --gappedthresh
    val   lastz_h                              // H = --inner
    val   lastz_y                              // Y = --ydrop

    output:
    tuple val(reference_name), val(query_name), path("*.kegalign.tgz"), emit: tarball
    path "versions.yml",                                               emit: versions

    script:
    // KegAlign's LASTZ commands reference "<data_folder>ref.2bit" and
    // "<data_folder>query.2bit" by those exact names (hardcoded in KegAlign's
    // segment_printer), and runner.py hardcodes the data folder as "work/".
    """
    mkdir -p work
    faToTwoBit ${reference_fa} work/ref.2bit
    faToTwoBit ${query_fa}     work/query.2bit

    # runner.py shells out to <tool_directory>/diagonal_partition.py and
    # package_output.py reads <tool_directory>/lastz-cmd.ini; both ship next to
    # the KegAlign executables (container /usr/local/bin, or the conda env bin).
    tool_dir=\$(dirname \$(command -v diagonal_partition.py))

    # Diagonal partitioning is always on: it splits oversized .segments files so
    # no single downstream LASTZ command blows up on traceback memory.
    runner.py \\
        --output-type tarball \\
        --output-file lastz-commands.txt \\
        --tool_directory "\$tool_dir" \\
        --diagonal-partition \\
        --num-cpu ${task.cpus} \\
        ${reference_fa} ${query_fa} \\
        --format axt+ \\
        --hspthresh ${lastz_k} \\
        --gappedthresh ${lastz_l} \\
        --inner ${lastz_h} \\
        --ydrop ${lastz_y}

    # Without this, package_output.py packs an empty workload and the failure
    # only surfaces inside run_lastz_tarball.py as an opaque output-count error.
    test -s lastz-commands.txt || {
        echo "KegAlign produced no alignment commands: no HSP passed --hspthresh ${lastz_k}." >&2
        echo "Nothing to align for ${reference_name} vs ${query_name}." >&2
        exit 1
    }

    package_output.py --tool_directory "\$tool_dir" --format_selector axt+
    mv data_package.tgz ${reference_name}.${query_name}.kegalign.tgz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        kegalign: \$(kegalign --help 2>&1 | grep -m1 -i '^Version:' | awk '{print \$2}' || echo 'N/A')
        faToTwoBit: \$(faToTwoBit 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
