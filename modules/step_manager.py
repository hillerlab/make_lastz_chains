"""Pipeline step manager."""
import json
import os
from modules.pipeline_steps import PipelineSteps


class StepManager:
    def __init__(self, project_dir, args):
        self.project_dir = project_dir
        self.steps_file = os.path.join(self.project_dir, "steps.json")
        self.steps = {
            "partition": "not_started",
            "lastz": "not_started",
            "cat": "not_started",
            "chainRun": "not_started",
            "chainMerge": "not_started",
            "fillChains": "not_started",
            "cleanChains": "not_started",
        }
        self.continue_arg = args.continue_arg if hasattr(args, 'continue_arg') else None
        self.load_or_init_steps()

    def load_or_init_steps(self):
        if os.path.exists(self.steps_file):
            with open(self.steps_file, "r") as f:
                self.steps = json.load(f)
            if self.continue_arg:
                self.set_continue_from_step(self.continue_arg)
        else:
            self.save_steps()

    def save_steps(self):
        with open(self.steps_file, "w") as f:
            json.dump(self.steps, f, indent=4)

    def set_continue_from_step(self, step):
        for s in self.steps.keys():
            self.steps[s] = "not_started" if s == step else "completed"
        self.save_steps()

    def mark_step_status(self, step, status):
        self.steps[step] = status
        self.save_steps()

    def execute_steps(self, project_dir, params, step_executables):
        step_to_function = {
            PipelineSteps.PARTITION: PipelineSteps.partition_step,
            PipelineSteps.LASTZ: PipelineSteps.lastz_step,
            PipelineSteps.CAT: PipelineSteps.cat_step,
            PipelineSteps.CHAIN_RUN: PipelineSteps.chain_run_step,
            PipelineSteps.CHAIN_MERGE: PipelineSteps.chain_merge_step,
            PipelineSteps.FILL_CHAINS: PipelineSteps.fill_chains_step,
            PipelineSteps.CLEAN_CHAINS: PipelineSteps.clean_chains_step
        }

        for step in PipelineSteps.ORDER:
            status = self.steps.get(step, "not_started")
            if status == "not_started":
                self.mark_step_status(step, "running")
                try:
                    # Execute the actual step function here
                    step_to_function[step](project_dir, params)
                    # After successful execution:
                    self.mark_step_status(step, "completed")
                except Exception as e:
                    print(f"An error occurred while executing {step}: {e}")
                    self.mark_step_status(step, "failed")
