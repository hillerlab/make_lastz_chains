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
    # extract every chromosome to its own FASTA so lastz reads the FASTA instead.
    is_v1=\$(python3 - <<'PY'
with open("${twobit}", "rb") as f:
    h = f.read(8)
if h[:4] == b"\\x43\\x27\\x41\\x1A":
    v = int.from_bytes(h[4:8], "little")
elif h[:4] == b"\\x1A\\x41\\x27\\x43":
    v = int.from_bytes(h[4:8], "big")
else:
    raise SystemExit("Not a .2bit file: ${twobit}")
print(1 if v == 1 else 0)
PY
)

    if [ "\$is_v1" = "1" ]; then
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
