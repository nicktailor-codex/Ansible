#!/usr/bin/env bash
# ============================================================
# pyxis_gpu_smoke.sh — Validate end-to-end GPU passthrough via
# Slurm GRES → Pyxis → Enroot → libnvidia-container-tools hook.
#
# Submits a short sbatch job with --gres=gpu:1 and a CUDA base
# image; runs `nvidia-smi` inside the container and asserts the
# expected GPU model is visible (matches the partition's hardware).
#
# Usage:
#   ./pyxis_gpu_smoke.sh [partition] [account] [docker://IMAGE]
#
# Defaults:
#   partition = gpu01
#   account   = research
#   image     = docker://nvcr.io#nvidia/cuda:12.6.0-base-ubuntu24.04
#
# Note on image URL syntax: enroot uses `docker://REGISTRY#PATH:TAG`
# (with `#`) for non-default registries. Apptainer's `docker://nvcr.io/path`
# form does NOT work — enroot reads it as a Docker Hub image path and
# pulls from registry-1.docker.io with a 401 error.
#
# Expected GPU per partition (lookup table inside):
#   gpu01, gpu02 → H200 NVL
#   cgpu01       → L4
# ============================================================
set -uo pipefail

PARTITION="${1:-gpu01}"
ACCOUNT="${2:-informatics}"
IMAGE="${3:-docker://nvcr.io#nvidia/cuda:12.6.0-base-ubuntu24.04}"
# /home is NetApp-mounted on every cluster node (migration 2026-05-29);
# /scratch is LOCAL per node. We submit from one node and the job runs
# on another, so output must land on a shared FS. Output files cluster
# under ~/smoketest/ so they don't litter the home root.
WORKDIR="/home/$USER/smoketest"

# Expected GPU name fragment for this partition.
case "$PARTITION" in
    gpu01|gpu02) EXPECTED_GPU="H200 NVL" ;;
    cgpu01)      EXPECTED_GPU="L4" ;;
    *)           EXPECTED_GPU="" ;;  # unknown partition → skip assertion
esac

# ── Colors ──────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

section() { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
field()   { printf "  ${DIM}%-16s${RESET} %s\n" "$1" "$2"; }
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
printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Pyxis + Enroot GPU Smoke Test${RESET}                         ${BOLD}${BLUE}│${RESET}\n"
printf "${BOLD}${BLUE}╰────────────────────────────────────────────────────────╯${RESET}\n"

section "Configuration"
field "Partition"     "$PARTITION"
field "Account"       "$ACCOUNT"
field "Image"         "$IMAGE"
field "Workdir"       "$WORKDIR"
field "User"          "$USER"
field "Host"          "$(hostname -s)"
field "GRES request"  "gpu:1"
field "Expected GPU"  "${EXPECTED_GPU:-<none — partition not in lookup>}"

# ── Submit ──────────────────────────────────────────────────
section "Submitting job"

# Inside the container: dump nvidia-smi structured info plus device
# files for visibility. The structured query is what we parse; the
# header/devices are for human eyes when reading the output file.
#
# Slurm --wrap creates a /bin/sh (dash on Ubuntu) script; avoid
# bash-isms here (e.g., `set -o pipefail` makes dash exit 2 instantly).
WRAP_CMD='echo "=== nvidia-smi --version ==="
nvidia-smi --version 2>&1 | head -2
echo
echo "=== nvidia-smi (full) ==="
nvidia-smi
echo
echo "=== /dev/nvidia* devices ==="
ls -la /dev/nvidia* 2>&1
echo
echo "=== GPU_STRUCTURED ==="
nvidia-smi --query-gpu=index,name,driver_version,memory.total,uuid --format=csv,noheader 2>&1
echo "=== END ==="'

JOBID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --account="$ACCOUNT" \
    --gres=gpu:1 \
    --time=00:10:00 --mem=4G \
    --chdir="$WORKDIR" \
    --output="$WORKDIR/gpu-smoke-%j.out" \
    --error="$WORKDIR/gpu-smoke-%j.err" \
    --job-name="gpu-smoke" \
    --container-image="$IMAGE" \
    --wrap="$WRAP_CMD")

if [[ -z "${JOBID:-}" ]]; then
    fl "sbatch did not return a job ID"
    exit 1
fi
ok "Submitted job ${BOLD}$JOBID${RESET}"

# ── Wait for completion ─────────────────────────────────────
section "Waiting for completion"

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
ELAPSED_TIME=$(get_field "$JOBID" Elapsed)
ALLOCTRES=$(get_field "$JOBID" AllocTRES)

OUTFILE="$WORKDIR/gpu-smoke-${JOBID}.out"
ERRFILE="$WORKDIR/gpu-smoke-${JOBID}.err"

