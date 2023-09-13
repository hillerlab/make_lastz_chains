"""Class that holds paths related to project output and intermediate files."""
import os

from constants import Constants


class ProjectPaths:
    # TODO: implement it, mode all chain_run_dir, chain_out_dir, etc. here
    def __init__(self, project_dir, root_dir, params):
        self.project_dir = project_dir
        self.root_dir = root_dir
        self.steps_json = self._j_abs(project_dir, "steps.json")
        self.log_file = self._j_abs(project_dir, "run.log")

        self.reference_genome = self._j_abs(project_dir, f"{Constants.TARGET_LABEL}.2bit")
        self.query_chrom_sizes = self._j_abs(project_dir, f"{Constants.QUERY_LABEL}.2bit")

        self.reference_partitions = self._j_abs(project_dir, f"{Constants.TARGET_LABEL}_partitions.txt")
        self.query_partitions = self._j_abs(project_dir, f"{Constants.QUERY_LABEL}_partitions.txt")

        self.ref_chrom_sizes = self._j_abs(project_dir, f"{Constants.TARGET_LABEL}.chrom.sizes")
        self.query_chrom_sizes = self._j_abs(project_dir, f"{Constants.QUERY_LABEL}.chrom.sizes")

        self.target_chrom_rename_table = None
        self.query_chrom_rename_table = None

        self.hl_kent_binaries = self._j_abs(root_dir, Constants.KENT_BINARIES_DIRNAME)
        self.chain_clean_micro_env = self._j_abs(root_dir, Constants.CHAIN_CLEAN_MICRO_ENV)

        # LASTZ step
        self.lastz_working_dir = self._j_abs(project_dir, Constants.TEMP_LASTZ_DIRNAME)
        self.project_params_dump = self._j_abs(project_dir, Constants.PARAMS_JSON_FILENAME)
        self.lastz_output_dir = self._j_abs(project_dir, Constants.TEMP_PSL_DIRNAME)
        self.lastz_joblist = self._j_abs(self.lastz_working_dir, Constants.LASTZ_JOBLIST_FILENAME)

        # CAT step
        self.psl_output_dir = self._j_abs(project_dir, Constants.TEMP_PSL_DIRNAME)
        self.cat_out_dirname = self._j_abs(project_dir, Constants.TEMP_CAT_DIRNAME)

        # CHAIN step
        self.chain_run_dir = self._j_abs(project_dir, Constants.TEMP_AXT_CHAIN_DIRNAME)
        self.chain_joblist_path = self._j_abs(self.chain_run_dir, Constants.CHAIN_JOBLIST_FILENAME)
        self.chain_output_dir = self._j_abs(self.chain_run_dir, Constants.CHAIN_RUN_OUT_DIRNAME)
        self.psl_sort_temp_dir = self._j_abs(self.chain_run_dir, Constants.PSL_SORT_TEMP_DIRNAME)
        self.sorted_psl_dir = self._j_abs(self.chain_run_dir, Constants.SORTED_PSL_DIRNAME)
        self.split_psl_dir = self._j_abs(self.chain_run_dir, Constants.SPLIT_PSL_DIRNAME)

        # MERGE CHAIN
        self.merged_chain_filename = f"{params.target_name}.{params.query_name}.all.chain.gz"
        self.merged_chain = os.path.join(self.chain_run_dir, self.merged_chain_filename)

        # FILL CHAIN
        self.filled_chain_filename = f"{params.target_name}.{params.query_name}.filled.chain.gz"
        self.filled_chain = self._j_abs(self.chain_run_dir, self.filled_chain_filename)

        self.fill_chain_run_dir = self._j_abs(self.project_dir, "TEMP_run.fillChain")  # TODO: constant
        self.fill_chain_filled_dir = self._j_abs(self.fill_chain_run_dir, "filledChain")  # TODO: constant
        self.fill_chain_jobs_dir = self._j_abs(self.fill_chain_run_dir, "jobs")

        self.fill_chain_joblist_prepare = self._j_abs(self.fill_chain_run_dir, "jobList_prepare.txt")
        self.fill_chain_joblist_merge = self._j_abs(self.fill_chain_run_dir, "fill_merge.txt")

        # CLEAN CHAIN
        self.before_cleaning_chain_filename = f"{params.target_name}.{params.query_name}.before_cleaning.chain.gz"
        self.before_cleaning_chain = self._j_abs(self.chain_run_dir, self.before_cleaning_chain_filename)
        self.clean_removed_suspects = self._j_abs(self.chain_run_dir, "removed_suspects.bed")
        self.chain_cleaner_log = self._j_abs(self.chain_run_dir, "chain_cleaner.log")
        self._create_dirs()

    @staticmethod
    def _j_abs(*args):
        """Apply both abspath and join."""
        return os.path.abspath(os.path.join(*args))

    def _create_dirs(self):
        directories_to_create = [
            self.lastz_working_dir,
            self.lastz_output_dir,
            self.psl_output_dir,
            self.cat_out_dirname,
            self.chain_run_dir,
            self.psl_sort_temp_dir,
            self.sorted_psl_dir,
            self.split_psl_dir,
            self.chain_output_dir
        ]

        for directory in directories_to_create:
            print(f"making: {directory}")
            os.makedirs(directory, exist_ok=True)

    def set_target_chrom_rename_table(self, table_path):
        self.target_chrom_rename_table = table_path

    def set_query_chrom_rename_table(self, table_path):
        self.query_chrom_rename_table = table_path
