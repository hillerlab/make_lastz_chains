/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MASK_GENOME — the genome with WindowMasker + sdust added to its own
    soft-masking (the union, like twoBitMask -add), for --window_masking_recovery.

    Runs only when a LASTZ job overflowed. As in the old Hiller lab pipeline, the
    masked genome then replaces the original for the re-run jobs and for every
    later step (chaining, anti-repeat, fill, clean). The .2bit keeps the
    original's format: v1 (-long) stays v1.
    Output: <name>.wmsdust.2bit
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process MASK_GENOME {
    tag "$genome_name"
    label 'process_fast'

    conda "${projectDir}/environment.yml"
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(genome_name), path(twobit), path(mask_bed)

    output:
    tuple val(genome_name), path("${genome_name}.wmsdust.2bit"), emit: twobit
    path "versions.yml",                                         emit: versions

    script:
    """
    # Bytes 0-3 are the signature 0x1A412743 (their order gives the endianness),
    # bytes 4-7 the version: 1 means the 64-bit (-long) layout.
    read -r b0 b1 b2 b3 b4 b5 b6 b7 <<< "\$(head -c 8 ${twobit} | od -A n -t x1)"
    case "\$b0\$b1\$b2\$b3" in
        4327411a) ver=\$((16#\$b7\$b6\$b5\$b4)) ;;
        1a412743) ver=\$((16#\$b4\$b5\$b6\$b7)) ;;
        *) echo "Not a .2bit file: ${twobit}" >&2; exit 1 ;;
    esac
    long=\$([ "\$ver" -eq 1 ] && echo -long || true)

    twoBitToFa ${twobit} stdout | soft_mask_fasta.py ${mask_bed} > masked.fa
    faToTwoBit \$long masked.fa ${genome_name}.wmsdust.2bit
    rm -f masked.fa

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """

    stub:
    """
    cp ${twobit} ${genome_name}.wmsdust.2bit

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: 'stub'
    END_VERSIONS
    """
}
