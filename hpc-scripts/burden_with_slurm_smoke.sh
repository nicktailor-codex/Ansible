#!/usr/bin/env bash
# ============================================================
# burdentesting_slurm_smoke.sh — Validate Slurm + Apptainer
# container chain end-to-end. Submits a short test job, watches
# state transitions, reports detailed sacct info, and gives a
# clear PASS/FAIL verdict.
#
# Usage:
#   ./burdentesting_slurm_smoke.sh [partition] [account] [path-to-sif]
#
# Defaults:
#   partition = cpu
#   account   = research
#   sif       = /scratch/cluster-software/containers/burdentesting-latest.sif
# ============================================================
set -uo pipefail

PARTITION="${1:-cpu}"
ACCOUNT="${2:-research}"
SIF="${3:-/scratch/cluster-software/containers/burdentesting-latest.sif}"
WORKDIR="/scratch/$USER"

# ── Colors (only if stdout is a TTY) ────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" RESET=""
fi

# ── Output helpers ──────────────────────────────────────────
section() { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
field()   { printf "  ${DIM}%-12s${RESET} %s\n" "$1" "$2"; }
ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
fl()      { printf "  ${RED}✗${RESET} %s\n" "$1"; }

# ── Pre-flight ──────────────────────────────────────────────
if [[ ! -f "$SIF" ]]; then
    printf "\n${RED}✗${RESET} SIF not found: %s\n\n" "$SIF"
    exit 1
fi

mkdir -p "$WORKDIR"

# ── Banner ──────────────────────────────────────────────────
echo
printf "${BOLD}${BLUE}╭────────────────────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Slurm + Container Smoke Test${RESET}                          ${BOLD}${BLUE}│${RESET}\n"
printf "${BOLD}${BLUE}╰────────────────────────────────────────────────────────╯${RESET}\n"

section "Configuration"
field "Partition" "$PARTITION"
field "Account"   "$ACCOUNT"
field "SIF"       "$SIF"
field "Workdir"   "$WORKDIR"
field "User"      "$USER"
field "Host"      "$(hostname -s)"

# ── Submit ──────────────────────────────────────────────────
section "Submitting job"

JOBID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --account="$ACCOUNT" \
    --time=00:05:00 --mem=4G \
    --chdir="$WORKDIR" \
    --output="$WORKDIR/slurm-smoke-%j.out" \
    --error="$WORKDIR/slurm-smoke-%j.err" \
    --job-name="container-smoke" \
    --wrap="apptainer exec $SIF regenie --help")

if [[ -z "${JOBID:-}" ]]; then
    fl "sbatch did not return a job ID"
    exit 1
fi

ok "Submitted job ${BOLD}$JOBID${RESET}"

# ── Wait for completion ─────────────────────────────────────
section "Waiting for completion"

TIMEOUT=120
ELAPSED=0
LAST_STATE=""

while squeue -h -j "$JOBID" 2>/dev/null | grep -q .; do
    if (( ELAPSED >= TIMEOUT )); then
        printf "\r%-70s\r" " "
        fl "Job $JOBID still running after ${TIMEOUT}s — cancelling"
        scancel "$JOBID" 2>/dev/null
        exit 1
    fi
    STATE=$(squeue -h -j "$JOBID" -o "%T" 2>/dev/null | head -1)
    if [[ "$STATE" != "$LAST_STATE" ]]; then
        printf "\r%-70s\r" " "
        printf "  ${DIM}[%3ds]${RESET} state: ${YELLOW}%s${RESET}\n" "$ELAPSED" "$STATE"
        LAST_STATE="$STATE"
    else
        printf "\r  ${DIM}[%3ds]${RESET} state: ${YELLOW}%s${RESET}" "$ELAPSED" "$STATE"
    fi
    sleep 2
    ((ELAPSED+=2))
done
printf "\r%-70s\r" " "
ok "Job finished in ${BOLD}${ELAPSED}s${RESET}"

# Give sacct a beat to catch up
sleep 1

# ── Collect sacct details ───────────────────────────────────
get_field() {
    sacct -j "$1" --format="$2" -X -n -P 2>/dev/null | head -1 | tr -d ' '
}

