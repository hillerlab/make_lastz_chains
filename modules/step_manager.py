"""Pipeline step manager."""
import json
import os
import traceback
from modules.pipeline_steps import PipelineSteps
from enum import Enum


class StepStatus(Enum):
    NOT_STARTED = "not_started"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"


class StepManager:
    def __init__(self, project_paths, args):
        self.project_dir = project_paths.project_dir
        self.steps_file = project_paths.steps_json
        self.steps = {s: StepStatus.NOT_STARTED for s in PipelineSteps.ORDER}
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
        serializable_steps = {k: v.value for k, v in self.steps.items()}
        with open(self.steps_file, "w") as f:
            json.dump(serializable_steps, f, indent=4)

    def set_continue_from_step(self, step):
        for s in self.steps.keys():
            self.steps[s] = StepStatus.NOT_STARTED if s == step else StepStatus.COMPLETED
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
                    step_to_function[step](params, project_paths, step_executables)
                    # After successful execution:
                    self.mark_step_status(step, StepStatus.COMPLETED)
                except Exception as e:
                    print(f"An error occurred while executing {step}: {e}")
                    traceback.print_exc()
                    self.mark_step_status(step, StepStatus.FAILED)
                    break
