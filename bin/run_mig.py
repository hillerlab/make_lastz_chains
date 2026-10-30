#!/usr/bin/env python
#
# Vendored verbatim from KegAlign, scripts/mps-mig/run_mig.py (MIT)
#   https://github.com/galaxyproject/KegAlign @ ea16d549d2bd3fa49e0e4b27e40bf32708c109f3
#   Copyright (c) 2020 Sneha D. Goenka, Yatish Turakhia, Benedict Paten, Mark Horowitz
#   Copyright (c) 2025 A. Burak Gulhan, Richard Burhans, Robert Harris, Mahmut Kandemir,
#                      Maximilian Haeussler, Anton Nekrutenko
#
# The kegalign-full conda package does not ship scripts/mps-mig, so both scripts
# live here; Nextflow prepends bin/ to PATH inside the container. Keep as close
# to verbatim as possible — re-vendor from upstream rather than patching locally.
#
# Local deviations from upstream, each marked "make_lastz_chains patch" inline:
#   1. NamedPopen.__init__ popped "name" before calling subprocess.Popen, which
#      rejects the keyword (upstream TypeErrors on the first submitted pair).
#   2. GPU_queue.__len__ reads self instead of a module-level "gpu_queue" that
#      does not exist (upstream NameErrors as soon as a pair is submitted).

import argparse
import datetime
import os
import pynvml
import re
import subprocess
import sys
import time


def check_makedir(pathname: str) -> None:
    try:
        os.makedirs(pathname, exist_ok=True)
    except Exception:
        sys.exit(f"ERROR: failed to make directory: {pathname}")


class NamedPopen(subprocess.Popen[str]):
    """
    Like subprocess.Popen, but returns an object with a .name member
    """

    def __init__(self, *args, **kwargs) -> None:
        # make_lastz_chains patch (upstream bug): "name" was forwarded into
        # subprocess.Popen, which rejects it — TypeError on the first submitted
        # pair, so upstream run_mig.py cannot schedule anything as shipped.
        # Pop it before delegating. Report upstream; drop this on re-vendoring.
        self.name = kwargs.pop("name", "")
        super().__init__(*args, **kwargs)


class GPU_queue:
    """ """

    def __init__(self, device_names: list[str], uid_folder: str, uid_prefix: str = "UID_", max_processes: list[int] | None = None):
        # dict of lists. Each list is for a GPU or MIG device which
        # holds UID values of processes running on that device
        self.queue: dict[str, list[str]] = {}
        for device_name in device_names:
            self.queue[device_name] = []
        # directory where UID files are written
        self.uid_folder = uid_folder
        # keeps track of each submitted proccess's corresponding UID value
        self.submitted_uid: set[str] = set()
        # keeps track of processes that successfully completed GPU portions
        self.completed_uid_history: set[str] = set()
        self.uid_prefix = uid_prefix
        # key: GPU device name (str), value: int (number of processes per MIG (or GPU) device)
        self.max_processes: dict[str, int] = {}
        if max_processes is not None:
            for i in range(len(device_names)):
                self.max_processes[device_names[i]] = max_processes[i]

    def __len__(self) -> int:
        # make_lastz_chains patch (upstream bug): read self, not a module-level
        # "gpu_queue" that does not exist — upstream NameErrors on the first
        # len(gpu_queue), i.e. as soon as a pair is submitted.
        return sum([len(i) for i in self.get_queue().values()])

    def submit(self, uid: str, device_name: str) -> None:
        self.queue[device_name].append(uid)
        self.submitted_uid.add(uid)

        if self.max_processes:
            if (self.max_processes[device_name] < len(self.queue[device_name])):
                sys.exit(f"WARNING for device {device_name}, max process = {self.max_processes[device_name]}, running process = {len(self.queue[device_name])}")

    """
    Removes processes that completed their GPU part but not necessarily CPU (LASTZ) part.
    Checks files in UID directory
    """

    def check_completion(self) -> None:
        completed_uid = set([f for f in os.listdir(self.uid_folder) if self.uid_prefix in f and os.path.isfile(os.path.join(self.uid_folder, f))])

        # check successfully completed jobs using file output from modified run_kegalign script
        uids_in_progress = completed_uid - self.completed_uid_history
        self.remove_uids(list(uids_in_progress))

    def remove_uids(self, uid_list: list[str]) -> None:
        for uid in uid_list:
            for device_queue in self.queue.values():
                if uid in reversed(device_queue):
                    device_queue.remove(uid)
                    self.completed_uid_history.add(uid)
                    continue

    def get_queue(self) -> dict[str, list[str]]:
        return self.queue

    def get_running_uids(self) -> list[str]:
        uids = []
        for device_queue in self.queue.values():
            for uid in device_queue:
                uids.append(uid)
        return uids

    def get_free_device_list(self) -> list[tuple[str, int]]:
        free_device = []
        for key, value in self.queue.items():
            running_process = len(value)
            max_processes = self.max_processes[key]
            if running_process < max_processes:
                free_device.append((key, running_process))
        return free_device


