"""Class to manage project directory."""
import os
import json
import shutil

class OutputDirectoryManager:
    def __init__(self, project_args):
        self.project_dir = os.path.abspath(project_args.project_dir) if project_args.project_dir else os.getcwd()
        self.force_override = project_args.force
        self.__create_directory_if_possible()
        self.__dump_args_as_json(project_args)

    def __create_directory_if_possible(self):
        if os.path.exists(self.project_dir) and self.force_override:
            shutil.rmtree(self.project_dir)
            os.makedirs(self.project_dir)
        elif os.path.exists(self.project_dir):
            self.__check_whether_override()
        else:
            os.makedirs(self.project_dir)

    def __check_whether_override(self):
        """Check whether it's possible to run script on the already existing directory."""
        raise RuntimeError("Directory already exists.")

    def __dump_args_as_json(self, args):
        args_dict = vars(args)
        with open(os.path.join(self.project_dir, "project_args.json"), "w") as f:
            json.dump(args_dict, f, indent=4)
