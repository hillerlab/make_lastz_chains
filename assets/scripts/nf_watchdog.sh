#!/bin/bash
# nf_watchdog.sh — detect a stalled Nextflow head job and force a -resume restart.
#
# A "stall" is detected when the in-flight task list reported by Nextflow's
# Task monitor (the `tasks to be completed: N` block in .nextflow.log) is
# byte-identical across consecutive checks for STALL_THRESHOLD seconds.
# This is the actual failure mode: Nextflow keeps logging, but the same
# tasks remain SUBMITTED forever because SLURM has no record of them.
#
# Run on the login node in tmux/screen, or as a tiny separate SLURM job.
# Do NOT bake this into the head job — it must outlive scancel.
#
# Required env (override on the command line if you don't want to edit):
#   NF_RUN_DIR         absolute path to the Nextflow run directory (where .nextflow.log lives)
#   NF_RESUME_SBATCH   absolute path to the sbatch wrapper that runs `nextflow run ... -resume`
#   NF_MAIN_JOB_NAME   #SBATCH --job-name of the head job (so squeue can find it)
#
# Optional:
#   STALL_THRESHOLD    seconds the signature must stay unchanged before we restart  (default 1800)
#   CHECK_INTERVAL     seconds between checks                                       (default 300)
#   MAX_RESTARTS       safety cap to prevent infinite resubmit loops                (default 5)

set -uo pipefail

export NF_RUN_DIR=/scratch/tianche5/amphibian_nf/Ascaphus_truei_Gallus_gallus_chains
export NF_RESUME_SBATCH=/path/to/your_resume_wrapper.sbatch   # must run nextflow with -resume
export NF_MAIN_JOB_NAME=test_v1path
STALL_THRESHOLD="${STALL_THRESHOLD:-1800}"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
MAX_RESTARTS="${MAX_RESTARTS:-5}"

NF_LOG="${NF_RUN_DIR%/}/.nextflow.log"
WATCHDOG_LOG="${NF_RUN_DIR%/}/nf_watchdog.log"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$WATCHDOG_LOG"; }

# Hash the most recent in-flight task block. The block starts at
# `tasks to be completed:` and continues with the indented `~> TaskHandler[...]`
# lines until the next non-indented log line or EOF.
stall_signature() {
    [ -f "$NF_LOG" ] || { echo "no-log"; return; }
    awk '
        /tasks to be completed:/ { block=""; cap=1; next }
        cap && /^~> TaskHandler\[/ { block = block $0 "\n"; next }
        cap && /^[^[:space:]~]/    { cap=0 }
        END { print block }
    ' "$NF_LOG" | md5sum | awk '{print $1}'
}

main_job_id() {
    squeue -u "$USER" -h -n "$NF_MAIN_JOB_NAME" -o '%i' | head -n1
}

restarts=0
last_sig=""
stall_since=0

log "watchdog starting; run_dir=$NF_RUN_DIR threshold=${STALL_THRESHOLD}s interval=${CHECK_INTERVAL}s max_restarts=$MAX_RESTARTS"

while :; do
    job_id=$(main_job_id)
    if [ -z "$job_id" ]; then
        log "no head job '$NF_MAIN_JOB_NAME' in queue — exiting"
        exit 0
    fi

    sig=$(stall_signature)
    now=$(date +%s)

    if [ "$sig" = "$last_sig" ] && [ -n "$sig" ] && [ "$sig" != "no-log" ]; then
        [ "$stall_since" -eq 0 ] && stall_since=$now
        elapsed=$(( now - stall_since ))
        log "head=$job_id signature=$sig unchanged for ${elapsed}s"
        if [ "$elapsed" -ge "$STALL_THRESHOLD" ]; then
            if [ "$restarts" -ge "$MAX_RESTARTS" ]; then
                log "STALL detected but MAX_RESTARTS=$MAX_RESTARTS reached — exiting without action"
                exit 1
            fi
            restarts=$(( restarts + 1 ))
            log "STALL — scancel $job_id and resubmit via $NF_RESUME_SBATCH (restart $restarts/$MAX_RESTARTS)"
            scancel "$job_id" || log "scancel returned non-zero"
            sleep 30
            new_id=$(sbatch --parsable "$NF_RESUME_SBATCH" 2>&1) || {
                log "sbatch failed: $new_id"; exit 2;
            }
            log "resubmitted as $new_id"
            last_sig=""
            stall_since=0
            sleep "$CHECK_INTERVAL"
            continue
        fi
    else
        if [ "$sig" != "$last_sig" ]; then
            log "head=$job_id signature changed — progress detected"
        fi
        last_sig=$sig
        stall_since=$now
    fi

    sleep "$CHECK_INTERVAL"
done
