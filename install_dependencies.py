#!/usr/bin/env python3
"""Script to download UCSC Kent binaries necessary to run the pipeline."""
import shutil
import os
import subprocess
import sys
import platform
from constants import Constants

__author__ = "Bogdan M. Kirilenko"

SCRIPT_LOCATION = os.path.abspath(os.path.dirname(__file__))
DESTINATION_DIR = os.path.join(SCRIPT_LOCATION, "HL_kent_binaries")
HG_DOWNLOAD_LINK = "https://hgdownload.cse.ucsc.edu/admin/exe/"

# OS related
OS_NAME = platform.system()
LINUX = "Linux"
MAC = "Darwin"
WINDOWS = "Windows"  # not really supported


if OS_NAME == LINUX:
    HG_DOWNLOAD_DIRNAME = "linux.x86_64"
elif OS_NAME == MAC:
    print("Warning! Not recommended to run on macOS.")
    HG_DOWNLOAD_DIRNAME = "macOSX.x86_64"
elif OS_NAME == WINDOWS:
    sys.exit("Error! Windows operating system is not supported")
else:
    sys.exit(f"Error! {OS_NAME} is not supported")


def make_executable(path):
    """Like chmod +x.

    Taken from
    https://stackoverflow.com/questions/12791997/how-do-you-do-a-simple-chmod-x-from-within-python
    """
    mode = os.stat(path).st_mode
    mode |= (mode & 0o444) >> 2  # copy R bits to X
    os.chmod(path, mode)


def process_tool(tool_name):
    binary_path = shutil.which(tool_name)
    if binary_path:
        print(f"{tool_name} is already included in $PATH at: {binary_path}")
        return
    # not found, need to acquire
    download_link = f"{HG_DOWNLOAD_LINK}/{HG_DOWNLOAD_DIRNAME}/{tool_name}"
    # destination dir for all binaries necessary to run the pipeline is HL_kent_binaries
    destination = os.path.join(DESTINATION_DIR, tool_name)

    if os.path.isfile(destination):
        # if already in destination directory: just skip it
        print(f"{tool_name} is already downloaded")
        return

    # trigger wget to download the tool
    load_cmd = ["wget", "-O", destination, download_link]
    cmd_result = subprocess.run(load_cmd, capture_output=True, text=True)

    # If wget was unable to download the tool, it will create and empty file
    # at destination (sometimes?).
    if cmd_result.returncode == 0 and os.path.isfile(destination) and os.path.getsize(destination) > 0:
        make_executable(destination)
        print(f"Successfully downloaded {tool_name}")
    else:
        if os.path.exists(destination):
            os.remove(destination)  # remove the empty file if it exists
        print(f"Error! Could not download {tool_name}.")
        print(f"Error details: {cmd_result.stderr}")


def check_lastz():
    lastz_found = shutil.which("lastz")
    if lastz_found:
        print("Lastz installation found")
    else:
        print("!Please download and install Lastz")


def main():
    print("# Started collecting dependencies.")

    # iterate through necessary binaries
    for attr, tool_name in vars(Constants.ToolNames).items():
        if attr.startswith("__"):
            continue
        if tool_name == "lastz":
            check_lastz()
            continue
        print(f"* processing {tool_name}")
        process_tool(tool_name)


if __name__ == "__main__":
    main()
