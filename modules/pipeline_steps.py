"""Class to manage pipeline steps."""


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
    def partition_step(project_dir, params):
        pass

    @staticmethod
    def lastz_step(project_dir, params):
        pass

    @staticmethod
    def cat_step(project_dir, params):
        pass

    @staticmethod
    def chain_run_step(project_dir, params):
        pass

    @staticmethod
    def chain_merge_step(project_dir, params):
        pass

    @staticmethod
    def fill_chains_step(project_dir, params):
        pass

    @staticmethod
    def clean_chains_step(project_dir, params):
        pass