section "Job details"
field "JobID"      "$JOBID"
field "Node"       "$NODELIST"
field "Elapsed"    "$ELAPSED_TIME"
field "State"      "$STATE"
field "ExitCode"   "$EXITCODE"
field "AllocTRES"  "$ALLOCTRES"
field "Output"     "$OUTFILE"
field "Stderr"     "$ERRFILE"

# ── Pyxis evidence ──────────────────────────────────────────
section "Pyxis evidence (from stderr)"
if [[ -f "$ERRFILE" ]] && grep -E 'pyxis:' "$ERRFILE" >/dev/null 2>&1; then
    grep -E 'pyxis:' "$ERRFILE" | head -6 | sed "s/^/    ${DIM}│${RESET} /"
else
    fl "No 'pyxis:' lines in stderr — was --container-image actually honored?"
fi

# ── Parse GPU detection ─────────────────────────────────────
section "GPU detected inside container"

if [[ ! -f "$OUTFILE" ]]; then
    fl "Output file missing: $OUTFILE"
    exit 1
fi

# Extract the structured CSV line(s) between GPU_STRUCTURED and END.
GPU_CSV=$(awk '/=== GPU_STRUCTURED ===/{f=1; next} /=== END ===/{f=0} f' "$OUTFILE" | grep -v '^[[:space:]]*$')

if [[ -z "$GPU_CSV" ]]; then
    fl "No GPU info found in job output. nvidia-smi may have failed inside the container."
    if grep -i 'no devices were found\|failed' "$OUTFILE" >/dev/null 2>&1; then
        section "Excerpt from job stdout (look for nvidia-smi failure)"
        grep -iE 'nvidia|failed|no devices|error' "$OUTFILE" | head -10 | sed "s/^/    ${DIM}│${RESET} /"
    fi
    GPU_MATCH=0
else
    # CSV: index, name, driver_version, memory.total, uuid
    GPU_COUNT=$(echo "$GPU_CSV" | wc -l)
    SAW_EXPECTED=0
    while IFS= read -r line; do
        IFS=',' read -r idx name drv mem uuid <<<"$line"
        idx=$(echo "$idx" | xargs); name=$(echo "$name" | xargs)
        drv=$(echo "$drv" | xargs); mem=$(echo "$mem" | xargs)
        uuid=$(echo "$uuid" | xargs)
        echo
        field "GPU index"    "$idx"
        field "GPU name"     "$name"
        field "Driver"       "$drv"
        field "Memory"       "$mem"
        field "UUID"         "$uuid"
        if [[ -n "$EXPECTED_GPU" ]] && [[ "$name" == *"$EXPECTED_GPU"* ]]; then
            SAW_EXPECTED=1
        fi
    done <<<"$GPU_CSV"

    echo
    field "GPUs visible"  "$GPU_COUNT"
    if [[ -n "$EXPECTED_GPU" ]]; then
        if (( SAW_EXPECTED == 1 )); then
            printf "  ${DIM}%-16s${RESET} ${GREEN}✓ matches partition (%s)${RESET}\n" "Expected match" "$EXPECTED_GPU"
            GPU_MATCH=1
        else
            printf "  ${DIM}%-16s${RESET} ${RED}✗ expected '%s' not seen${RESET}\n" "Expected match" "$EXPECTED_GPU"
            GPU_MATCH=0
        fi
    else
        printf "  ${DIM}%-16s${RESET} ${YELLOW}(skipped — no expected GPU for this partition)${RESET}\n" "Expected match"
        GPU_MATCH=1  # don't fail when partition isn't in the lookup
    fi
fi

# ── Verdict ─────────────────────────────────────────────────
echo
if [[ "$STATE" == "COMPLETED" ]] && [[ "$EXITCODE" == "0:0" ]] && (( GPU_MATCH == 1 )); then
    printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}GPU passthrough validated${RESET}       ${BOLD}${GREEN}│${RESET}\n"
    printf "${BOLD}${GREEN}╰──────────────────────────────────────────╯${RESET}\n"
    echo
    exit 0
else
    printf "${BOLD}${RED}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${RED}│${RESET}  ${BOLD}${RED}✗ FAIL${RESET}  ${RED}see details above${RESET}               ${BOLD}${RED}│${RESET}\n"
    printf "${BOLD}${RED}╰──────────────────────────────────────────╯${RESET}\n"
    echo
    if [[ -f "$ERRFILE" ]] && [[ -s "$ERRFILE" ]]; then
        section "Stderr (last 20 lines)"
        tail -20 "$ERRFILE" | sed "s/^/    ${DIM}│${RESET} /"
        echo
    fi
    exit 1
fi
