"""Class that holds paths to all necessary executables."""
import os
import shutil
from constants import Constants


class StepExecutables:
    def __init__(self, root_dir):
        self.root_dir = root_dir
        self.hl_kent_binaries_path = os.path.join(root_dir, Constants.KENT_BINARIES_DIRNAME)

        self.partition_script = self.__find_script("partitionSequence.pl")
        self.lastz_wrapper = self.__find_script("run_lastz.py")
        self.split_chain_into_random_parts = self.__find_script("split_chain_into_random_parts.pl")
        self.fa_to_two_bit = self.__find_binary(Constants.ToolNames.FA_TO_TWO_BIT)
        self.two_bit_to_fa = self.__find_binary(Constants.ToolNames.TWO_BIT_TO_FA)
        self.psl_sort_acc = self.__find_binary(Constants.ToolNames.PSL_SORT_ACC)
        self.axt_chain = self.__find_binary(Constants.ToolNames.AXT_CHAIN)
        self.chain_anti_repeat = self.__find_binary(Constants.ToolNames.CHAIN_ANTI_REPEAT)
        self.chain_merge_sort = self.__find_binary(Constants.ToolNames.CHAIN_MERGE_SORT)
        self.chain_cleaner = self.__find_binary(Constants.ToolNames.CHAIN_CLEANER)

    def __find_script(self, script_name):
        rel_path = os.path.join(self.root_dir, "standalone_scripts", script_name)
        abs_path = os.path.abspath(rel_path)
        if not os.path.isfile(abs_path):
            raise ValueError(f"Error! Cannot locate script: {script_name}")
        return abs_path

    def __find_binary(self, binary_name):
        binary_path = shutil.which(binary_name)

        if binary_path is None:
            # Try to find it in the HL_kent_binaries directory
            binary_path = os.path.join(self.hl_kent_binaries_path, binary_name)

            if not os.path.exists(binary_path):
                raise ValueError(
                    f"Error! Cannot locate binary: {binary_name} - not "
                    f"in $PATH and not in {self.hl_kent_binaries_path}"
                )
        return binary_path
