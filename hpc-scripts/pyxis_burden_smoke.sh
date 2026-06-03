#!/usr/bin/env bash
# ============================================================
# pyxis_burden_smoke.sh — Full content validation of the MRC EPID
# burdentesting Docker image via Pyxis + Enroot through Slurm.
# Submits sbatch jobs that run 20 content checks inside the container,
# parses the results, and renders a sectioned [PASS]/[FAIL] report.
#
# Modes:
#   ./pyxis_burden_smoke.sh                          # all 4 partitions in parallel
#   ./pyxis_burden_smoke.sh all                      # explicit
#   ./pyxis_burden_smoke.sh cpu                      # single partition
#   ./pyxis_burden_smoke.sh gpu01 research IMG       # full args
#
# When multiple partitions are run, jobs are submitted to all of them
# concurrently — Slurm queues each on its target node and they execute
# in parallel since each partition has a distinct node. Total wall clock
# = slowest single-node test, not the sum.
#
# Defaults:
#   partitions = cpu, gpu01, gpu02, cgpu01
#   account    = research
#   image      = docker://egardner413/mrcepid-burdentesting:latest
# ============================================================
set -uo pipefail

# ── Args ────────────────────────────────────────────────────
ARG1="${1:-all}"
ACCOUNT="${2:-informatics}"
IMAGE="${3:-docker://egardner413/mrcepid-burdentesting:latest}"

if [[ "$ARG1" == "all" ]] || [[ -z "$ARG1" ]]; then
    PARTITIONS=(cpu gpu01 gpu02 cgpu01)
else
    PARTITIONS=("$ARG1")
fi

# /home is NetApp-mounted on every cluster node (migration 2026-05-29);
# /scratch is LOCAL per node. We submit from one node and the job runs
# on another, so output must land on a shared FS. Output files cluster
# under ~/smoketest/.
WORKDIR="/home/$USER/smoketest"
IN_CONTAINER_SCRIPT="$WORKDIR/burden_in_container.sh"

# ── Colors ──────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
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

# ── Write the in-container check script ─────────────────────
cat > "$IN_CONTAINER_SCRIPT" <<'IN_CONTAINER'
#!/usr/bin/env bash
# Runs INSIDE the burdentesting container.
set -uo pipefail

extract_version() {
    local raw="$1"
    [[ -z "$raw" ]] && { echo ""; return; }
    local out
    out=$(echo "$raw" | grep -iE 'version|\bv?[0-9]+\.[0-9]+' | grep -vE '^[[:space:]]*[|*+=_-]+[[:space:]]*$' | head -1)
    [[ -z "$out" ]] && out=$(echo "$raw" | grep -v '^[[:space:]]*$' | grep -vE '^[[:space:]]*[|*+=_-]+[[:space:]]*$' | head -1)
    echo "$out" | tr -d '\r' | sed 's/^[[:space:]|*+]*//;s/[[:space:]|*+]*$//' | head -c 100
}

v() {
    local label="$1"; shift
    local raw
    raw=$("$@" 2>&1)
    # Detect false positives: shell errors masquerading as tool output.
    # gcta64 in the burdentesting image, for example, doesn't exist —
    # bash emits "command not found" to stderr, which without this guard
    # gets captured as a "version string" and the check reports PASS.
    if echo "$raw" | grep -qE 'command not found|No such file or directory|cannot execute'; then
        printf "RESULT %s| FAIL\n" "$label"
        return
    fi
    if [[ -z "$raw" ]]; then
        printf "RESULT %s| FAIL\n" "$label"
        return
    fi
    printf "RESULT %s|%s PASS\n" "$label" "$(extract_version "$raw")"
}

ck() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "RESULT %s| PASS\n" "$label"
    else
        printf "RESULT %s| FAIL\n" "$label"
    fi
}

echo "SECTION binary_tools"
v "regenie"  regenie --help
v "bolt"     bolt --help
v "samtools" samtools --version
v "bcftools" bcftools --version
v "plink"    plink --version
v "plink2"   plink2 --version
v "bedtools" bedtools --version
v "metal"    bash -c 'echo QUIT | metal'
v "gcta"     gcta
v "qctool"   qctool -help
v "bgenix"   bgenix -help

echo "SECTION r_stack"
v "R interpreter" R --version

R_LIBS='library(GENESIS); library(GMMAT); library(STAAR); library(SKAT); library(MetaSKAT); library(tidyverse)'
if R -e "$R_LIBS" >/dev/null 2>&1; then
    printf "RESULT R packages: GENESIS, GMMAT, STAAR, SKAT, MetaSKAT, tidyverse| PASS\n"
else
    printf "RESULT R packages: GENESIS, GMMAT, STAAR, SKAT, MetaSKAT, tidyverse| FAIL\n"
