/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FILL_CHAIN_SPLIT — Decompress merged chain and randomly split into N parts
    for parallel gap-filling by REPEAT_FILLER.
    Calls bin/split_chains.py.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

process FILL_CHAIN_SPLIT {
    label 'process_fast'

    // TODO: conda "conda-forge::python=3.10 conda-forge::gzip=1.12"
    // TODO: container 'path/to/python.sif'

    input:
    path merged_chain_gz   // *.all.chain.gz
    val  num_parts

    output:
    path "chain_chunks/infill_chain_*", emit: chain_chunks
    path "versions.yml",                 emit: versions

    script:
    """
    mkdir -p chain_chunks

    # Decompress
    gunzip -c ${merged_chain_gz} > merged.chain

    # Split into parts
    split_chains.py \\
        --chain merged.chain \\
        --num_parts ${num_parts} \\
        --output_dir chain_chunks

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python --version 2>&1 | awk '{print \$2}')
    END_VERSIONS
    """
}
