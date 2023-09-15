"""Class to manage project directory."""
import os
import shutil
# import json


class OutputDirectoryManager:
    def __init__(self, project_args):
        self.project_dir = os.path.abspath(project_args.project_dir) if project_args.project_dir else os.getcwd()
        self.force_override = project_args.force
        self.continue_from_step = project_args.continue_from_step
        self.__create_directory_if_possible()

    def __create_directory_if_possible(self):
        if os.path.exists(self.project_dir) and self.force_override:
            shutil.rmtree(self.project_dir)
            os.makedirs(self.project_dir)
        elif os.path.exists(self.project_dir) and self.continue_from_step:
            # self.__check_whether_override()
            pass  # just do nothing I guess
        else:
            os.makedirs(self.project_dir)

    def __check_whether_override(self):
        """Check whether it's possible to run script on the already existing directory."""
        raise RuntimeError("Directory already exists.")