fi

echo "SECTION saige_scripts"
v "step1_fitNULLGLMM.R" step1_fitNULLGLMM.R --help
v "step2_SPAtests.R"    step2_SPAtests.R    --help
v "step3_LDmat.R"       step3_LDmat.R       --help
v "createSparseGRM.R"   createSparseGRM.R   --help

echo "SECTION vep_python"
v "VEP (perl)" bash -c "perl /ensembl-vep/vep --help 2>&1"
v "python"     python --version
ck "general_utilities" python -c "import general_utilities"

echo "DONE"
IN_CONTAINER
chmod +x "$IN_CONTAINER_SCRIPT"

# ── Banner ──────────────────────────────────────────────────
echo
printf "${BOLD}${BLUE}╭────────────────────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Pyxis + Enroot Burdentesting Smoke Test${RESET}              ${BOLD}${BLUE}│${RESET}\n"
printf "${BOLD}${BLUE}╰────────────────────────────────────────────────────────╯${RESET}\n"

section "Configuration"
field "Partitions" "${PARTITIONS[*]}"
field "Account"    "$ACCOUNT"
field "Image"      "$IMAGE"
field "Workdir"    "$WORKDIR"
field "User"       "$USER"
field "Host"       "$(hostname -s)"

# ── Submit one job per partition ────────────────────────────
section "Submitting jobs"

declare -A JOB_PARTITION  # JOBID -> partition name

for p in "${PARTITIONS[@]}"; do
    JOBID=$(sbatch --parsable \
        --partition="$p" \
        --account="$ACCOUNT" \
        --time=00:15:00 --mem=4G \
        --chdir="$WORKDIR" \
        --output="$WORKDIR/burden-pyxis-%j.out" \
        --error="$WORKDIR/burden-pyxis-%j.err" \
        --job-name="burden-smoke-$p" \
        --container-image="$IMAGE" \
        --container-mounts="$WORKDIR:$WORKDIR" \
        --wrap="bash $IN_CONTAINER_SCRIPT" 2>/dev/null)
    if [[ -z "${JOBID:-}" ]]; then
        fl "sbatch failed for partition $p — skipping"
        continue
    fi
    JOB_PARTITION[$JOBID]="$p"
    ok "Submitted ${BOLD}$JOBID${RESET} → partition ${BOLD}$p${RESET}"
done

