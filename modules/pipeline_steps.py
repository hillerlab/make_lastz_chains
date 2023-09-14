"""Class to manage pipeline steps."""
from constants import Constants
from modules.make_chains_logging import to_log
from modules.step_status import StepStatus
from steps_implementations.partition import do_partition_for_genome
from steps_implementations.lastz_step import do_lastz
from steps_implementations.cat_step import do_cat
from steps_implementations.chain_run_step import do_chain_run
from steps_implementations.chain_merge_step import do_chains_merge
from steps_implementations.fill_chain_step import do_chains_fill
from steps_implementations.clean_chain_step import do_chains_clean


class PipelineSteps:
    PARTITION = "partition"
    LASTZ = "lastz"
    CAT = "cat"
    CHAIN_RUN = "chain_run"
    CHAIN_MERGE = "chain_merge"
    FILL_CHAINS = "fill_chains"
    CLEAN_CHAINS = "clean_chains"

    ORDER = [
        PARTITION,
        LASTZ,
        CAT,
        CHAIN_RUN,
        CHAIN_MERGE,
        FILL_CHAINS,
        CLEAN_CHAINS,
    ]

    @staticmethod
    def partition_step(params, project_paths, executables):
        to_log("\n### Partition Step ###\n")
        target_partitions_list = do_partition_for_genome(Constants.TARGET_LABEL,
                                                         params,
                                                         project_paths,
                                                         executables)
        query_partitions_list = do_partition_for_genome(Constants.QUERY_LABEL,
                                                        params,
                                                        project_paths,
                                                        executables)
        to_log(f"Num. target partitions: {len(target_partitions_list)}")
        to_log(f"Num. query partitions: {len(query_partitions_list)}")
        to_log(f"Num. lastz jobs: {len(target_partitions_list) * len(query_partitions_list)}")
        return StepStatus.COMPLETED

    @staticmethod
    def lastz_step(params, project_paths, executables):
        to_log("\n### Lastz Alignment Step ###\n")
        do_lastz(params, project_paths,  executables)
        return StepStatus.COMPLETED

    @staticmethod
    def cat_step(params, project_paths, executables):
        to_log("\n### Concatenating Lastz Results (Cat) Step ###\n")
        do_cat(params, project_paths, executables)
        return StepStatus.COMPLETED

    @staticmethod
    def chain_run_step(params, project_paths, executables):
        to_log("\n### Build Chains Step ###\n")
        do_chain_run(params, project_paths, executables)
        return StepStatus.COMPLETED

    @staticmethod
    def chain_merge_step(params, project_paths, executables):
        to_log("\n### Merge Chains Step ###\n")
        do_chains_merge(params, project_paths, executables)
        return StepStatus.COMPLETED

    @staticmethod
    def fill_chains_step(params, project_paths, executables):
        if params.fill_chain is False:
            # TODO: consider bool here
            to_log("### !Skipping Fill Chains ###")
            return StepStatus.SKIPPED
        to_log("\n### Fill Chains Step ###\n")
        do_chains_fill(params, project_paths, executables)
        return StepStatus.COMPLETED

    @staticmethod
    def clean_chains_step(params, project_paths, executables):
        if params.clean_chain is False:
            # TODO: consider bool here
            to_log("### !Skipping Clean Chains ###")
            return StepStatus.SKIPPED
        to_log("\n### Clean Chains Step ###\n")
        do_chains_clean(params, project_paths, executables)
        return StepStatus.COMPLETED
