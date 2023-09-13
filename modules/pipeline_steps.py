"""Class to manage pipeline steps."""
import os
import subprocess
import json
from constants import Constants
from modules.make_chains_logging import to_log
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
        to_log("### Step Partition ###")
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

    @staticmethod
    def lastz_step(params, project_paths, executables):
        to_log("# Step Lastz")
        do_lastz(params, project_paths,  executables)

    @staticmethod
    def cat_step(params, project_paths, executables):
        to_log("# Step Cat")
        do_cat(params, project_paths, executables)

    @staticmethod
    def chain_run_step(params, project_paths, executables):
        to_log("# Step Chain Run")
        do_chain_run(params, project_paths, executables)

    @staticmethod
    def chain_merge_step(params, project_paths, executables):
        to_log("# Step Chain Merge")
        do_chains_merge(params, project_paths, executables)

    @staticmethod
    def fill_chains_step(params, project_paths, executables):
        if params.clean_chain == 0:
            # TODO: consider bool here
            to_log("Skipping chain merge")
            return
        to_log("# Step Fill Chains")
        do_chains_fill(params, project_paths, executables)

    @staticmethod
    def clean_chains_step(params, project_paths, executables):
        to_log("# Step Clean Chains")
        if params.clean_chain == 0:
            # TODO: consider bool here
            to_log("Skipping clean chain")
            return
        do_chains_clean(params, project_paths, executables)
