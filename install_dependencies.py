#!/usr/bin/env python3
"""Download all necessary dependencies."""
import subprocess
import os
import platform
import sys
import shutil
import argparse

"""
ISSUES

TOOD: add docker
Replace rsync calls with some more stable way
"""

DESCRIPTION = """
TO BE FILLED
"""

# download links
HGDOWNLOAD = "rsync://hgdownload.soe.ucsc.edu/genome/admin/exe/"
HGDOWNLOAD_HTTPS = "https://hgdownload.cse.ucsc.edu/admin/exe/"

# binaries names
class Required:
    AXTCHAIN = "axtChain"
    FATOTWOBIT = "faToTwoBit"
    TWOBITTOFA = "twoBitToFa"
    CHAINSORT = "chainSort"
    CHAINSCORE = "chainScore"
    CHAINNET = "chainNet"  # TODO: check later if needed
    LASTZ = "lastz"
    GENSUB2 = "gensub2"
    AXTTOPSL = "axtToPsl"
    CHAINANTIREPEAT = "chainAntiRepeat"
    CHAINMERGESORT = "chainMergeSort"
    LASTZ = "lastz"
    PSLSORTACC = "pslSortAcc"
    CHAINCLEANER = "chainCleaner"

LASTZ_DOWNLOADABLE = "lastz-1.04.00"

# output directories
BINARIES_DIR = "kent_binaries"
HL_EXEC_DIR = "HL_kent_binaries"

# channels related
CONDA = "conda"
DOCKER = "docker"
RSYNC_CMD = "rsync -aPt --update"

# OS related
OS_NAME = platform.system()
LINUX = "Linux"
MAC = "Darwin"
WINDOWS = "Windows"  # not really supported

if OS_NAME == LINUX:
    HGDOWNLOAD_DIRNAME = "linux.x86_64"
elif OS_NAME == MAC:
    HGDOWNLOAD_DIRNAME = "macOSX.x86_64"
elif OS_NAME == WINDOWS:
    sys.exit("Error! Windows operating system is not supported")
else:
    sys.exit(f"Error! {OS_NAME} is not supported")

# download statuses
SUCCESS = "SUCCESS"
TO_ADD = "TO_ADD"
FAILED = "FAILED"

# compiling from scratch
CFLAGS = "-Wall -Wextra -O2 -g -std=c99"

# for chain cleaner:
# chainNet - available in conda

HL_PATH = os.path.abspath(os.path.join(os.getcwd(), BINARIES_DIR))


def make_executable(path):
    """Like chmod +x.

    Taken from
    https://stackoverflow.com/questions/12791997/how-do-you-do-a-simple-chmod-x-from-within-python
    """
    mode = os.stat(path).st_mode
    mode |= (mode & 0o444) >> 2  # copy R bits to X
    os.chmod(path, mode)


def _is_already_installed(binary_name):
    """Check whether package is already installed."""
    which_ret = shutil.which(binary_name)
    if which_ret:
        print(f"{binary_name} is already installed at {which_ret}")
        return True
    else:
        return False


def _check_conda_available():
    """Check whether conda is available."""
    which_conda = shutil.which(CONDA)
    if which_conda:
        print(f"Found conda installation at {which_conda}")
        return True
    else:
        print("!Warning! Conda is not installed or is not reachable")
        return False


def _check_docker_available():
    """Check whether conda is available."""
    which_conda = shutil.which(DOCKER)
    if which_conda:
        print(f"Found docker installation at {which_conda}")
        return True
    else:
        print("!Warning! Docker is not installed or is not reachable")
        return False


