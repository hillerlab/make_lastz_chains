/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    WINDOWMASKER — genome-wide WindowMasker + sdust intervals (UCSC's
    windowmaskerSdust recipe), for --window_masking_recovery.

    Runs only when a CPU LASTZ job overflowed lastz's anchor table. The intervals
    are what the old Hiller lab pipeline added to its crashed jobs' genomes
    (twoBitMask -add) before re-running them split 5x5.
    Output: <name>.wmsdust.bed, 0-based half-open.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process WINDOWMASKER {
    tag "$genome_name"
    label 'process_fast'

    conda "bioconda::blast=2.17.0"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/blast:2.17.0--h66d330f_0' :
        'quay.io/biocontainers/blast:2.17.0--h66d330f_0' }"

    input:
    tuple val(genome_name), path(fasta)

    output:
    tuple val(genome_name), path("${genome_name}.wmsdust.bed"), emit: bed
    path "versions.yml",                                         emit: versions

    script:
    // windowmasker counts in a bounded table and spills when it is full; give it
    // most of the task's memory (MB), leaving room for the process itself.
    def mem_mb = task.memory ? Math.max(1536, (task.memory.toMega() * 0.8) as long) : 1536
    """
    windowmasker -mk_counts -in ${fasta} -out ${genome_name}.counts -mem ${mem_mb}
    windowmasker -ustat ${genome_name}.counts -in ${fasta} -out ${genome_name}.interval \\
        -outfmt interval -dust true
    # interval format: '>name' then '<start> - <end>' lines, 0-based inclusive
    awk '/^>/ { c = substr(\$1, 2); next } NF == 3 { print c "\\t" \$1 "\\t" \$3 + 1 }' \\
        ${genome_name}.interval > ${genome_name}.wmsdust.bed
    rm -f ${genome_name}.counts ${genome_name}.interval

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        windowmasker: \$(windowmasker -version-full 2>&1 | awk '/Package/ { print \$3; exit }' | tr -d ',')
    END_VERSIONS
    """

    stub:
    """
    : > ${genome_name}.wmsdust.bed

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        windowmasker: 'stub'
    END_VERSIONS
    """
}
