#!/usr/bin/env bash
# ============================================================
# pyxis_slurm_smoke.sh — Validate Pyxis + Enroot via Slurm.
# Submits a short srun job with `--container-image=docker://...`,
# watches state transitions, reports sacct details, gives a clear
# PASS/FAIL verdict.
#
# Counterpart to burden_with_slurm_smoke.sh — same shape, now
# exercising Pyxis SPANK + Enroot instead of Apptainer.
#
# Usage:
#   ./pyxis_slurm_smoke.sh [partition] [account] [docker://IMAGE]
#
# Defaults:
#   partition = cpu
#   account   = research
#   image     = docker://egardner413/mrcepid-burdentesting:latest
# ============================================================
set -uo pipefail

PARTITION="${1:-cpu}"
ACCOUNT="${2:-research}"
IMAGE="${3:-docker://egardner413/mrcepid-burdentesting:latest}"
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

section() { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
field()   { printf "  ${DIM}%-12s${RESET} %s\n" "$1" "$2"; }
ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
fl()      { printf "  ${RED}✗${RESET} %s\n" "$1"; }

# ── Pre-flight ──────────────────────────────────────────────
if ! command -v sbatch >/dev/null 2>&1; then
    printf "\n${RED}✗${RESET} sbatch not found — is slurm-client installed?\n\n"
    exit 1
fi

mkdir -p "$WORKDIR"

# ── Banner ──────────────────────────────────────────────────
echo
printf "${BOLD}${BLUE}╭────────────────────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Pyxis + Enroot Slurm smoke test${RESET}                       ${BOLD}${BLUE}│${RESET}\n"
printf "${BOLD}${BLUE}╰────────────────────────────────────────────────────────╯${RESET}\n"

section "Configuration"
field "Partition" "$PARTITION"
field "Account"   "$ACCOUNT"
field "Image"     "$IMAGE"
field "Workdir"   "$WORKDIR"
field "User"      "$USER"
field "Host"      "$(hostname -s)"

# Determine a sensible test command for the image. If the image is a
# burdentesting one, exercise regenie; otherwise just dump os-release.
case "$IMAGE" in
    *burdentesting*) TEST_CMD="regenie --help" ;;
    *)               TEST_CMD="bash -c 'cat /etc/os-release | head -3; hostname'" ;;
esac
field "Test cmd"  "$TEST_CMD"

# ── Submit ──────────────────────────────────────────────────
section "Submitting job"

JOBID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --account="$ACCOUNT" \
    --time=00:10:00 --mem=4G \
    --chdir="$WORKDIR" \
    --output="$WORKDIR/pyxis-smoke-%j.out" \
    --error="$WORKDIR/pyxis-smoke-%j.err" \
    --job-name="pyxis-smoke" \
    --container-image="$IMAGE" \
    --wrap="$TEST_CMD")

if [[ -z "${JOBID:-}" ]]; then
    fl "sbatch did not return a job ID"
    exit 1
fi

ok "Submitted job ${BOLD}$JOBID${RESET}"

# ── Wait for completion ─────────────────────────────────────
section "Waiting for completion"

# Pyxis-managed jobs can sit in CF (configuring) longer while enroot pulls
# the image on first run. Use a longer timeout for the first pull.
TIMEOUT=600
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
        printf "  ${DIM}[%4ds]${RESET} state: ${YELLOW}%s${RESET}\n" "$ELAPSED" "$STATE"
        LAST_STATE="$STATE"
    else
        printf "\r  ${DIM}[%4ds]${RESET} state: ${YELLOW}%s${RESET}" "$ELAPSED" "$STATE"
    fi
    sleep 2
    ((ELAPSED+=2))
done
printf "\r%-70s\r" " "
ok "Job finished in ${BOLD}${ELAPSED}s${RESET}"

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

OUTFILE="$WORKDIR/pyxis-smoke-${JOBID}.out"
ERRFILE="$WORKDIR/pyxis-smoke-${JOBID}.err"
OUT_LINES=$(wc -l < "$OUTFILE" 2>/dev/null || echo 0)
ERR_LINES=$(wc -l < "$ERRFILE" 2>/dev/null || echo 0)
OUT_SIZE=$(ls -lh "$OUTFILE" 2>/dev/null | awk '{print $5}' || echo "0")

# ── Job details ─────────────────────────────────────────────
section "Job details"
field "JobID"     "$JOBID"
field "JobName"   "pyxis-smoke"
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

# ── Pyxis evidence in stderr ────────────────────────────────
section "Pyxis evidence (from stderr)"
if [[ -f "$ERRFILE" ]] && grep -E 'pyxis:' "$ERRFILE" >/dev/null 2>&1; then
    grep -E 'pyxis:' "$ERRFILE" | head -8 | sed "s/^/    ${DIM}│${RESET} /"
else
    fl "No 'pyxis:' lines in stderr — was --container-image actually honored?"
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
# PASS conditions:
#   - State=COMPLETED, ExitCode=0:0
#   - For burdentesting: stdout contains "REGENIE"
#   - For generic: stdout has any non-empty content
echo
PASS=0
if [[ "$STATE" == "COMPLETED" ]] && [[ "$EXITCODE" == "0:0" ]]; then
    case "$IMAGE" in
        *burdentesting*)
            grep -q "REGENIE" "$OUTFILE" 2>/dev/null && PASS=1
            ;;
        *)
            (( OUT_LINES > 0 )) && PASS=1
            ;;
    esac
fi

if [[ $PASS -eq 1 ]]; then
    printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}Pyxis+Enroot chain validated${RESET}    ${BOLD}${GREEN}│${RESET}\n"
    printf "${BOLD}${GREEN}╰──────────────────────────────────────────╯${RESET}\n"
    echo
    exit 0
else
    printf "${BOLD}${RED}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${RED}│${RESET}  ${BOLD}${RED}✗ FAIL${RESET}  ${RED}see details above${RESET}               ${BOLD}${RED}│${RESET}\n"
    printf "${BOLD}${RED}╰──────────────────────────────────────────╯${RESET}\n"
    echo
    if [[ -f "$ERRFILE" ]] && (( ERR_LINES > 0 )); then
        section "Stderr (last 20 lines)"
        tail -20 "$ERRFILE" | sed "s/^/    ${DIM}│${RESET} /"
        echo
    fi
    exit 1
fi