if (( ${#JOB_PARTITION[@]} == 0 )); then
    fl "No jobs submitted successfully"
    exit 1
fi

# ── Wait for all jobs to complete (in parallel) ─────────────
section "Waiting for completion"

TIMEOUT=900
ELAPSED=0

while true; do
    pending_summary=""
    pending=0
    for j in "${!JOB_PARTITION[@]}"; do
        if squeue -h -j "$j" 2>/dev/null | grep -q .; then
            state=$(squeue -h -j "$j" -o "%T" 2>/dev/null | head -1)
            pending_summary+="${JOB_PARTITION[$j]}=$state "
            pending=1
        fi
    done
    if (( pending == 0 )); then
        printf "\r%-100s\r" " "
        ok "All ${#JOB_PARTITION[@]} jobs complete in ${BOLD}${ELAPSED}s${RESET}"
        break
    fi
    if (( ELAPSED >= TIMEOUT )); then
        printf "\r%-100s\r" " "
        fl "Timeout after ${TIMEOUT}s — cancelling remaining jobs"
        for j in "${!JOB_PARTITION[@]}"; do
            scancel "$j" 2>/dev/null || true
        done
        break
    fi
    printf "\r  ${DIM}[%4ds]${RESET} pending: ${YELLOW}%s${RESET}" "$ELAPSED" "$pending_summary"
    sleep 5
    ((ELAPSED+=5))
done

sleep 1  # let sacct catch up

# ── Per-partition rendering ─────────────────────────────────
declare -A PASS_COUNT
declare -A FAIL_COUNT
declare -A VERDICT
declare -A NODE_USED

declare -A SECTION_TITLES=(
    [binary_tools]="── 1. Binary tools ──"
    [r_stack]="── 2. R stack ──"
    [saige_scripts]="── 3. SAIGE custom-build scripts ──"
    [vep_python]="── 4. VEP and Python ──"
)

get_field() {
    sacct -j "$1" --format="$2" -X -n -P 2>/dev/null | head -1 | tr -d ' '
}

# Render in partition order (deterministic) instead of associative
# array iteration order (which is non-deterministic in bash).
for p in "${PARTITIONS[@]}"; do
    JOBID=""
    for j in "${!JOB_PARTITION[@]}"; do
        [[ "${JOB_PARTITION[$j]}" == "$p" ]] && { JOBID="$j"; break; }
    done
    [[ -z "$JOBID" ]] && continue

    STATE=$(get_field "$JOBID" State)
    EXITCODE=$(get_field "$JOBID" ExitCode)
    NODE=$(get_field "$JOBID" NodeList)
    ELAPSED_TIME=$(get_field "$JOBID" Elapsed)

    NODE_USED[$p]="$NODE"

    OUTFILE="$WORKDIR/burden-pyxis-${JOBID}.out"
    ERRFILE="$WORKDIR/burden-pyxis-${JOBID}.err"

    section "Partition: ${BOLD}$p${RESET}${BLUE}  (job $JOBID on $NODE)${RESET}"
    field "State"    "$STATE"
    field "ExitCode" "$EXITCODE"
    field "Elapsed"  "$ELAPSED_TIME"

    # Pyxis evidence
    if [[ -f "$ERRFILE" ]] && grep -E 'pyxis:' "$ERRFILE" >/dev/null 2>&1; then
        pyxis_line=$(grep -E 'pyxis: imported' "$ERRFILE" | head -1)
        [[ -n "$pyxis_line" ]] && printf "  ${DIM}%-12s${RESET} ${GREEN}✓${RESET} imported via pyxis\n" "Container"
    fi

    pass=0; fail=0
    if [[ -f "$OUTFILE" ]]; then
        while IFS= read -r line; do
            case "$line" in
                SECTION\ *)
                    sname="${line#SECTION }"
                    echo
                    printf "  ${BOLD}%s${RESET}\n" "${SECTION_TITLES[$sname]:-── $sname ──}"
                    ;;
                RESULT\ *)
                    rest="${line#RESULT }"
                    verdict="${rest##* }"
                    rest_no_verdict="${rest% *}"
                    label="${rest_no_verdict%%|*}"
                    version="${rest_no_verdict#*|}"
                    [[ "$label" == "$rest_no_verdict" ]] && version=""
                    if [[ "$verdict" == "PASS" ]]; then
                        if [[ -n "$version" ]]; then
                            printf "    ${GREEN}[PASS]${RESET} %-42s ${DIM}%s${RESET}\n" "$label" "$version"
                        else
                            printf "    ${GREEN}[PASS]${RESET} %s\n" "$label"
                        fi
                        ((pass++))
                    else
                        printf "    ${RED}[FAIL]${RESET} %s\n" "$label"
                        ((fail++))
                    fi
                    ;;
            esac
        done < "$OUTFILE"
    else
        fl "Output file missing: $OUTFILE"
    fi

    PASS_COUNT[$p]=$pass
    FAIL_COUNT[$p]=$fail
    if [[ "$STATE" == "COMPLETED" ]] && [[ "$EXITCODE" == "0:0" ]] && (( fail == 0 )) && (( pass > 0 )); then
        VERDICT[$p]="PASS"
    else
        VERDICT[$p]="FAIL"
    fi
done

# ── Cluster-wide summary ────────────────────────────────────
echo
printf "${BOLD}═══════════════════════════════════════════════════════════════════════${RESET}\n"
printf " ${BOLD}Cluster-wide validation summary${RESET}\n"
printf "${BOLD}═══════════════════════════════════════════════════════════════════════${RESET}\n"
printf "  ${BOLD}%-12s %-18s %-6s %-6s %-8s${RESET}\n" "Partition" "Node" "Pass" "Fail" "Verdict"
printf "  ${DIM}%-12s %-18s %-6s %-6s %-8s${RESET}\n" "---------" "----" "----" "----" "-------"
overall_fail=0
for p in "${PARTITIONS[@]}"; do
    v="${VERDICT[$p]:-?}"
    color="$RED"
    [[ "$v" == "PASS" ]] && color="$GREEN"
    [[ "$v" == "PASS" ]] || overall_fail=1
    printf "  %-12s %-18s %-6s %-6s ${color}${BOLD}%-8s${RESET}\n" \
        "$p" "${NODE_USED[$p]:--}" "${PASS_COUNT[$p]:-0}" "${FAIL_COUNT[$p]:-0}" "$v"
done
echo

if (( overall_fail == 0 )); then
    printf "${BOLD}${GREEN}╭──────────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}all partitions validated${RESET}            ${BOLD}${GREEN}│${RESET}\n"
    printf "${BOLD}${GREEN}╰──────────────────────────────────────────────╯${RESET}\n"
    echo
    exit 0
else
    printf "${BOLD}${RED}╭──────────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${RED}│${RESET}  ${BOLD}${RED}✗ FAIL${RESET}  ${RED}one or more partitions failed${RESET}       ${BOLD}${RED}│${RESET}\n"
    printf "${BOLD}${RED}╰──────────────────────────────────────────────╯${RESET}\n"
    echo
    exit 1
fi
