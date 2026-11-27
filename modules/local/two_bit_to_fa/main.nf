/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    TWO_BIT_TO_FA — Rehydrate a whole genome .2bit back to a single FASTA.

    KegAlign's GPU seeding stage reads FASTA only (its own LASTZ stage reads the
    .2bit copies KEGALIGN builds internally). The pipeline standardises every
    genome to .2bit in PREPARE_GENOMES, so the KegAlign backend converts back
    here rather than PREPARE_GENOMES keeping the original FASTA around.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process TWO_BIT_TO_FA {
    tag "$genome_name"
    label 'process_fast'

    conda "${projectDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-twobittofa:482--hdc0a859_0' :
        'quay.io/biocontainers/ucsc-twobittofa:482--hdc0a859_0' }"

    input:
    tuple val(genome_name), path(twobit)

    output:
    tuple val(genome_name), path("${genome_name}.fa"), emit: fasta
    path "versions.yml",                               emit: versions

    script:
    """
    twoBitToFa ${twobit} ${genome_name}.fa

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-twobittofa: \$(twoBitToFa 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