STATE=$(get_field "$JOBID" State)
EXITCODE=$(get_field "$JOBID" ExitCode)
NODELIST=$(get_field "$JOBID" NodeList)
SUBMIT=$(get_field "$JOBID" Submit)
START=$(get_field "$JOBID" Start)
END=$(get_field "$JOBID" End)
ELAPSED_TIME=$(get_field "$JOBID" Elapsed)
CPUTIME=$(get_field "$JOBID" CPUTime)
ALLOCCPUS=$(get_field "$JOBID" AllocCPUS)
REQMEM=$(get_field "$JOBID" ReqMem)
MAXRSS=$(sacct -j "${JOBID}.batch" --format=MaxRSS -n -P 2>/dev/null | head -1 | tr -d ' ')

OUTFILE="$WORKDIR/slurm-smoke-${JOBID}.out"
ERRFILE="$WORKDIR/slurm-smoke-${JOBID}.err"
OUT_LINES=$(wc -l < "$OUTFILE" 2>/dev/null || echo 0)
ERR_LINES=$(wc -l < "$ERRFILE" 2>/dev/null || echo 0)
OUT_SIZE=$(ls -lh "$OUTFILE" 2>/dev/null | awk '{print $5}' || echo "0")

# ── Job details ─────────────────────────────────────────────
section "Job details"
field "JobID"     "$JOBID"
field "JobName"   "container-smoke"
field "Node"      "$NODELIST"
field "CPUs"      "$ALLOCCPUS"
field "Req mem"   "$REQMEM"
[[ -n "$MAXRSS" ]] && field "Max RSS" "$MAXRSS"
field "Submit"    "$SUBMIT"
field "Start"     "$START"
field "End"       "$END"
field "Elapsed"   "$ELAPSED_TIME"
field "CPU time"  "$CPUTIME"

# ── Result ──────────────────────────────────────────────────
section "Result"
if [[ "$STATE" == "COMPLETED" ]]; then
    printf "  ${DIM}%-12s${RESET} ${GREEN}%s${RESET}\n" "State" "$STATE"
else
    printf "  ${DIM}%-12s${RESET} ${RED}%s${RESET}\n" "State" "$STATE"
fi
if [[ "$EXITCODE" == "0:0" ]]; then
    printf "  ${DIM}%-12s${RESET} ${GREEN}%s${RESET}\n" "ExitCode" "$EXITCODE"
else
    printf "  ${DIM}%-12s${RESET} ${RED}%s${RESET}\n" "ExitCode" "$EXITCODE"
fi
field "Output" "$OUTFILE  (${OUT_LINES} lines, ${OUT_SIZE})"
if (( ERR_LINES > 0 )); then
    printf "  ${DIM}%-12s${RESET} ${YELLOW}%s${RESET}\n" "Stderr" "$ERRFILE  (${ERR_LINES} lines)"
else
    field "Stderr" "$ERRFILE  (empty)"
fi

# ── Output preview ──────────────────────────────────────────
section "Output preview (first 8 lines)"
if [[ -f "$OUTFILE" ]] && [[ "$OUT_LINES" -gt 0 ]]; then
    head -8 "$OUTFILE" | sed "s/^/    ${DIM}│${RESET} /"
    if (( OUT_LINES > 8 )); then
        printf "    ${DIM}│${RESET} ${DIM}... (%d more lines)${RESET}\n" $((OUT_LINES - 8))
    fi
else
    fl "Output file empty or missing"
fi

# ── Verdict ─────────────────────────────────────────────────
echo
if [[ "$STATE" == "COMPLETED" ]] && [[ "$EXITCODE" == "0:0" ]] && grep -q "REGENIE" "$OUTFILE" 2>/dev/null; then
    printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}full chain validated${RESET}            ${BOLD}${GREEN}│${RESET}\n"
    printf "${BOLD}${GREEN}╰──────────────────────────────────────────╯${RESET}\n"
    echo
    exit 0
else
    printf "${BOLD}${RED}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${RED}│${RESET}  ${BOLD}${RED}✗ FAIL${RESET}  ${RED}see details above${RESET}               ${BOLD}${RED}│${RESET}\n"
    printf "${BOLD}${RED}╰──────────────────────────────────────────╯${RESET}\n"
    echo
    if [[ -f "$ERRFILE" ]] && (( ERR_LINES > 0 )); then
        section "Stderr"
        head -20 "$ERRFILE" | sed "s/^/    ${DIM}│${RESET} /"
        echo
    fi
    exit 1
fi