"""
Hold list of processes.
Removes complete processes to prevent too many file open errors.
"""


class Process_List:
    def __init__(self, max_processes: int = 256) -> None:
        # key process.name (UID), value: process
        self.processes: dict[str, NamedPopen] = {}
        self.stdout = ""
        self.stderr = ""
        self.max_processes = max_processes

    def append(self, process: NamedPopen) -> None:
        print(f"== ADDING process {process.name}")
        if process.name not in self.processes:
            self.processes[process.name] = process
        else:
            sys.exit(f"ERROR: duplicate process.name: {process.name}")

        if len(self.processes) >= self.max_processes:
            self.get_fails_and_check_completion()

    def _detect_failure(self, stderr: str) -> str:
        failures = ["core dumped", "Can't open", "cuda", "bad_alloc", "Aborted"]
        for f in failures:
            if f in stderr:
                if "cudaErrorCudartUnloading" in stderr:
                    return "mem_err"
                else:
                    return "other_err"
        return "no_err"

    """
    Check if processes are complete and saves outputs to stdout and stderr.
    Complete processes are removed from self.processes
    Returns any process names (UID) that have failed
    """

    def get_fails_and_check_completion(self) -> tuple[list[str], list[str]]:
        process_names = list(self.processes.keys())
        fails = []
        mem_fails = []
        for p_name in process_names:
            p = self.processes[p_name]
            # check if process is finished
            if p.poll() is not None:
                # clear line
                print("\33[2K", end="")
                print(f"-- REMOVING process {p.name}")
                # get outputs. Blocks until process returns
                stdout, stderr = p.communicate()
                self.stdout += stdout
                self.stderr += stderr
                error_type = self._detect_failure(stderr)
                if error_type == "other_err":
                    print(f"FAIL {p.name}")
                    fails.append(p.name)
                if error_type == "mem_err":
                    print(f"MEM_FAIL {p.name}")
                    mem_fails.append(p.name)
                del self.processes[p.name]
        return fails, mem_fails

    """
    Checks uids in uid_list and returns those whose corresponding procces
    is finished running.

    Does not update any class members
    """

    def check_uid_completion(self, uid_list: list[str]) -> list[str]:
        complete_uids = []
        for uid_name in uid_list:
            if uid_name in self.processes:
                process = self.processes[uid_name]
                assert process.name == uid_name
                if process.poll() is not None:
                    complete_uids.append(uid_name)
        return complete_uids

    """
    Check if finished processes, by uid name, failed due to memory errors
    """

    def check_uid_memfail(self, uid_list: list[str]) -> list[str]:
        mem_fails = []
        for uid_name in uid_list:
            if uid_name in self.processes:
                process = self.processes[uid_name]
                assert process.name == uid_name
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    error_type = self._detect_failure(stderr)
                    if error_type == "mem_err":
                        mem_fails.append(process.name)
        return mem_fails

    def get_output(self, terminate: bool = False) -> tuple[str, str]:
        for name, process in self.processes.items():
            if terminate:
                # if process still running
                if process.poll() is None:
                    process.terminate()
                    print(f"Error 1: Could not get results for process {process.name}")
                    stdout = ""
                    stderr = ""
                else:
                    try:
                        stdout, stderr = process.communicate()
                    except Exception:
                        print(f"Error 2: Could not get results for process {process.name}")
                        stdout = ""
                        stderr = ""
            else:
                print(f"waiting for process {name}")
                try:
                    # get outputs. Blocks until process returns
                    stdout, stderr = process.communicate()
                except Exception:
                    print(f"Error 3: Could not get results for process {process.name}")
                    stdout = ""
                    stderr = ""
            self.stdout += stdout
            self.stderr += stderr
        return self.stdout, self.stderr

    def print_fails(self) -> None:
        print(f"FAILED: {self.fails()}")


