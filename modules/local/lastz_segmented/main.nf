/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    LASTZ_SEGMENTED — Pairwise sequence alignment for one reference x query segment
    coming from hspZ high-scoring ungapped alignment. It skips indexing, seeding,
    gap-free extension or chaining. Flags match KegAlign's generated LASTZ
    command: --gappedthresh=L, --inner=H, --ydrop=Y, --strand from the partition.

    Sequence inputs resolve per chromosome: a pre-extracted <chrom>.fa from
    EXTRACT_CHROMS when present (v1 .2bit, which lastz cannot read), otherwise
    the native .2bit single-contig selection (v0).

    lastz streams straight into axtToPsl, as KEG_LASTZ does, so no AXT is ever
    written. The PSL lands gzipped, one file per reference chromosome under
    psl/<chrom>/, which CHAIN_BUILD bundles without a split pass.

    --lastz_segments_per_job N: one task takes N segments files and runs them
    one after another, each exactly as it runs alone (same lastz calls, same
    psl/<chrom>/<file id>.r<n>.psl.gz names), so the PSL is the same and a pair
    needs N times fewer scheduler jobs. Default 1: one file per task.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process LASTZ_SEGMENTED {
    tag "${meta.id} ${meta.reference}:${meta.query}"
    label 'process_fast'

    conda "${projectDir}/environment.yml"
    // The pipeline image, not a granular one: it carries lastz, axtToPsl and gzip.
    container 'ghcr.io/hillerlab/make_lastz_chains:latest'

    input:
    tuple val(meta), path(segments)            // one segments file, or the files of one batch
    path  reference_twobit
    path  query_twobit
    path  reference_chroms_dir                 // dir of pre-extracted <chrom>.fa (v1) or empty (v0)
    path  query_chroms_dir
    path  reference_chrom_sizes
    path  query_chrom_sizes
    val   lastz_h
    val   lastz_l
    val   lastz_y

    output:
    // optional: a segments file whose anchors all fail to extend writes no PSL.
    tuple val(meta), path("psl/*/*.psl.gz"), emit: psl, optional: true
    val   n_segments,                        emit: n_segments   // files this task ran: the integrity count
    path  "versions.yml",                    emit: versions

    script:
    n_segments = segments instanceof Collection ? segments.size() : 1
    """
    # One segments file: \$1 the file, \$2 its id (the file name without .segments).
    lastz_one() {
        local segment=\$1 id=\$2 strand ref safe query qseq refseq all_fa q

        # lastz's 2bit loader concatenates every sequence of a [multiple] file into
        # one buffer capped at 2^31-11 bp, which whole-genome 2bits overflow. The
        # segments file names its sequences, so run one lastz per reference
        # chromosome (single-contig selection) with all of its queries in one FASTA,
        # in pairs.txt order, which writes the same PSL lines as one lastz per
        # (reference, query) pair. That per-pair loop re-read the reference
        # chromosome and the query 2bit's index once per pair: on a fragmented
        # assembly (2.07 M scaffolds) one task held 4,845 pairs and read 393 GB in
        # 4 h; per reference it reads 0.45 GB in 14 s.
        #
        # Strand, L, H, Y and traceback match KegAlign's generated LASTZ commands
        # (run_keg_lastz.py / lastz-commands.txt). lastz_l is gappedthresh; lastz_h
        # is inner only. --strand is required for minus-strand query coordinates.
        case "\$id" in
            *.minus*) strand=minus ;;
            *.plus*)  strand=plus  ;;
            *)
                strand=\$(awk -F'\\t' 'NF>=7 { print (\$7=="-" ? "minus" : "plus"); exit }' "\$segment")
                ;;
        esac
        if [ -z "\$strand" ]; then
            echo "LASTZ_SEGMENTED: cannot derive --strand from \$segment (id=\$id)" >&2
            exit 1
        fi

        awk -F'\\t' 'NF { print \$1 "\\t" \$4 }' "\$segment" | sort -u > pairs.txt
        mkdir -p pairs psl
        # One PSL per reference chromosome, numbered within this segments file
        # (r1, r2, ...) so names stay unique when bundles from many files are
        # staged together.
        declare -A ref_n=()
        awk -F'\\t' '!seen[\$1]++ { print \$1 }' pairs.txt > refs.txt
        while IFS= read -r ref; do
            safe=\$(printf '%s' "\$ref" | tr -c 'A-Za-z0-9_.-' '_')
            awk -F'\\t' -v r="\$ref" '\$1==r { print \$2 }' pairs.txt > "pairs/\${safe}.queries"
            # This reference's anchors, grouped by query in pairs.txt order (file order
            # within a query), so lastz goes through them as the per-pair loop did.
            awk -F'\\t' -v r="\$ref" 'NR==FNR { o[\$1] = NR; next } \$1==r { print o[\$4] "\\t" FNR "\\t" \$0 }' \\
                "pairs/\${safe}.queries" "\$segment" \\
                | sort -t\$'\\t' -k1,1n -k2,2n | cut -f3- > "pairs/\${safe}.segments"

            # Pre-extracted per-chrom FASTA wins (v1 .2bit is unreadable by lastz);
            # otherwise the v0 .2bit single-contig selection, as before.
            if [ -s "${reference_chroms_dir}/\${ref}.fa" ]; then
                refseq="${reference_chroms_dir}/\${ref}.fa"
            else
                refseq="${reference_twobit}/\${ref}"
            fi
            if [ "\$(wc -l < "pairs/\${safe}.queries")" -eq 1 ]; then
                query=\$(cat "pairs/\${safe}.queries")
                if [ -s "${query_chroms_dir}/\${query}.fa" ]; then
                    qseq="${query_chroms_dir}/\${query}.fa"
                else
                    qseq="${query_twobit}/\${query}"
                fi
            else
                # Several queries: one FASTA, in pairs.txt order.
                all_fa=1
                while IFS= read -r q; do
                    [ -s "${query_chroms_dir}/\${q}.fa" ] || { all_fa=0; break; }
                done < "pairs/\${safe}.queries"
                if [ "\$all_fa" = 1 ]; then
                    while IFS= read -r q; do
                        cat "${query_chroms_dir}/\${q}.fa"
                    done < "pairs/\${safe}.queries" > "pairs/\${safe}.fa"
                else
                    twoBitToFa -seqList="pairs/\${safe}.queries" ${query_twobit} "pairs/\${safe}.fa"
                fi
                qseq="pairs/\${safe}.fa"
            fi
            lastz \\
              --segments="pairs/\${safe}.segments" \\
              --format=axt+ \\
              --allocate:traceback=1.99G \\
              --gappedthresh=${lastz_l} \\
              --inner=${lastz_h} \\
              --ydrop=${lastz_y} \\
              --strand=\$strand \\
              \$refseq \$qseq \\
            | axtToPsl /dev/stdin ${reference_chrom_sizes} ${query_chrom_sizes} pairs/\${safe}.psl

            if [ -s "pairs/\${safe}.psl" ]; then
                ref_n[\$ref]=\$(( \${#ref_n[@]} + 1 ))
                mkdir -p "psl/\$ref"
                gzip -c "pairs/\${safe}.psl" > "psl/\$ref/\${id}.r\${ref_n[\$ref]}.psl.gz"
            fi
            rm -f "pairs/\${safe}".*
        done < refs.txt
    }

    # --lastz_segments_per_job: the files of this task, one after another. Each
    # runs as it would alone, so its PSL files are the same.
    n_done=0
    for segment in ${segments}; do
        lastz_one "\$segment" "\$(basename "\$segment" .segments)"
        n_done=\$(( n_done + 1 ))
    done
    if [ "\$n_done" -ne ${n_segments} ]; then
        echo "LASTZ_SEGMENTED: ran \$n_done of ${n_segments} segments files" >&2
        exit 1
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        ucsc-axttopsl: \$(axtToPsl 2>&1 | grep version | awk '{print \$NF}' || echo 'N/A')
    END_VERSIONS
    """

    stub:
    n_segments = segments instanceof Collection ? segments.size() : 1
    """
    mkdir -p psl/${meta.reference}
    for segment in ${segments}; do
        echo | gzip -c > "psl/${meta.reference}/\$(basename "\$segment" .segments).r1.psl.gz"
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        lastz: \$(lastz --version 2>&1 | head -1)
        ucsc-axttopsl: 'stub'
    END_VERSIONS
    """
}
