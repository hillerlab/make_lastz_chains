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
    genome_name    // val: e.g. 'hg38'
    genome_path    // val: path to genome file (FASTA or .2bit)

    main:
    // Generate chrom.sizes format agnostic
    CHROMSIZE ( Channel.of( [ genome_name, genome_path ] ) )

    // Determine if the input is already a .2bit file
    def is_twobit = genome_path.endsWith('.2bit')

    if (is_twobit) {
        // Already .2bit — stage the file directly
        twobit_ch = Channel.of( [ genome_name, file(genome_path) ] )
    } else {
        // Convert FASTA → .2bit
        fa_ch = Channel.of( [ genome_name, file(genome_path) ] )
        FA_TO_TWO_BIT ( fa_ch )
        twobit_ch = FA_TO_TWO_BIT.out.twobit
    }

    // Join twobit and chrom_sizes on genome_name
    prepared_ch = twobit_ch.join( CHROMSIZE.out.chrom_sizes )

    // Pre-extract chromosomes once per genome (v1 only; no-op for v0).
    // Downstream LASTZ tasks symlink this directory instead of each task
    // running its own twoBitToFa.
    EXTRACT_CHROMS ( prepared_ch )

    emit:
    prepared   = prepared_ch                      // (genome_name, twobit, chrom_sizes)
    chroms_dir = EXTRACT_CHROMS.out.chroms_dir    // (genome_name, dir/)
    versions   = (is_twobit
                    ? CHROMSIZE.out.versions
                    : FA_TO_TWO_BIT.out.versions.mix(CHROMSIZE.out.versions)
                 ).mix(EXTRACT_CHROMS.out.versions)
}
