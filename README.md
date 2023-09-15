# Make Lastz Chains
# THIS VERSION IS UNDER DEVELOPMENT

[![Code style: black](https://img.shields.io/badge/code%20style-black-000000.svg)](https://github.com/psf/black)
![version](https://img.shields.io/badge/version-2.0.0%20alpha-blue)
[![made-with-Nextflow](https://img.shields.io/badge/Made%20with-Nextflow-23aa62.svg)](https://www.nextflow.io/)

Portable Hillerlab solution for generating pairwise genome alignment chains.
These chains can be used as input for [TOGA](https://github.com/hillerlab/TOGA) or for generating multiz alignments.

![Abstract Chains](readme_images/abstract_chains.png)

Chains explained:
http://genomewiki.ucsc.edu/index.php/Chains_Nets

Chain format specification:
https://genome.ucsc.edu/goldenPath/help/chain.html

## Usage

⚠️ Although the pipeline works on macOS, it is strongly recommended to run it on a Linux-based machine.

### Installation:

Install nextflow:
https://www.nextflow.io/docs/latest/getstarted.html

Please note that Nextflow requires a java runtime.

Then do the following:

```bash
git clone git@github.com:hillerlab/make_lastz_chains.git
cd make_lastz_chains
# install python packages (just one actually)
pip3 install -r requirements.txt
# The pipeline requires many UCSC Kent binaries,
# they can be downloaded using this script,
# unless they are already in the $PATH:
./install_dependencies.py
```

Please also acquire `lastz` and add a binary to your `$PATH`.

### Running the pipeline

The script to be called is `make_chains.py`.

```bash
### Minimal example
./make_chains__OLD.py ${target_genome_id} ${query_genome_id} ${target_genome_sequence} ${query_genome_sequence} --executor ${cluster_management_system} --project_dir test
 ```

A quick test sample:

```bash
./make_chains.py target query test_data/test_reference.fa test_data/test_query.fa --pd test_out -f
```

#### Target and query genome IDs

These are simply strings that differentiate between the target and query genome names.
For example, hg38 and mm10 will work.
They could also be human and mouse, or even h and m.
Technically, any reasonable sequence of letters and numbers should work.

#### Genome sequences

Genome sequences can be provided in either `fasta` or `twobit` formats.
Please find the 2bit file format specification [here](https://genome.ucsc.edu/FAQ/FAQformat.html#format7).

⚠️ **Warning**

If your scaffold names are numbered, such as NC_00000.1, consider removing the scaffold numbers
(rename NC_00000.1 to NC_00000 or NC_00000__1, for example). Some tools, especially those included
in the make_chains workflow, may not handle such identifiers correctly.
The pipeline will attempt to trim scaffold numbers automatically for proper data processing.

The chain format does not allow spaces in scaffold names,
as spaces are the delimiter characters for chain headers.
If the pipeline detects spaces in the chain headers, it will crash.

If you wish to rename reference and query chromosomes or scaffolds back to their original names,
please use the standalone_scripts/rename_chromosomes_back.py script.

#### Project directory

This is the directory where all steps will be executed (not a mandatory argument).
By default, the pipeline saves all intermediate files in the directory where the pipeline was initiated.
Therefore, it's strongly recommended to specify the project directory.

#### Executor / available clusters

The executor controls which cluster management system to use.
By default, the `local` executor is used, meaning the pipeline utilizes only the machine's CPU.
To run it on a Slurm cluster, add the `--executor` slurm option.
Please see the Nextflow documentation for a list of supported executors.

#### Reading pipeline parameters from JSON file

`TO BE FILLED`
`--params_from_file {params_json}`

### Output
The pipeline saves the resulting chain file in the project directory specified by the respective parameter.
The output file is named as follows:  `${target_ID}.${query_ID}.final.chain.gz`

## Citation

- Kirilenko BM, Munegowda C, Osipova E, Jebb D, Sharma V, Blumer M, Morales A, Ahmed AW, Kontopoulos DG, Hilgers L, Lindblad-Toh K, Karlsson EK, Zoonomia Consortium, Hiller M. [Integrating gene annotation with orthology inference at scale.](https://www.science.org/stoken/author-tokens/ST-1161/full), Science, 380, 2023 
- Osipova E, Hecker N, Hiller M. [RepeatFiller newly identifies megabases of aligning repetitive sequences and improves annotations of conserved non-exonic elements.](https://academic.oup.com/gigascience/article/8/11/giz132/5631861) GigaScience, 8(11), giz132, 2019
- Suarez H, Langer BE, Ladde P, Hiller M. [chainCleaner improves genome alignment specificity and sensitivity.](https://academic.oup.com/bioinformatics/article/33/11/1596/2929344) Bioinformatics, 33(11), 1596-1603, 2017
- Kent WJ, Baertsch R, Hinrichs A, Miller W, Haussler D. [Evolution's cauldron: Duplication, deletion, and rearrangement in the mouse and human genomes](https://www.pnas.org/doi/10.1073/pnas.1932072100) PNAS, 100(20):11484-9, 2003
