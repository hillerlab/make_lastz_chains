"""Module to manage Nextflow processes."""
import os
import shutil
import subprocess
from constants import Constants
from modules.make_chains_logging import to_log
from modules.error_classes import NextflowProcessError


class NextflowConfig:
    """Model for a config file."""
    def __init__(self, executor, memory, time, label, config_dir, **kwargs):
        self.executor = executor
        self.memory = 4
        self.time = time
        self.label = label
        self.config_dir = config_dir
        self.queue = kwargs.get("queue", None)
        self.cpus = 1  # always a fixed number
        self.config_path = None
        self.queue_size = Constants.NextflowConstants.DEFAULT_QUEUE_SIZE

    def dump_to_file(self):
        """Write the respective config file,"""
        filename = f"{self.label}_config.nf"
        self.config_path = os.path.join(self.config_dir, filename)
        f = open(self.config_path, "w")
        f.write(f"// Nextflow config for {self.label} jobs\n")
        f.write(f"process.executor = '{self.executor}'\n")
        f.write(f"process.memory = {{ {self.memory}.GB * task.attempt }}\n")
        f.write("process.time = { 0.5.hour*task.attempt }\n")
        f.write(f"process.cpus = '{self.cpus}'\n")
        if self.queue:
            f.write(f"process.queue = '{self.queue}'\n")
        f.write(f"executor.queueSize = '{self.queue_size}'\n")
        f.write("process.maxRetries = 5\n")
        f.write("process.errorStrategy = 'retry'\n")
        f.write("process.maxErrors = '-1'\n")
        f.close()
        return self.config_path

    def remove_config(self):
        if self.config_path is None:
            return
        os.remove(self.config_path) if os.path.isfile(self.config_path) else None


class NextflowWrapper:
    """
    Nextflow manager.
    """

    def __init__(self, nextflow_exec):
        self.nextflow_exec = nextflow_exec
        self._process = None
        self.joblist_path = None
        self.config_file = None
        self.config_instance = None
        self.return_code = None
        self.execute_dir = None
        self.label = None
        self.nf_master_script = Constants.NextflowConstants.NF_SCRIPT_PATH

    def execute(self, joblist_path: str, config_instance: NextflowConfig, execute_dir: str, wait=False, **kwargs):
        """Implementation for Nextflow."""
        # define parameters
        self.joblist_path = joblist_path
        self.config_instance = config_instance
        self.execute_dir = execute_dir
        self.label = kwargs.get("label", "")

        # create the nextflow process
        self.config_file = config_instance.dump_to_file()
        cmd = f"{self.nextflow_exec} {self.nf_master_script} --joblist {joblist_path} -c {self.config_file}"

        os.makedirs(self.execute_dir, exist_ok=True)
        to_log(f"Parallel manager: pushing job {cmd}")
        self._process = subprocess.Popen(cmd,
                                         shell=True,
                                         # stdout=log_file,
                                         # stderr=log_file,
                                         cwd=self.execute_dir)
        if wait:
            self._process.wait()

    def _acquire_return_code(self):
        running = self._process.poll() is None
        if running:
            return
        self.return_code = self._process.returncode

    def check_status(self):
        """Check if nextflow jobs are done."""
        if self.return_code:
            return self.return_code
        self._acquire_return_code()
        return self.return_code

    def check_failed(self, dont_clean_logs=False):
        self._acquire_return_code()
        if self.return_code is None:
            return
        if self.return_code == 0:
            to_log(f"\n### Nextflow process {self.label} finished successfully")
            return

        to_log(f"\n### Error! The nextflow process {self.label} crashed!")
        if dont_clean_logs is False:
            to_log(f"Please look at the logs in the {self.execute_dir}")
        else:
            self.cleanup()
        raise NextflowProcessError(f"Jobs for {self.label} at {self.joblist_path} died")

    def cleanup(self):
        """Nextflow produces a bunch of files: to be removed."""
        nf_dir = os.path.join(self.execute_dir, ".nextflow")
        work_dir = os.path.join(self.execute_dir, "work")
        shutil.rmtree(nf_dir)
        shutil.rmtree(work_dir)
        self.config_instance.remove_config()


def execute_nextflow_step(nextflow_exec,
                          executor,
                          memory_req,
                          time_req,
                          step_label,
                          config_dir,
                          queue,
                          joblist,
                          run_dir):
    """

    Execute Nextflow Step

    Executes a Nextflow step using the specified parameters.
    Facilitates the cooperation between NextflowConfig and NextflowWrapper classes.

    Parameters:
    - nextflow_exec (str): The path to the Nextflow executable.
    - executor (str): The Nextflow executor to use.
    - memory_req (str): The memory requirement for the step.
    - time_req (str): The time requirement for the step.
    - step_label (str): The label for the step.
    - config_dir (str): The directory to find the Nextflow configuration files.
    - queue (str): The queue to submit the job to.
    - joblist (str): The list of jobs to execute.
    - run_dir (str): The directory where the Nextflow run will be executed.

    Returns:
    None

    Raises:
    - NextflowProcessError: If the Nextflow process fails.

    """
    nextflow_config = NextflowConfig(executor, memory_req, time_req, step_label, config_dir=config_dir, queue=queue)
    nextflow_manager = NextflowWrapper(nextflow_exec)
    nextflow_manager.execute(joblist, nextflow_config, run_dir, wait=True, label=step_label)
    nextflow_manager.check_failed()
    nextflow_manager.cleanup()