### DIFFERENT WAYS TO DOWNLOAD THE PACKAGE >>>>>>
def download_from_hg(binary_name):
    """Download binary directly from HG storage."""
    # TODO: rewrite to wget; rsync may stuck on some systems
    # for some unclear reason
    print(f"Downloading {binary_name} directly from HG downloads storage")
    # link = f"{HGDOWNLOAD}/{HGDOWNLOAD_DIRNAME}/{binary_name}"
    link = f"{HGDOWNLOAD_HTTPS}/{HGDOWNLOAD_DIRNAME}/{binary_name}"

    # load_cmd = f"{RSYNC_CMD} {link} {BINARIES_DIR}/"
    dest = f"{BINARIES_DIR}/{binary_name}"
    load_cmd = f"wget -O {dest} {link}"
    
    if os.path.isfile(dest):
        print(f"{dest} is already downloaded")
        return True
    rc = subprocess.call(load_cmd, shell=True)
    if rc == 0:
        print(f"{binary_name} sucessfully downloaded")
        make_executable(dest)
        # TODO: test that binary executes
        return True
    else:
        print(f"!Command failed\n{load_cmd}!")
        return False


def download_with_conda(conda_binary_name, binary_name):
    """Install package with Conda."""
    conda_command = f"conda install -y -c bioconda {conda_binary_name}"
    rc = subprocess.call(conda_command, shell=True)
    if rc != 0:
        print(f"Failed {binary_name} install with Conda")
        return False

    which_fa_to_two_bit = shutil.which(binary_name)
    if which_fa_to_two_bit is None:
        print(f"cannot locate {binary_name} after conda install...")
        return False
    print(f"Can locate {binary_name} - already added to $PATH")
    return True


### <<<<<< DIFFERENT WAYS TO DOWNLOAD THE PACKAGE


### AXTCHAIN
def acquire_axtchain(conda_available):
    """Acquire axtChain binary and test."""
    print("\n### Acquiring axtChain ###")
    if _is_already_installed(Required.AXTCHAIN):
        return SUCCESS
    # also available as docker:
    # https://quay.io/repository/biocontainers/ucsc-axtchain
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-axtchain"
        is_ok = download_with_conda(conda_name, Required.AXTCHAIN)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.AXTCHAIN} with conda failed, trying direct download..."

    is_downloaded = download_from_hg(Required.AXTCHAIN)
    return TO_ADD if is_downloaded else FAILED


### FATOTWOBIT
def acquire_fatotwobit(conda_available):
    """Acquire faToTwoBit."""
    # also available as docker container:
    # https://quay.io/repository/biocontainers/ucsc-fatotwobit
    print("\n### Acquiring faToTwoBit ###")
    if _is_already_installed(Required.FATOTWOBIT):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-fatotwobit"
        is_ok = download_with_conda(conda_name, Required.FATOTWOBIT)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.FATOTWOBIT} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.FATOTWOBIT)
    return TO_ADD if is_downloaded else FAILED


### TWOBITTOFA
def acquire_twobittofa(conda_available):
    """Acquire faToTwoBit."""
    # also available as docker container:
    # https://quay.io/repository/biocontainers/ucsc-fatotwobit
    print("\n### Acquiring twoBitToFa ###")
    if _is_already_installed(Required.TWOBITTOFA):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-twobittofa"
        is_ok = download_with_conda(conda_name, Required.TWOBITTOFA)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.TWOBITTOFA} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.TWOBITTOFA)
    return TO_ADD if is_downloaded else FAILED


### CHAINSORT
def acquire_chainsort(conda_available):
    """Acquire chain sort."""
    # available as container at:
    # https://quay.io/repository/biocontainers/ucsc-chainsort
    print("\n### Acquiring chainSort ###")
    if _is_already_installed(Required.CHAINSORT):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-chainsort"
        is_ok = download_with_conda(conda_name, Required.CHAINSORT)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.CHAINSORT} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.CHAINSORT)
    return TO_ADD if is_downloaded else FAILED


#GENSUB2
def acquire_gensub2(conda_available):
    """Acquire gensub2."""
    print("\n### Acquiring gensub2 ###")
    if _is_already_installed(Required.GENSUB2):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-gensub2"
        is_ok = download_with_conda(conda_name, Required.GENSUB2)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.GENSUB2} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.GENSUB2)
    return TO_ADD if is_downloaded else FAILED