def run_command(command: str) -> str:
    line_as_bytes = subprocess.check_output(f"{command}", shell=True)
    line = line_as_bytes.decode("ascii")
    return line


def get_nvidia_smi() -> str:
    return run_command("nvidia-smi")


def get_nvidia_smi_L() -> str:
    return run_command("nvidia-smi -L")


# TODO make this use nvml functions
def get_uuids() -> list[str]:
    mig_uuids = re.findall(r"\(UUID: MIG(.*?)\)", get_nvidia_smi_L())
    mig_uuid_list = []
    for id in mig_uuids:
        mig_uuid_list.append(f"MIG{id}")
    return mig_uuid_list


# TODO make this use nvml functions
def init_mig_dict(used_uuids: list[str]) -> dict[tuple[str, str, str], str]:
    x = get_nvidia_smi().split("MIG devices:")[1]
    border_text = x.split("\n")[1].strip()

    x = x.split("=|")[1].strip()
    x = x.split("Processes:")[0].strip()
    # devices = x.split("+------------------+----------------------+-----------+-----------------------+")[:-1]
    devices = x.split(border_text)[:-1]
    # key = (gpu, gi_id, ci_id), value = mig_uuid
    mig_dict = {}
    mig_uuids = get_uuids()

    assert len(devices) == len(mig_uuids)
    for i, device in enumerate(devices):
        s = device.split()
        gpu = s[1]
        assert gpu.isdigit()
        gi_id = s[2]
        assert gi_id.isdigit()
        ci_id = s[3]
        assert ci_id.isdigit()
        mig_dev = s[4]
        assert mig_dev.isdigit()
        uuid = mig_uuids[i]
        if uuid in used_uuids:
            mig_dict[(gpu, gi_id, ci_id)] = uuid
    return mig_dict


def combine_results(output_dir: str, output_file: str, part_pattern: str = "part_*.maf", remove: bool = True) -> None:
    try:
        run_command(f"cat {os.path.join(output_dir, part_pattern)} > {output_file}")
        # "cat *.txt > all.txt"
        if remove:
            run_command(f"rm {os.path.join(output_dir, part_pattern)}")
    except Exception:
        print("Could not combine results")


def remove_uid_files(uid_dir: str, uid_prefix: str) -> None:
    try:
        run_command(f"rm {os.path.join(uid_dir, uid_prefix)}*")
    except Exception:
        print("Could not remove uids")


def init_mps(mig_list: list[str], mps_pipe_dir: str) -> None:
    for mig in mig_list:
        print(f"Initializing MPS server for {mig}")
        command = f"CUDA_VISIBLE_DEVICES={mig} CUDA_MPS_PIPE_DIRECTORY={os.path.join(mps_pipe_dir, mig)} nvidia-cuda-mps-control -d"
        run_command(command)


def destroy_mps(mig_list: list[str], mps_pipe_dir: str) -> None:
    for mig in mig_list:
        print(f"Destroying MPS server for {mig}")
        command = f"echo quit | CUDA_VISIBLE_DEVICES={mig} CUDA_MPS_PIPE_DIRECTORY={os.path.join(mps_pipe_dir, mig)} nvidia-cuda-mps-control"
        run_command(command)


