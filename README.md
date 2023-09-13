# Make Lastz Chains
# THIS VERSION IS UNDER DEVELOPMENT

[![Code style: black](https://img.shields.io/badge/code%20style-black-000000.svg)](https://github.com/psf/black)
![version](https://img.shields.io/badge/version-0.0.1-blue)
[![made-with-Nextflow](https://img.shields.io/badge/Made%20with-Nextflow-23aa62.svg)](https://www.nextflow.io/)

To test:
`./make_chains.py target query test_data/test_reference.fa test_data/test_query.fa --pd test_out -f`
`./make_chains.py target query test_data/humanChrX.fa test_data/mm39ChrX.fa --pd test_out_2 -f`
`./make_chains.py target query test_data/humanChrX.fa test_data/mm39ChrX.fa --pd test_out_2 --cfs chain_run --kt`

To not forget:

- gcc command to build chain_bst_lib.so

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
./install_dependencies__OLD.py
```

### Usage

The script to be called is *make_chains.py*

```

### Minimal example
```bash
./make_chains__OLD.py ${target_genome_id} ${query_genome_id} ${target_genome_sequence} ${query_genome_sequence} --executor ${cluster_management_system} --project_dir test
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
By default, the "local" executor is used - the pipeline utilizes only the machine's CPU.
To run it on a slurm cluster add --executor slurm option.
Please see [nextflow documentation](https://www.nextflow.io/docs/latest/executor.html) to find a list of supported executors.

#### Output
The pipeline saves the resulting chains file to the project directory specified by the respective parameter.
The output file is named as follows: ${target_ID}.${query_ID}.allfilled.chain.gz

## Citation

- Kirilenko BM, Munegowda C, Osipova E, Jebb D, Sharma V, Blumer M, Morales A, Ahmed AW, Kontopoulos DG, Hilgers L, Lindblad-Toh K, Karlsson EK, Zoonomia Consortium, Hiller M. [Integrating gene annotation with orthology inference at scale.](https://www.science.org/stoken/author-tokens/ST-1161/full), Science, 380, 2023 
- Osipova E, Hecker N, Hiller M. [RepeatFiller newly identifies megabases of aligning repetitive sequences and improves annotations of conserved non-exonic elements.](https://academic.oup.com/gigascience/article/8/11/giz132/5631861) GigaScience, 8(11), giz132, 2019
- Suarez H, Langer BE, Ladde P, Hiller M. [chainCleaner improves genome alignment specificity and sensitivity.](https://academic.oup.com/bioinformatics/article/33/11/1596/2929344) Bioinformatics, 33(11), 1596-1603, 2017
- Kent WJ, Baertsch R, Hinrichs A, Miller W, Haussler D. [Evolution's cauldron: Duplication, deletion, and rearrangement in the mouse and human genomes](https://www.pnas.org/doi/10.1073/pnas.1932072100) PNAS, 100(20):11484-9, 2003