### AXTTOPSL
def acquire_axttopsl(conda_available):
    """Acquire axtToPsl."""
    print("\n### Acquiring axtToPsl ###")
    if _is_already_installed(Required.AXTTOPSL):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-axttopsl"
        is_ok = download_with_conda(conda_name, Required.AXTTOPSL)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.AXTTOPSL} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.AXTTOPSL)
    return TO_ADD if is_downloaded else FAILED



### CHAINANTIREPEAR
def acquire_chainantirepeat(conda_available):
    """Acquire chainAntiRepeat"""
    print(f"\n### Acquiring {Required.CHAINANTIREPEAT} ###")
    if _is_already_installed(Required.CHAINANTIREPEAT):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-chainantirepeat"
        is_ok = download_with_conda(conda_name, Required.CHAINANTIREPEAT)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.CHAINANTIREPEAT} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.CHAINANTIREPEAT)
    return TO_ADD if is_downloaded else FAILED


### CHAINMERGESORT
def acquire_chainmergesort(conda_available):
    """Acquire chainMergeSort"""
    print(f"\n### Acquiring {Required.CHAINMERGESORT} ###")
    if _is_already_installed(Required.CHAINMERGESORT):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-chainmergesort"
        is_ok = download_with_conda(conda_name, Required.CHAINMERGESORT)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.CHAINMERGESORT} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.CHAINMERGESORT)
    return TO_ADD if is_downloaded else FAILED


### CHAIN SCORE
def acquire_chainscore():
    print(f"\n### Acquiring {Required.CHAINSCORE} ###")
    is_downloaded = download_from_hg(Required.CHAINSCORE)
    return TO_ADD if is_downloaded else FAILED


### PSLSORTACC
def acquire_pslsortacc():
    print(f"\n### Acquiring {Required.PSLSORTACC} ###")
    is_downloaded = download_from_hg(Required.PSLSORTACC)
    return TO_ADD if is_downloaded else FAILED


### CHAINCLEANER
def acquire_chaincleaner():
    print(f"\n### Acquiring {Required.CHAINCLEANER} ###")
    is_downloaded = download_from_hg(Required.CHAINCLEANER)
    return TO_ADD if is_downloaded else FAILED


### LASTZ
def acquire_lastz(conda_available):
    print("\n### Acquiring lastz ###")
    if _is_already_installed(Required.LASTZ):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "lastz"
        is_ok = download_with_conda(conda_name, Required.LASTZ)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.LASTZ} with conda failed, trying direct download..."
    # TODO: build from source
    print("Trying to build LASTZ from source...")
    # git clone https://github.com/lastz/lastz
    # cd <somepath>/lastz-distrib-X.XX.XX/src
    # make
    # make install
    # no way, have to download
    is_downloaded = download_from_hg(LASTZ_DOWNLOADABLE)
    if is_downloaded is False:
        print("Failed to download lastz from {HGDOWNLOAD}")
        print("Probably lastz-xxxx version is updated")
        print("Pls check it and fix the script accordingly")
        return FAILED
    # need to rename lastz-1.04.00 to lastz
    src_ = os.path.join(BINARIES_DIR, LASTZ_DOWNLOADABLE)
    dst_ = os.path.join(BINARIES_DIR, Required.LASTZ)
    shutil.move(src_, dst_)
    return TO_ADD


### CHAINNET
def acquire_chainnet(conda_available):
    """Acquire chainNet."""
    # also available as docker container:
    # https://quay.io/repository/biocontainers/ucsc-fatotwobit
    print("\n### Acquiring chainNet ###")
    if _is_already_installed(Required.CHAINNET):
        return SUCCESS
    if conda_available:
        print("Conda available: trying this channel...")
        conda_name = "ucsc-chainnet"
        is_ok = download_with_conda(conda_name, Required.CHAINNET)
        if is_ok:
            return SUCCESS
        else:
            f"Installing {Required.CHAINNET} with conda failed, trying direct download..."
    # download from store
    is_downloaded = download_from_hg(Required.CHAINNET)
    return TO_ADD if is_downloaded else FAILED
# >>>>> Downloading kent utils

