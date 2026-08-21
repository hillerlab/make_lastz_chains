/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_SEGMENTED — Pairwise sequence alignment for one reference x query segment
    coming from hspZ high-scoring ungapped alignment. It skips indexing, seeding,
    gap-free extension or chaining. Flags match KegAlign's generated LASTZ
    command: --gappedthresh=L, --inner=H, --ydrop=Y, --strand from the partition.
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
        lastz \\
          --segments="pairs/\${safe}.segments" \\
          --format=axt+ \\
          --allocate:traceback=1.99G \\
          --gappedthresh=${lastz_l} \\
          --inner=${lastz_h} \\
          --ydrop=${lastz_y} \\
          --strand=\$strand \\
          --output="pairs/\${safe}.axt" \\
          ${reference_twobit}/\$ref ${query_twobit}/\$query
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
