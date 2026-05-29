#!/usr/bin/env bash
# ============================================================
# pyxis_burden_smoke.sh — Full content validation of the MRC EPID
# burdentesting Docker image via Pyxis + Enroot through Slurm.
# Counterpart to burden_without_slurm_smoke.sh (which runs the
# same checks via Apptainer + SIF).
#
# Submits ONE sbatch job with --container-image=docker://... that
# runs all content checks sequentially inside the container,
# capturing tool versions where the binary has a clean --version.
# Parses the resulting output and renders the familiar
# [PASS]/[FAIL] sectioned report with a final verdict.
#
# Usage:
#   ./pyxis_burden_smoke.sh [partition] [account] [docker://IMAGE]
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
IN_CONTAINER_SCRIPT="$WORKDIR/burden_in_container.sh"

# ── Colors (only if stdout is a TTY) ────────────────────────
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
# Single-quoted heredoc → no host-side expansion; the script
# executes verbatim inside the burdentesting container.
#
# Output protocol parsed by the host wrapper:
#   SECTION <name>                   — start of a logical section
#   RESULT <label>|<version> PASS    — check passed; version optional
#   RESULT <label>|       FAIL       — check failed; version may be empty
cat > "$IN_CONTAINER_SCRIPT" <<'IN_CONTAINER'
#!/usr/bin/env bash
# Runs INSIDE the burdentesting container.
set -uo pipefail

# Pull a sensible version string out of arbitrary tool output:
#   1. First line containing "version" (case-insensitive) or vN.N pattern
#   2. Fall back: first non-empty, non-decoration line
# Then strip pipe/star/plus decoration and trim whitespace.
extract_version() {
    local raw="$1"
    [[ -z "$raw" ]] && { echo ""; return; }
    local out
    out=$(echo "$raw" | grep -iE 'version|\bv?[0-9]+\.[0-9]+' | grep -vE '^[[:space:]]*[|*+=_-]+[[:space:]]*$' | head -1)
    [[ -z "$out" ]] && out=$(echo "$raw" | grep -v '^[[:space:]]*$' | grep -vE '^[[:space:]]*[|*+=_-]+[[:space:]]*$' | head -1)
    echo "$out" | tr -d '\r' | sed 's/^[[:space:]|*+]*//;s/[[:space:]|*+]*$//' | head -c 100
}

# v: probe a tool; the probe doubles as the existence check.
# PASS if the probe produced any output (most --help/--version cmds do
# even if exit is non-zero). Version line is parsed from the output.
v() {
    local label="$1"; shift
    local raw
    raw=$("$@" 2>&1)
    if [[ -z "$raw" ]]; then
        printf "RESULT %s| FAIL\n" "$label"
        return
    fi
    printf "RESULT %s|%s PASS\n" "$label" "$(extract_version "$raw")"
}

# ck: silent-success check (no output expected). For things like
# `python -c "import X"` that pass with empty stdout/stderr.
ck() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "RESULT %s| PASS\n" "$label"
    else
        printf "RESULT %s| FAIL\n" "$label"
    fi
}

# ── 1. Binary tools ──────────────────────────────────────────
echo "SECTION binary_tools"
v "regenie"  regenie --help
v "bolt"     bolt --help
v "samtools" samtools --version
v "bcftools" bcftools --version
v "plink"    plink --version
v "plink2"   plink2 --version
v "bedtools" bedtools --version
v "metal"    bash -c 'echo QUIT | metal'
v "gcta"     gcta64
v "qctool"   qctool -help
v "bgenix"   bgenix -help

# ── 2. R stack ───────────────────────────────────────────────
echo "SECTION r_stack"
v "R interpreter" R --version

R_LIBS='library(GENESIS); library(GMMAT); library(STAAR); library(SKAT); library(MetaSKAT); library(tidyverse)'
if R -e "$R_LIBS" >/dev/null 2>&1; then
    printf "RESULT R packages: GENESIS, GMMAT, STAAR, SKAT, MetaSKAT, tidyverse| PASS\n"
else
    printf "RESULT R packages: GENESIS, GMMAT, STAAR, SKAT, MetaSKAT, tidyverse| FAIL\n"
fi

# ── 3. SAIGE custom-build scripts ────────────────────────────
echo "SECTION saige_scripts"
v "step1_fitNULLGLMM.R" step1_fitNULLGLMM.R --help
v "step2_SPAtests.R"    step2_SPAtests.R    --help
v "step3_LDmat.R"       step3_LDmat.R       --help
v "createSparseGRM.R"   createSparseGRM.R   --help

