/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_SEGMENTED — Pairwise sequence alignment for one reference x query segment
    coming from hspZ high-scoring ungapped alignment. It skips indexing, seeding,
    gap-free extension or chaining. Flags match KegAlign's generated LASTZ
    command: --gappedthresh=L, --inner=H, --ydrop=Y, --strand from the partition.

    Sequence inputs resolve per chromosome: a pre-extracted <chrom>.fa from
    EXTRACT_CHROMS when present (v1 .2bit, which lastz cannot read), otherwise
    the native .2bit single-contig selection (v0).
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process LASTZ_SEGMENTED {
    tag "${meta.id} ${meta.reference}:${meta.query}"
    label 'process_fast'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/lastz:1.04.52--h7b50bb2_1' :
        'quay.io/biocontainers/lastz:1.04.52--h7b50bb2_1' }"

    input:
    tuple val(meta), path(segment)
    path  reference_twobit
    path  query_twobit
    path  reference_chroms_dir                 // dir of pre-extracted <chrom>.fa (v1) or empty (v0)
    path  query_chroms_dir
    val   lastz_h
    val   lastz_l
    val   lastz_y

    output:
    tuple val(meta.reference), val(meta.query), path("*.axt"), emit: axt
    path  "versions.yml",                                      emit: versions

    script:
    """
    # lastz's 2bit loader concatenates every sequence of a [multiple] file into
    # one buffer capped at 2^31-11 bp, which whole-genome 2bits overflow. The
    # segments file names its sequences, so run one lastz per (reference,
    # query) chromosome pair with single-contig selection instead.
    #
    # Strand, L, H, Y and traceback match KegAlign's generated LASTZ commands
    # (run_keg_lastz.py / lastz-commands.txt). lastz_l is gappedthresh; lastz_h
    # is inner only. --strand is required for minus-strand query coordinates.
    case "${meta.id}" in
        *.minus*) strand=minus ;;
        *.plus*)  strand=plus  ;;
        *)
            strand=\$(awk -F'\\t' 'NF>=7 { print (\$7=="-" ? "minus" : "plus"); exit }' ${segment})
            ;;
    esac
    if [ -z "\$strand" ]; then
        echo "LASTZ_SEGMENTED: cannot derive --strand from ${segment} (id=${meta.id})" >&2
        exit 1
    fi

    awk -F'\\t' 'NF { print \$1 "\\t" \$4 }' ${segment} | sort -u > pairs.txt
    mkdir -p pairs
    while IFS=\$'\\t' read -r ref query; do
        safe=\$(printf '%s__%s' "\$ref" "\$query" | tr -c 'A-Za-z0-9_.-' '_')
        awk -F'\\t' -v r="\$ref" -v q="\$query" '\$1==r && \$4==q' ${segment} > "pairs/\${safe}.segments"

        # Pre-extracted per-chrom FASTA wins (v1 .2bit is unreadable by lastz);
        # otherwise the v0 .2bit single-contig selection, as before.
        if [ -s "${reference_chroms_dir}/\${ref}.fa" ]; then
            refseq="${reference_chroms_dir}/\${ref}.fa"
        else
            refseq="${reference_twobit}/\${ref}"
        fi
        if [ -s "${query_chroms_dir}/\${query}.fa" ]; then
            qseq="${query_chroms_dir}/\${query}.fa"
        else
            qseq="${query_twobit}/\${query}"
        fi
        lastz \\
          --segments="pairs/\${safe}.segments" \\
          --format=axt+ \\
          --allocate:traceback=1.99G \\
          --gappedthresh=${lastz_l} \\
          --inner=${lastz_h} \\
          --ydrop=${lastz_y} \\
          --strand=\$strand \\
          --output="pairs/\${safe}.axt" \\
          \$refseq \$qseq
    done < pairs.txt
    cat pairs/*.axt > ${meta.id}.axt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
    END_VERSIONS
    """

    stub:
    """
    touch ${meta.id}.axt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
    END_VERSIONS
    """
}