def get_time(timer: datetime.datetime) -> str:
    return str(datetime.datetime.now() - timer).split(".", 1)[0]


def parse_args() -> argparse.Namespace:
    # TODO most variables with 'mig' in the name are misleading. They are used for both MIG and non-MIG GPUs. Need to rename these
    parser = argparse.ArgumentParser()
    parser.add_argument("--MIG", type=str, default="", help="Comma separated list of GPU or MIG device names")
    parser.add_argument("--MPS", type=str, default="", help="Comma separated list of number of processes per GPU/MIG node.")
    parser.add_argument("--kill_mps", action="store_true", help="Shutdown all MPS daemons. Does not run aligmnet. Used for debug purposes or when run_mig script improperly terminated.")
    # parser.add_argument("--skip_mps_init", action="store_true")
    parser.add_argument("--refresh", type=float, default=0.2, help="Time in seconds to wait before checking for free GPU or MIG devices")
    # parser.add_argument("--usev", type=str, default="")
    parser.add_argument("--query", type=str, required=True, help="Directory containing partitioned input query file.")
    parser.add_argument("--target", type=str, required=True, help="Directory containing partitioned input target file.")
    parser.add_argument("--tmp_dir", type=str, required=True, help="Directory to store temporary files.")
    parser.add_argument("--output", type=str, required=True, help="Output alignment file name.")
    parser.add_argument("--format", type=str, default="maf-", help="Output alignment file format. Must be supported by KegAlign, i.e. able to be concatenated.")
    parser.add_argument("--mps_pipe_dir", type=str, help="MPS pipe directory.")
    parser.add_argument("--num_threads", type=int, default=-1, help="Number of threads to use for each KegAlign process.")
    parser.add_argument("--segment_size", type=int, default=0, help="Maximum segment size output by KegAlign. Segment files larger than this parameter are partitioned. 0 does no partitioning, -1 estimates best partition size. See diagonal_partition.py")
    parser.add_argument("--kegalign_cmd", type=str, default="run_kegalign_symlink", help="Command to KegAlign runner script. This is called when aligning each pair of query and target files.")
    parser.add_argument("--opt_cmd", type=str, default="", help="Additional options to pass to KegAlign runner script.")
    parser.add_argument("--keep_partial", action="store_true", help="Keep output files for each pair of alignments after combining them. It is recommended to keep these files for debugging purposes or if output file format does not support concatenation.")
    parser.add_argument("--only_missing", action="store_true", help="Only run KegAlign for missing pairs of query and target files, if any failed for some reason.")
    parser.add_argument("--skip_mps_control", action="store_true", help="Skip starting and stopping MPS daemon. Used for debugging purposes.")
    parser.add_argument("--start_uid", type=int, default=None, help="Start alignmet from a specific pair. Used for debugging purposes.")
    parser.add_argument("--verbose", action="store_true", help="Print additional information to console.")
    parser.add_argument("--twobit_ext", type=str, default=".2bit", help="File extensions of 2bit files in query and target directories.")
    parser.add_argument("--resubmit_fails", action="store_false", help="Whether to resubmit failed alignment pairs.")

    return parser.parse_args()


