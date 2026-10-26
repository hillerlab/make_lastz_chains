/*
Copyright (c) 2026 The Hiller Lab at the Senckenberg Gessellschaft für Naturforschung
Distributed under the terms of the Apache License, Version 2.0.
*/

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PREPARE_GENOMES subworkflow
    Converts FASTA to .2bit (if needed), generates chrom.sizes, and pre-extracts
    every chromosome to its own FASTA when the .2bit is v1 (lastz cannot read v1
    directly — see modules/local/extract_chroms/main.nf). For v0 .2bit the
    chroms_dir is empty and lastz reads the .2bit natively.

    Emits:
      prepared   — (genome_name, twobit_file, chrom_sizes_file)
      chroms_dir — (genome_name, dir_of_<chrom>.fa)   empty dir for v0
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FA_TO_TWO_BIT  } from '../../../modules/local/fa_to_two_bit/main'
include { CHROMSIZE      } from '../../../modules/local/chromsize/main'
include { EXTRACT_CHROMS } from '../../../modules/local/extract_chroms/main'

workflow PREPARE_GENOMES {
    take:
    genome_name    // val: e.g. 'hg38', or a list of names (--array queries)
    genome_path    // val: path to genome file (FASTA or .2bit), or a list matching genome_name
    extract_chroms // val: true/false

    main:
    ch_versions = Channel.empty()

    // One item per genome. Names become Strings: they key per-query channels
    // downstream, where an Integer name (--query_name 1) would never match.
    ch_genomes = Channel
        .fromList( [ [ genome_name ].flatten()*.toString(), [ genome_path ].flatten() ].transpose() )
        .branch { _n, p ->
            twobit: p.toString().endsWith('.2bit')   // already .2bit — staged directly
            fasta:  true                              // FASTA → .2bit
        }

    // Generate chrom.sizes format agnostic
    CHROMSIZE ( ch_genomes.twobit.mix( ch_genomes.fasta ) )

    FA_TO_TWO_BIT ( ch_genomes.fasta.map { n, p -> [ n, file(p) ] } )
    twobit_ch = ch_genomes.twobit.map { n, p -> [ n, file(p) ] }.mix( FA_TO_TWO_BIT.out.twobit )

    ch_versions = ch_versions.mix(FA_TO_TWO_BIT.out.versions)

    // Join twobit and chrom_sizes on genome_name
    prepared_ch = twobit_ch.join( CHROMSIZE.out.chrom_sizes )

    // Pre-extract chromosomes once per genome (v1 only; no-op for v0).
    // Downstream LASTZ tasks symlink this directory instead of each task
    // running its own twoBitToFa.
    ch_extracted_chroms = Channel.empty()
    if (extract_chroms) {
        EXTRACT_CHROMS ( prepared_ch )
        ch_extracted_chroms = EXTRACT_CHROMS.out.chroms_dir

        ch_versions = ch_versions.mix(EXTRACT_CHROMS.out.versions)
    }

    ch_versions = ch_versions.mix(CHROMSIZE.out.versions)

    emit:
    prepared   = prepared_ch                      // (genome_name, twobit, chrom_sizes)
    chroms_dir = ch_extracted_chroms              // (genome_name, dir/)
    versions   = ch_versions                      // versions.yml
}