# ── 4. VEP and Python ────────────────────────────────────────
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
field "Partition" "$PARTITION"
field "Account"   "$ACCOUNT"
field "Image"     "$IMAGE"
field "Workdir"   "$WORKDIR"
field "User"      "$USER"
field "Host"      "$(hostname -s)"
field "In-script" "$IN_CONTAINER_SCRIPT"

# ── Submit ──────────────────────────────────────────────────
section "Submitting job"

JOBID=$(sbatch --parsable \
    --partition="$PARTITION" \
    --account="$ACCOUNT" \
    --time=00:15:00 --mem=4G \
    --chdir="$WORKDIR" \
    --output="$WORKDIR/burden-pyxis-%j.out" \
    --error="$WORKDIR/burden-pyxis-%j.err" \
    --job-name="burden-pyxis-smoke" \
    --container-image="$IMAGE" \
    --container-mounts="$WORKDIR:$WORKDIR" \
    --wrap="bash $IN_CONTAINER_SCRIPT")

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

OUTFILE="$WORKDIR/burden-pyxis-${JOBID}.out"
ERRFILE="$WORKDIR/burden-pyxis-${JOBID}.err"

section "Job details"
field "JobID"     "$JOBID"
field "Node"      "$NODELIST"
field "Elapsed"   "$ELAPSED_TIME"
field "State"     "$STATE"
field "ExitCode"  "$EXITCODE"
field "Output"    "$OUTFILE"
field "Stderr"    "$ERRFILE"

# ── Pyxis evidence (proves the container chain actually ran) ─
section "Pyxis evidence (from stderr)"
if [[ -f "$ERRFILE" ]] && grep -E 'pyxis:' "$ERRFILE" >/dev/null 2>&1; then
    grep -E 'pyxis:' "$ERRFILE" | head -6 | sed "s/^/    ${DIM}│${RESET} /"
else
    fl "No 'pyxis:' lines in stderr — was --container-image actually honored?"
fi

# ── Parse + render content checks ───────────────────────────
section "Content checks"

if [[ ! -f "$OUTFILE" ]]; then
    fl "Output file missing: $OUTFILE"
    exit 1
fi

PASSES=0
FAILS=0
declare -A SECTION_TITLES=(
    [binary_tools]="── 1. Binary tools ──"
    [r_stack]="── 2. R stack ──"
    [saige_scripts]="── 3. SAIGE custom-build scripts ──"
    [vep_python]="── 4. VEP and Python ──"
)

while IFS= read -r line; do
    case "$line" in
        SECTION\ *)
            sname="${line#SECTION }"
            echo
            printf "  ${BOLD}%s${RESET}\n" "${SECTION_TITLES[$sname]:-── $sname ──}"
            ;;
        RESULT\ *)
            rest="${line#RESULT }"
            verdict="${rest##* }"               # PASS|FAIL (last word)
            rest_no_verdict="${rest% *}"         # before last space
            label="${rest_no_verdict%%|*}"       # before first pipe
            version="${rest_no_verdict#*|}"      # after first pipe
            # No pipe present → label == rest_no_verdict, so version is empty.
            [[ "$label" == "$rest_no_verdict" ]] && version=""

            if [[ "$verdict" == "PASS" ]]; then
                if [[ -n "$version" ]]; then
                    printf "    ${GREEN}[PASS]${RESET} %-42s ${DIM}%s${RESET}\n" "$label" "$version"
                else
                    printf "    ${GREEN}[PASS]${RESET} %s\n" "$label"
                fi
                ((PASSES++))
            else
                printf "    ${RED}[FAIL]${RESET} %s\n" "$label"
                ((FAILS++))
            fi
            ;;
        DONE) ;;  # end marker
    esac
done < "$OUTFILE"

# ── Totals + verdict ────────────────────────────────────────
TOTAL=$((PASSES + FAILS))

echo
printf "${BOLD}═══════════════════════════════════════════════════════${RESET}\n"
printf " ${BOLD}Result: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}  (of %d checks)\n" "$PASSES" "$FAILS" "$TOTAL"
printf "${BOLD}═══════════════════════════════════════════════════════${RESET}\n"
echo

if [[ "$STATE" == "COMPLETED" ]] && [[ "$EXITCODE" == "0:0" ]] && (( FAILS == 0 )) && (( PASSES > 0 )); then
    printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}Container content validated${RESET}     ${BOLD}${GREEN}│${RESET}\n"
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