def main() -> None:
    args = parse_args()

    check_makedir(args.tmp_dir)
    check_makedir(args.mps_pipe_dir)

    output_format = args.output.split(".")[-1]

    mig_list = args.MIG.split(",")
    if len(mig_list) != len(set(mig_list)):
        sys.exit("Duplicate MIG ids given")
    no_MIG = False
    if "GPU" in args.MIG:
        print("Using non-MIG GPU")
        no_MIG = True

    cpus_available = len(os.sched_getaffinity(0))
    if args.num_threads == -1 or args.num_threads > cpus_available:
        args.num_threads = cpus_available
    print(f"USING {args.num_threads} THREADS")

    use_MPS = args.MPS is not None
    if use_MPS:
        print("USING MPS")
        # how many processes per MIG node
        num_MPS = [int(x) for x in args.MPS.split(",")]
        max_proc_dict = dict(zip(mig_list, num_MPS))

    try:
        pynvml.nvmlInit()
    except pynvml.NVMLError as e:
        sys.exit(f"ERROR: {str(e)}")

    timer = datetime.datetime.now()
    # TODO script currently only supports 1 GPU per KegAlign process. Add multiple GPU support if needed
    gpu_per_kegalign = 1

    # GPU is determined using CUDA_VISIBLE_DEVICES variable when calling kegalign script.
    # NOTE: Multiple MIG devices canNOT be used by the same KegAlign instance due to CUDA
    # limitations. See https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html#cuda-visible-devices

    # TODO make this non hardcoded
    non_mig_gpu_id = 0

    query_dir = args.query
    target_dir = args.target
    tmp_dir = os.path.abspath(args.tmp_dir)
    output_file = args.output

    mps_pipe_dir = os.path.abspath(args.mps_pipe_dir)

    uid_prefix = "UID_"

    segment_size = args.segment_size

    segment_command = ""
    if args.segment_size != 0:
        segment_command = f"--segment_size {segment_size}"

    mps_timer = datetime.datetime.now()

    if args.kill_mps:
        destroy_mps(mig_list, mps_pipe_dir)
        sys.exit(0)

    if use_MPS and not args.skip_mps_control:
        try:
            destroy_mps(mig_list, mps_pipe_dir)
        except Exception:
            pass
        init_mps(mig_list, mps_pipe_dir)
    print(f"MPS init time: {get_time(mps_timer)}")

    _2bit_extension = args.twobit_ext
    query_block_file_names = sorted([filename for filename in os.listdir(query_dir) if _2bit_extension not in filename])
    target_block_file_names = sorted([filename for filename in os.listdir(target_dir) if _2bit_extension not in filename])

    process_list = Process_List()

    python_log = ""
    python_log += f"Starting Time: {datetime.datetime.now()}\n"

    # used to check if program stopped due to error or termination
    normal_completion = False

    resub_mem_fails = args.resubmit_fails

    verbose = args.verbose

    # use try block to make sure to run exit functions on exit, even if errors
    try:
        """
        if no_MIG:
            mig_dict = {}
            mig_dict[str(non_mig_gpu_id), "N/A", "N/A"] = mig_list[0]
        else:
            mig_dict = init_mig_dict(mig_list)

        print(mig_dict)
        """
        part = 1
        refresh_time = args.refresh

        # Main purpose of GPU_queue is to keep track of running KegAlign processes on each GPU or MIG device
        # Since we call a runner script, which calls the KegAlign executable we want to keep track of, using
        # process id to keep track of KegAlign instances is difficult. Instead we use temporary files (UID files)
        # to keep track of running processes. This is done by the kegalign runner script writing a UID file when
        # a kegalign process is successfully completed.
        # If the run_mig.py and kegalign runner script were to be combined into one script, this process would be
        # much simpler.
        gpu_queue = GPU_queue(mig_list, tmp_dir, uid_prefix, num_MPS)
        print(f"GPU QUEUE: {gpu_queue.queue}")

        mig_process_dict = gpu_queue.get_queue()
        free_mig_list = gpu_queue.get_free_device_list()

        max_processes = sum(max_proc_dict.values())
        print(f"max processes = {max_processes}")
        print(mig_process_dict)
        print("=====")
        # list of tasks
        pairs = []
        for q in query_block_file_names:
            for t in target_block_file_names:
                pairs.append((q, t))
        total_pairs = len(pairs)
        # used when resubmitting mem fails. Need to know file pair for given UID
        uid_pair_map: dict[str, tuple[str, str]] = {}
        while len(pairs) > 0:
            # print(f"running part {part}: {q} and {t}")
            # used for printing to console
            entered_while = False
            while len(free_mig_list) == 0:
                entered_while = True
                time.sleep(refresh_time)
                # checks removes processes from gpu_queue whose UID files have been written
                gpu_queue.check_completion()

                # some processes fail mainly due to lacking GPU, need to deal with these
                # TODO prevent failures by checking GPU memory usage
                running_uids = gpu_queue.get_running_uids()
                # uids that have their corresponding process complete, but not removed (possibly due to errors).
                failed_uids = process_list.check_uid_completion(running_uids)
                # Note: process removal done by checking if UID file is written
                if resub_mem_fails:
                    resub_uids = process_list.check_uid_memfail(failed_uids)
                    for resub_uid in resub_uids:
                        print(f"{resub_uid} RESUBMITTED")
                        python_log += f"{resub_uid} RESUBMITTED\n"
                        resub_pair = uid_pair_map[resub_uid]
                        pairs.append(resub_pair)
                # failed_uids = process_list.get_fails_and_check_completion()
                if len(failed_uids) > 0:
                    gpu_queue.remove_uids(failed_uids)
                    for uid in failed_uids:
                        python_log += f"FAILED UID {uid}\n"
                        print(f"FAILED UID {uid}")

                mig_process_dict = gpu_queue.get_queue()
                free_mig_list = gpu_queue.get_free_device_list()
                # print(f"Free devices: {free_mig_list}, device_queue: {gpu_queue.get_queue()}", end="\r")
                # print(f"\33[2KFree devices: {free_mig_list}", end="\r")
                if verbose:
                    # clear line
                    print("\33[2K", end="")

                    # print GPU queue information
                    # get single MIG slice queue
                    for enum_i, i in enumerate(gpu_queue.get_queue().values()):
                        # get
                        for enum_j, j in enumerate(i):
                            if enum_j == len(i) - 1:
                                print(f"{j[4:]}", end="")
                            else:
                                print(f"{j[4:]} ", end="")
                        if enum_i == len(gpu_queue.get_queue()) - 1:
                            pass
                        else:
                            print("|", end="")
                    print("\r", end="")
            if verbose and entered_while:
                print("")

            # get MIG device
            # TODO choose most remaining free space left device
            mig_device, proc_ctr = free_mig_list[0]
            free_mig_list.pop(0)
            assert proc_ctr < max_proc_dict[mig_device]
            while proc_ctr < max_proc_dict[mig_device]:
                proc_ctr += 1
                if len(pairs) == 0:
                    break
                q, t = pairs[0]
                pairs.pop(0)
                uid_name = uid_prefix + str(part)

                out = os.path.join(tmp_dir, f"part_{part}.{output_format}")
                command = f"CUDA_VISIBLE_DEVICES={mig_device} {args.kegalign_cmd} {args.opt_cmd} {os.path.join(target_dir, t)} {os.path.join(query_dir, q)} --debug --output={out} --format={args.format} --num_gpu {gpu_per_kegalign} --num_threads {args.num_threads} --uid {os.path.abspath(os.path.join(tmp_dir, uid_name))} {segment_command}"
                command = f"CUDA_MPS_PIPE_DIRECTORY={os.path.join(mps_pipe_dir, mig_device)} " + command

                if bool(args.only_missing):
                    if os.path.isfile(out):
                        part += 1
                        if verbose:
                            print(f"SKIPPING process, part {part}: {t} and {q}. Elapsed Time: {get_time(timer)}")
                        python_log += "SKIPPED: " + command + "\n"
                        continue
                    if args.start_uid and part < int(args.start_uid):
                        if verbose:
                            print(f"SKIPPING process, part {part}: {t} and {q}. Elapsed Time: {get_time(timer)}")
                        python_log += "SKIPPED: " + command + "\n"
                        part += 1
                        continue
                # run process in non blocking way
                process = NamedPopen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, shell=True, name=uid_name)
                process_list.append(process)
                gpu_queue.submit(uid_name, mig_device)
                # sum([len(i) for i in gpu_queue.get_queue().values()])
                running = len(gpu_queue)
                est_runtime = str((datetime.datetime.now() - timer) * (total_pairs / max(total_pairs - len(pairs) - running, 1))).split(".", 1)[0]
                if verbose:
                    print(f"running process with pid={process.pid}, uid={uid_name} and mig_uuid={mig_device}. part {part} /{total_pairs}: {t} and {q}. Elapsed Time: {get_time(timer)}, estimated runtime: {est_runtime} [len(pairs) {len(pairs)}, running {running}]")
                    print(command)
                # process_list.append(process)
                mig_process_dict = gpu_queue.get_queue()
                uid_pair_map[uid_name] = (q, t)
                part += 1
                python_log += command + "\n"

        # wait for GPU sections to complete by checking uid files
        while len(gpu_queue) > 0:
            # update gpu queue by checking for new uid files
            gpu_queue.check_completion()

            # check processes that failed and did not make a uid file
            running_uids = gpu_queue.get_running_uids()
            # if processes corresponding to running uids have
            # completed without making uid file then these must have
            # failed for some reason
            failed_uids = process_list.check_uid_completion(running_uids)
            if len(failed_uids) > 0:
                gpu_queue.remove_uids(failed_uids)
                for uid in failed_uids:
                    python_log += f"FAILED UID {uid}\n"
                    print(f"FAILED UID {uid}")
            # Resubmission of failed KegAlign processes can be done
            # with the parameter --only_missing
            # TODO add support resubmission for failed UIDs after
            # all pairs have been submitted

        print()
        print(f"Finished GPU section. time {get_time(timer)}")
        python_log += f"Finished GPU section. time {get_time(timer)}\n"
        if use_MPS and not bool(int(args.skip_mps_control)):
            destroy_mps(mig_list, mps_pipe_dir)

        # wait for all processes (LASTZ and output concatenation parts) to complete
        output_stdout, output_stderr = process_list.get_output()

        # check if missing parts
        output_file_list = [i for i in os.listdir(tmp_dir) if i.startswith("part_") and i.endswith(f".{output_format}")]
        expected_outputs = len(query_block_file_names) * len(target_block_file_names)
        if len(output_file_list) != expected_outputs:
            print(f"Missing {expected_outputs-len(output_file_list)} output parts: ")
            set_output_file_list = set(output_file_list)

            for k in range(1, expected_outputs + 1):
                part_name = f"part_{k}.{output_format}"
                if part_name not in set_output_file_list:
                    print(f"{k}, ", end="")
            print()
            print("Rerun with --only_missing")

        normal_completion = True
    finally:

        if not normal_completion:
            output_stdout, output_stderr = process_list.get_output(terminate=True)
            if use_MPS and not bool(int(args.skip_mps_control)):
                destroy_mps(mig_list, mps_pipe_dir)
        stdout_log_file = process_list.stdout
        stderr_log_file = process_list.stderr
        # log outputs to tmp directory
        # f"{tmp_dir}o.txt"
        stdout_log_file = "o.txt"
        write_mode = "w"
        if args.only_missing:
            write_mode = "a"
        with open(stdout_log_file, write_mode) as file:
            print(f"Writing stdout to {stdout_log_file}")
            file.write(output_stdout)
        # f"{tmp_dir}e.txt"
        stderr_log_file = "e.txt"
        with open(stderr_log_file, write_mode) as file:
            print(f"Writing stderr to {stderr_log_file}")
            file.write(output_stderr)

        print(f"total time {get_time(timer)}")
        python_log += f"total time {get_time(timer)}\n"
        combine_results(tmp_dir, output_file, part_pattern=f"part_*.{output_format}", remove=(not bool(args.keep_partial)))
        print(f"result combination finished at {get_time(timer)}")
        python_log += f"result combination finished at {get_time(timer)}\n"
        python_log += f"Ending Time: {datetime.datetime.now()}\n"
        # finished execution
        # f"{tmp_dir}p.txt"
        python_log_file = "p.txt"
        with open(python_log_file, write_mode) as file:
            print(f"Writing executed commands to {python_log_file}")
            file.write(python_log)
        # print(output_stderr)
        # print(output_stdout)

        if not bool(not bool(args.keep_partial)):
            remove_uid_files(tmp_dir, uid_prefix)

        try:
            pynvml.nvmlShutdown()
        except pynvml.NVMLError as e:
            sys.exit(f"ERROR: {str(e)}")


if __name__ == "__main__":
    main()
