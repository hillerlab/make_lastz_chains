"""Pipeline step manager."""
import json
import os
import sys
import traceback
from modules.make_chains_logging import to_log
from modules.pipeline_steps import PipelineSteps
from modules.step_status import StepStatus


class StepManager:
    def __init__(self, project_paths, args):
        self.project_dir = project_paths.project_dir
        self.steps_file = project_paths.steps_json
        self.steps = {s: StepStatus.NOT_STARTED for s in PipelineSteps.ORDER}
        self.continue_from_step = args.continue_from_step
        self.load_or_init_steps()

    def load_or_init_steps(self):
        if os.path.exists(self.steps_file):
            with open(self.steps_file, "r") as f:
                with open(self.steps_file, "r") as f:
                    loaded_steps = json.load(f)
                self.steps = {k: StepStatus.from_string(v) for k, v in loaded_steps.items()}
            if self.continue_from_step:
                self.set_continue_from_step(self.continue_from_step)
        else:
            self.save_steps()

    def save_steps(self):
        serializable_steps = {k: v.value for k, v in self.steps.items()}
        with open(self.steps_file, "w") as f:
            json.dump(serializable_steps, f, indent=4)

    def set_continue_from_step(self, step_to_start_from):
        to_log(f"### Trying to continue from step: {step_to_start_from}")
        mark_following = False
        for step in PipelineSteps.ORDER:
            if step_to_start_from == step:
                self.steps[step] = StepStatus.NOT_STARTED
                mark_following = True
            elif mark_following:
                self.steps[step] = StepStatus.NOT_STARTED
            elif mark_following is False and self.steps[step] == StepStatus.FAILED:
                raise ValueError(f"Cannot start from {step_to_start_from}: {step} failed")
            elif mark_following is False and self.steps[step] == StepStatus.NOT_STARTED:
                raise ValueError(f"Cannot start from {step_to_start_from}: {step} was not done")
        self.save_steps()

    def mark_step_status(self, step, status):
        self.steps[step] = status
        self.save_steps()

    def execute_steps(self, params, step_executables, project_paths):
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
            status = self.steps.get(step, StepStatus.NOT_STARTED)
            if status == StepStatus.NOT_STARTED:
                self.mark_step_status(step, StepStatus.RUNNING)
                try:
                    # Execute the actual step function here
                    step_result = step_to_function[step](params, project_paths, step_executables)
                    step_result = step_result if step_result else StepStatus.COMPLETED
                    # After successful execution:
                    self.mark_step_status(step, step_result)
                except Exception as e:
                    to_log(f"An error occurred while executing {step}: {e}")
                    traceback.print_exc()
                    self.mark_step_status(step, StepStatus.FAILED)
                    sys.exit(1)
