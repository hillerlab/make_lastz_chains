# Make Lastz Chains

Portable Hillerlab solution for generating pairwise genome alignment chains.
These chains can be used as input for [TOGA](https://github.com/hillerlab/TOGA) or for generating multiz alignments.

Chains explained:
http://genomewiki.ucsc.edu/index.php/Chains_Nets

Chain format specification:
https://genome.ucsc.edu/goldenPath/help/chain.html


## Usage

### Installation:

Install nextflow:
https://www.nextflow.io/docs/latest/getstarted.html
Nextflow requires a java runtime

Then do the following:

```bash
git clone git@github.com:hillerlab/make_lastz_chains.git
cd chains_builder
# install python packages (just two)
pip3 install -r requirements.txt
# download/build all necessary binaries: 
./install_dependencies.py
```

### Usage

The script to be called is *make_chains.py*

```txt
usage: make_chains.py [-h] [--project_dir PROJECT_DIR] [--DEF DEF] [--force_def]
                      [--continue_arg CONTINUE_ARG] [--executor EXECUTOR]
                      [--executor_queuesize EXECUTOR_QUEUESIZE]
                      [--executor_partition EXECUTOR_PARTITION]
                      [--cluster_parameters CLUSTER_PARAMETERS] [--lastz LASTZ]
                      [--seq1_chunk SEQ1_CHUNK] [--seq2_chunk SEQ2_CHUNK]
                      [--blastz_h BLASTZ_H] [--blastz_y BLASTZ_Y]
                      [--blastz_l BLASTZ_L] [--blastz_k BLASTZ_K]
                      [--fill_prepare_memory FILL_PREPARE_MEMORY]
                      [--chaining_memory CHAINING_MEMORY]
                      [--chain_clean_memory CHAIN_CLEAN_MEMORY]
                      target_name query_name target_genome query_genome

Build chains for a given pair of target and query genomes.

positional arguments:
  target_name           Target genome identifier, e.g. hg38, human, etc.
  query_name            Query genome identifier, e.g. mm10, mm39, mouse, etc.
  target_genome         Target genome. Accepted formats are: fasta and 2bit.
  query_genome          Query genome. Accepted formats are: fasta and 2bit.

optional arguments:
  -h, --help            show this help message and exit
  --project_dir PROJECT_DIR, --pd PROJECT_DIR
                        Project directory. By default: pwd
  --DEF DEF             DEF formatted configuration file, please read README.md
                        for details.
  --force_def           Start the pipeline even if a DEF file already exists
                        (overwrite the project)
  --continue_arg CONTINUE_ARG
                        Continue execution in the already existing project
                        starting with the specified step. Available steps are:
                        {'lastz', 'chainMerge', 'cleanChains', 'cat', 'chainRun',
                        'fillChains', 'partition'}Please specify existing
                        --project_dir to use this option

cluster_params:
  --executor EXECUTOR   Cluster jobs executor. Please see README.md to get a list
                        of all available systems. Default local
  --executor_queuesize EXECUTOR_QUEUESIZE
                        Controls NextFlow queueSize parameter: maximal number of
                        jobs in the queue (default 2000)
  --executor_partition EXECUTOR_PARTITION
                        Set cluster queue/partition (default batch)
  --cluster_parameters CLUSTER_PARAMETERS
                        Additional cluster parameters, regulates NextFlow
                        clusterOptions (default None)

def_params:
  --lastz LASTZ         Path to specific lastz binary (if needed)
  --seq1_chunk SEQ1_CHUNK
                        Chunk size for target sequence (default 175000000)
  --seq2_chunk SEQ2_CHUNK
                        Chunk size for query sequence (default 50000000)
  --blastz_h BLASTZ_H   BLASTZ_H parameter, (default 2000)
  --blastz_y BLASTZ_Y   BLASTZ_Y parameter, (default 9400)
  --blastz_l BLASTZ_L   BLASTZ_L parameter, (default 3000)
  --blastz_k BLASTZ_K   BLASTZ_K parameter, (default 2400)
  --fill_prepare_memory FILL_PREPARE_MEMORY
                        FILL_PREPARE_MEMORY parameter (default 50000)
  --chaining_memory CHAINING_MEMORY
                        CHAININGMEMORY parameter, (default 50000)
  --chain_clean_memory CHAIN_CLEAN_MEMORY
                        CHAINCLEANMEMORY parameter, (default 100000)
```

### Minimal example
```bash
./make_chains.py ${target_genome_id} ${query_genome_id} ${target_genome_sequence} ${query_genome_sequence} --executor ${cluster_management_system} --project_dir test
 ```

### Output

The pipeline saves the resulting chain file into the "${project_dir}/${target_genome_id}.${query_genome_id}.allfilled.chain.gz" file.

#### Target and query genome IDs

Those are simply strings that differentiate between target and query genome names.
For example, hg38 and mm10 will work.
Can also be human and mouse, even h and m fits.
Technically, any reasonable sequence of letters and numbers should work.

#### Genome sequences

Genome sequences can be provided as *fasta* or *twobit* formatted files.
Please find 2bit file format specification [here](https://genome.ucsc.edu/FAQ/FAQformat.html#format7).

> **Warning**
> If your scaffold names are numbered, such as NC_00000.1 please consider removing scaffold numbers (rename NC_00000.1 to NC_00000 or NC_00000__1, for example). Some tools (especially those included in the make_chains workflow) are not able to correctly handle such identifiers.
> The pipeline will try to trim scaffold numbers automatically to process the data properly.
> Afterwards, it will rename the scaffolds back.
>
> The chain format does not allow spaces in scaffold names because space is the delimiter character for chain headers.
> If the pipeline detects spaces in headers: it will crash.



#### Project directory

Directory where all steps are to be executed (not mandatory argument)
By default pipeline saves all intermediate files in the directory where the pipeline was called.
So, it's strongly recommended to specify the project directory.

#### Executor / available clusters

Executor controls which cluster management system to use.
By default the "local" executor is used - the pipeline utilizes only the machine's CPU.
To run it on a slurm cluster add --executor slurm option.
Please see [nextflow documentation](https://www.nextflow.io/docs/latest/executor.html) to find a list of supported executors.

#### Output
The pipeline saves the resulting chains file to the project directory specified by the respective parameter. The output file is named as follows: ${target_ID}.${query_ID}.allfilled.chain.gz

#### Cleanup
To clean the output up:
```
cd project_dir
./cleanUp.csh
```

## DEF format specification

Pipeline parameters can be also specified in a configuration file.
For backwards compatibility we call it a DEF file.
This file has the following structure:

```txt
KEY=VALUE
```

Available keys are:

- FILL_CHAIN: controls whether pipeline executes the fill_chain step or not, possible values are 0 and 1, default 1
- CLEANCHAIN: whether or not execute chain cleaning step, 0/1, default 1.
- CHAINCLEANMEMORY: amount of memory (in Mb) allocated for chain cleaning cluster job, default 100000
- CHAININGMEMORY: amount of memory (in Mb) allocated for chaining job, 50000 is default.
...

Lastz parameters can also be tuned in the DEF file:
- BLASTZ=lastz
- BLASTZ_H=2000
- BLASTZ_Y=9400
- BLASTZ_L=3000
- BLASTZ_K=2400


To read from a DEF file, plase use the --DEF command line argument.

## Parameters priority

The pipeline collects the parameters from 3 different sources: (1) defaults, (2) command line arguments, (3) DEF file. The same parameter may be tuned in both command line and DEF file, therefore the pipeline uses the following order of precedence:
Defaults < DEF file < Command line arguments

For example, if DEF file says 
SEQ1_CHUNK = 100_000_000
and cmd arg --seq1_chunk equals to 80_000_000
then the final SEQ1_CHUNK value will be 80_000_000
because command line arguments have a higher priority.

## Citation

- Kirilenko BM, Munegowda C, Osipova E, Jebb D, Sharma V, Blumer M, Morales A, Ahmed AW, Kontopoulos DG, Hilgers L, Lindblad-Toh K, Karlsson EK, Zoonomia Consortium, Hiller M. [Integrating gene annotation with orthology inference at scale.](https://www.science.org/stoken/author-tokens/ST-1161/full), Science, 380, 2023 
- Osipova E, Hecker N, Hiller M. [RepeatFiller newly identifies megabases of aligning repetitive sequences and improves annotations of conserved non-exonic elements.](https://academic.oup.com/gigascience/article/8/11/giz132/5631861) GigaScience, 8(11), giz132, 2019
- Suarez H, Langer BE, Ladde P, Hiller M. [chainCleaner improves genome alignment specificity and sensitivity.](https://academic.oup.com/bioinformatics/article/33/11/1596/2929344) Bioinformatics, 33(11), 1596-1603, 2017
- Kent WJ, Baertsch R, Hinrichs A, Miller W, Haussler D. [Evolution's cauldron: Duplication, deletion, and rearrangement in the mouse and human genomes](https://www.pnas.org/doi/10.1073/pnas.1932072100) PNAS, 100(20):11484-9, 2003
