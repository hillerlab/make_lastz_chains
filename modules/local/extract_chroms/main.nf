/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    EXTRACT_CHROMS — Extract every chromosome from a v1 .2bit to its own FASTA.

    Produces a directory of <chrom>.fa files that LASTZ tasks share by symlink
    (since `path` inputs are symlinked by default), avoiding the
    O(N tasks × genome) duplication that the per-task cache produced.

    For v0 .2bit files, lastz reads them natively — this process emits an empty
    directory (sentinel) and run_lastz.py falls back to its native .2bit code path.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process EXTRACT_CHROMS {
    tag "$genome_name"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/ucsc-twobittofa:482--hdc0a859_0' :
        'quay.io/biocontainers/ucsc-twobittofa:482--hdc0a859_0' }"

    input:
    tuple val(genome_name), path(twobit), path(chrom_sizes)

    output:
    tuple val(genome_name), path("${genome_name}_chroms/"), emit: chroms_dir
    path "versions.yml",                                     emit: versions

    script:
    """
    mkdir -p ${genome_name}_chroms

    # Detect .2bit version. v0 (32-bit offsets) is readable directly by lastz —
    # no extraction needed. v1 (faToTwoBit -long) is unreadable by lastz —
    # extract every chromosome to its own FASTA so lastz reads the FASTA 
    # Bytes 0-3 are the signature 0x1A412743; their on-disk order tells us the
    # endianness, and bytes 4-7 hold the version in that same endianness.
    read -r b0 b1 b2 b3 b4 b5 b6 b7 <<< "\$(head -c 8 ${twobit} | od -A n -t x1)"
    sig="\$b0\$b1\$b2\$b3"
    if [ "\$sig" = "4327411a" ]; then
        ver=\$((16#\$b7\$b6\$b5\$b4))      # little-endian
    elif [ "\$sig" = "1a412743" ]; then
        ver=\$((16#\$b4\$b5\$b6\$b7))      # big-endian
    else
        echo "Not a .2bit file: ${twobit}" >&2
        exit 1
    fi

    if [ "\$ver" -eq 1 ]; then
        n=\$(wc -l < ${chrom_sizes})
        echo "v1 .2bit detected — extracting \$n chromosomes" >&2
        while IFS=\$'\\t' read -r chrom size; do
            [ -z "\$chrom" ] && continue
            twoBitToFa -seq="\$chrom" ${twobit} "${genome_name}_chroms/\${chrom}.fa"
        done < ${chrom_sizes}
        echo "Done extracting \$n chromosomes." >&2
    else
        echo "v0 .2bit — no extraction (lastz reads .2bit directly)" >&2
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        ucsc-twobittofa: \$(twoBitToFa 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """
}