def build_chain_extract_id():
    """Build chain extract ID shared library"""
    print("\n### Building chain extract ID ###")
    slib_src = os.path.join(HL_EXEC_DIR, "chain_bst_lib.c")
    slib_dest = os.path.join(HL_EXEC_DIR, "chain_bst_lib.so")
    if os.path.isfile(slib_dest):
        print(f"{slib_dest} is already built")
        return SUCCESS
    cmd = f"gcc {CFLAGS} -fPIC -shared -o {slib_dest} {slib_src}"
    rc = subprocess.call(cmd, shell=True)
    if rc == 0:
        print("Success!")
        return SUCCESS
    else:
        print(f"Build command crashed!\n{cmd}")
        return FAILED


def parse_args():
    app = argparse.ArgumentParser()
    app.add_argument(
        "--allow_failure",
        action="store_true",
        dest="allow_failure",
        help="Allow downloading packages to fail.",
    )
    args = app.parse_args()
    return args


def check_stat(stat_lst):
    print("\n\n")
    if all(x == SUCCESS for x in stat_lst.values()):
        print("### All dependencies are installed ###")
        return
    elif all(x != FAILED for x in stat_lst.values()):
        print("### All dependencies are downloaded BUT")
        print("Please add the following paths to $PATH")

    for k, v in stat_lst.items():
        if v == SUCCESS:
            continue
        elif v == FAILED:
            print(f"# Error! Could not install {k}: {v}")
            print("This is a necessary requirement, please try")
            print("To acquire the respective binary and add it")
            print("to some $PATH directory\n")
        elif v == TO_ADD:
            print(f"# Warning! {k} is not in the $PATH")
            print(f"Please add:\n{HL_PATH}\nto your $PATH before running the pipeline\n")
    
    if any(x == FAILED for x in stat_lst.values()):
        print("\n### Error! Could not install some binaries (see above)")
        

def main():
    """Download/install all packeges."""
    args = parse_args()
    print("Acquiring packages necessary to run ")
    print(f"Operating system: {OS_NAME}")
    if args.allow_failure:
        print("Allowing download to fail")

    os.mkdir(BINARIES_DIR) if not os.path.isdir(BINARIES_DIR) else None

    conda_available = _check_conda_available()
    docker_available = _check_docker_available()
    print(f"Conda available: {conda_available}; Docker available: {docker_available}")

    axtchain_status = acquire_axtchain(conda_available)
    fatotwobit_status = acquire_fatotwobit(conda_available)
    twobittofa_status = acquire_twobittofa(conda_available)
    chainsort_status = acquire_chainsort(conda_available)
    chainscore_status = acquire_chainscore()
    gensub2_status = acquire_gensub2(conda_available)
    lastz_status = acquire_lastz(conda_available)
    axttopsl_status = acquire_axttopsl(conda_available)
    chainnet_status = acquire_chainnet(conda_available)
    chainantirepeat_status = acquire_chainantirepeat(conda_available)
    chainmergesort_status = acquire_chainmergesort(conda_available)
    pslsortacca_status = acquire_pslsortacc()
    chaincleaner_status = acquire_chaincleaner()

    chain_bst_status = build_chain_extract_id()

    installation_stats = {
        Required.AXTCHAIN: axtchain_status,
        Required.FATOTWOBIT: fatotwobit_status,
        Required.CHAINSORT: chainsort_status,
        Required.LASTZ: lastz_status,
        "chain_bst_lib.so": chain_bst_status,
        Required.TWOBITTOFA: twobittofa_status,
        Required.CHAINSCORE: chainscore_status,
        Required.GENSUB2: gensub2_status,
        Required.AXTTOPSL: axttopsl_status,
        Required.PSLSORTACC: pslsortacca_status,
        Required.CHAINANTIREPEAT: chainantirepeat_status,
        Required.CHAINMERGESORT: chainmergesort_status,
        Required.CHAINCLEANER: chaincleaner_status,
        Required.CHAINNET: chainnet_status,
    }

    check_stat(installation_stats)


if __name__ == "__main__":
    main()
