/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MASKED_CHROMS — per-chromosome FASTAs of the masked genome (MASK_GENOME),
    for --window_masking_recovery.

    Only the chromosomes of the overflowed LASTZ jobs. run_lastz.py prefers a
    <chrom>.fa from the chroms dir over the .2bit, so LASTZ_RECOVER reads these,
    whatever the .2bit's format (lastz cannot read a v1 .2bit).
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process MASKED_CHROMS {
    tag "$genome_name"
    label 'process_fast'

    conda "${projectDir}/environment.yml"
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(genome_name), path(twobit), val(chroms)

    output:
    tuple val(genome_name), path("masked_*"), emit: chroms_dir
    path "versions.yml",                      emit: versions

    script:
    // Named after the process (MASKED_CHROMS_REFERENCE / _QUERY), not the genome:
    // LASTZ_RECOVER stages both dirs, and a self-alignment has one genome name.
    def dir = "masked_${task.process.tokenize(':')[-1].toLowerCase()}"
    """
    mkdir -p ${dir}
    printf '%s\\n' ${chroms.join(' ')} > chroms.txt
    while IFS= read -r chrom; do
        twoBitToFa -seq="\$chrom" ${twobit} "${dir}/\$chrom.fa"
    done < chroms.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-twobittofa: 482
    END_VERSIONS
    """

    stub:
    def dir = "masked_${task.process.tokenize(':')[-1].toLowerCase()}"
    """
    mkdir -p ${dir}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-twobittofa: 'stub'
    END_VERSIONS
    """
}
