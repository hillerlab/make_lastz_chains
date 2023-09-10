"""Class to manage pipeline steps."""
import os
import subprocess
import json
from constants import Constants
from modules.make_chains_logging import to_log
from steps_implementations.partition import do_partition_for_genome
from steps_implementations.lastz_step import do_lastz

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
    def partition_step(project_dir, params, executables):
        to_log("### Step Partition ###")
        target_partitions_list = do_partition_for_genome(Constants.TARGET_LABEL, project_dir, params, executables)
        query_partitions_list = do_partition_for_genome(Constants.QUERY_LABEL, project_dir, params, executables)
        to_log(f"Num. target partitions: {len(target_partitions_list)}")
        to_log(f"Num. query partitions: {len(query_partitions_list)}")
        to_log(f"Num. lastz jobs: {len(target_partitions_list) * len(query_partitions_list)}")

    @staticmethod
    def lastz_step(project_dir, params, executables):
        to_log("# Step Lastz")
        do_lastz(project_dir, params, executables)

    @staticmethod
    def cat_step(project_dir, params, executables):
        to_log("# Step Cat")
        pass

    @staticmethod
    def chain_run_step(project_dir, params, executables):
        to_log("# Step Chain Run")
        pass

    @staticmethod
    def chain_merge_step(project_dir, params, executables):
        to_log("# Step Chain Merge")
        pass

    @staticmethod
    def fill_chains_step(project_dir, params, executables):
        to_log("# Step Fill Chains")
        pass

    @staticmethod
    def clean_chains_step(project_dir, params, executables):
        to_log("# Step Clean Chains")
        pass
