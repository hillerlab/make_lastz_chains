"""Module to manage Nextflow processes."""
import os
import shutil
import subprocess
from constants import Constants
from modules.make_chains_logging import to_log


class NextflowWrapper:
    """
    Nextflow manager.
    """

    def __init__(self):
        super().__init__()
        self._process = None
        self.joblist_path = None
        self.config_file = None
        self.return_code = None
        self.execute_dir = None
        self.nf_master_script = Constants.NextflowConstants.NF_SCRIPT_PATH

    def execute(self, joblist_path, config_file, execute_dir, wait=False, **kwargs):
        """Implementation for Nextflow."""
        # define parameters
        self.joblist_path = joblist_path
        self.config_file = config_file
        self.execute_dir = execute_dir
        # create the nextflow process

        cmd = f"nextflow {self.nf_master_script} --joblist {joblist_path}"
        if self.config_file:
            cmd += f" -c {self.config_file}"

        os.makedirs(self.execute_dir, exist_ok=True)
        # log_file_path = os.path.join(execute_dir, "nextflow_process.log")
        # with open(log_file_path, "w") as log_file:
        to_log(f"Parallel manager: pushing job {cmd}")
        self._process = subprocess.Popen(cmd,
                                         shell=True,
                                         # stdout=log_file,
                                         # stderr=log_file,
                                         cwd=self.execute_dir)
        if wait:
            self._process.wait()

    def check_status(self):
        """Check if nextflow jobs are done."""
        if self.return_code:
            return self.return_code
        running = self._process.poll() is None
        if running:
            return None
        self.return_code = self._process.returncode
        return self.return_code

    def cleanup(self):
        nf_dir = os.path.join(self.execute_dir, ".nextflow")
        shutil.rmtree(nf_dir)
