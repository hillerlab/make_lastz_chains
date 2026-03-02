/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PREPARE_GENOMES subworkflow
    Converts FASTA to .2bit (if needed) and generates chrom.sizes for one genome.
    Emits: (genome_name, twobit_file, chrom_sizes_file)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { FA_TO_TWO_BIT } from '../../../modules/local/fa_to_two_bit/main'
include { TWO_BIT_INFO  } from '../../../modules/local/two_bit_info/main'

workflow PREPARE_GENOMES {
    take:
    genome_name    // val: e.g. 'hg38'
    genome_path    // val: path to genome file (FASTA or .2bit)

    main:
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

    // Generate chrom.sizes
    TWO_BIT_INFO ( twobit_ch )

    // Join twobit and chrom_sizes on genome_name
    prepared_ch = twobit_ch.join( TWO_BIT_INFO.out.chrom_sizes )

    emit:
    prepared   = prepared_ch   // tuple: (genome_name, twobit, chrom_sizes)
    versions   = is_twobit
                   ? TWO_BIT_INFO.out.versions
                   : FA_TO_TWO_BIT.out.versions.mix(TWO_BIT_INFO.out.versions)
}
