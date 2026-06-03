#!/bin/bash -l
# =============================================================================
# spack_slurm_smoke.sh — validate the Spack + Lmod + Slurm chain.
#
# Submits a sbatch job that loads every burden-stack module, asserts each
# binary resolves to /software/spack/opt/spack/, checks each version against
# the burdentesting Docker image, and reports a clean PASS/FAIL summary.
#
# Usage:
#   sbatch spack_slurm_smoke.sh                # default partition (gpu01)
#   sbatch -p cpu  spack_slurm_smoke.sh        # override partition
#   sbatch -p gpu02 spack_slurm_smoke.sh
#
# Designed for SUBMISSION via sbatch, not direct execution.
# Output goes to ./spack-smoke-<jobid>.out by default.
# =============================================================================
#SBATCH -J spack-smoke
#SBATCH -A informatics
#SBATCH -p gpu01
#SBATCH -n 2
#SBATCH --mem=4G
#SBATCH -t 5:00
#SBATCH -o spack-smoke-%j.out
set -uo pipefail

# Colours only on a TTY (this is a Slurm batch job, so usually plain text)
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

# ── output helpers ──
section() { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$1"; ((PASS++)); }
fail()    { printf "  ${RED}✗${RESET} %s\n" "$1"; ((FAIL++)); }
warn()    { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }   # informational, no counter
info()    { printf "  ${DIM}%s${RESET}\n" "$1"; }
field()   { printf "  ${DIM}%-14s${RESET} %s\n" "$1" "$2"; }

PASS=0
FAIL=0

# ── 0. Environment ──
section "Environment"
field "Hostname"   "$(hostname)"
field "Job ID"     "${SLURM_JOB_ID:-(not in slurm)}"
field "Partition"  "${SLURM_JOB_PARTITION:-n/a}"
field "Node"       "${SLURM_JOB_NODELIST:-n/a}"
field "CPUs"       "${SLURM_CPUS_ON_NODE:-n/a}"
field "Memory"     "${SLURM_MEM_PER_NODE:-n/a} MB"
field "Started"    "$(date -Iseconds)"

if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    warn "Running directly (not via sbatch) — Slurm scheduling chain not exercised, but module/binary checks below still apply. For full validation use: sbatch $0"
else
    ok "Running under Slurm (job $SLURM_JOB_ID on $SLURM_JOB_NODELIST)"
fi

# ── 1. Lmod available ──
section "Lmod module system"
if command -v module >/dev/null 2>&1; then
    ok "module command is available"
else
    fail "module command NOT available — check #!/bin/bash -l shebang"
    exit 1
fi

if [[ "$MODULEPATH" == */software/spack/share/spack/lmod/* ]]; then
    ok "MODULEPATH includes spack core dir"
    field "MODULEPATH" "$MODULEPATH"
else
    fail "MODULEPATH missing spack core dir — check /etc/profile.d/spack.sh"
    field "MODULEPATH" "$MODULEPATH"
fi

# ── 2. Expected modules visible ──
section "Burden stack modules available"
EXPECTED_MODULES=(regenie plink plink2 bcftools samtools htslib gcta r python jq)
AVAIL=$(module --terse avail 2>&1)
for m in "${EXPECTED_MODULES[@]}"; do
    if echo "$AVAIL" | grep -qE "^$m/"; then
        v=$(echo "$AVAIL" | grep -E "^$m/" | head -1)
        ok "$m available as $v"
    else
        fail "$m NOT in module avail"
    fi
done

# ── 3. Load + run each tool ──
section "Loading + running tools"

declare -A EXPECTED_VERSION=(
    [regenie]="3.4.1"
    [plink]="1.9-beta6.27"
    [plink2]="2.00a5.11"
    [bcftools]="1.20"
    [samtools]="1.20"
    [htslib]="1.20"
    [gcta]="1.94.1"
    [r]="4.3.3"
    [python]="3.11.9"
    [jq]="1.7.1"
)

# Load everything at once (autoload pulls deps)
if module load regenie plink plink2 bcftools samtools htslib gcta r python jq 2>/dev/null; then
    ok "module load (all 10) succeeded"
else
    fail "module load failed"
fi

# ── 3a. Binary paths ──
declare -A BIN_NAMES=(
    [regenie]=regenie
    [plink]=plink
    [plink2]=plink2
    [bcftools]=bcftools
    [samtools]=samtools
    [htslib]=htsfile
    [gcta]=gcta64       # upstream names the 64-bit build `gcta64`, not `gcta`
    [r]=R
    [python]=python3
    [jq]=jq
)
section "Binary paths under /software/spack/opt/spack/"
for mod in "${!BIN_NAMES[@]}"; do
    bin="${BIN_NAMES[$mod]}"
    path=$(command -v "$bin" 2>/dev/null || echo "")
    if [[ "$path" == /software/spack/opt/spack/* ]]; then
        ok "$bin → $path"
    elif [[ -n "$path" ]]; then
        fail "$bin found at $path (NOT in /software/spack/opt/spack/)"
    else
        fail "$bin not found in PATH"
    fi
done

# ── 3b. Version checks ──
section "Tool versions match burdentesting image pins"
check_version() {
    local mod="$1" cmd="$2" expected_substr="$3"
    local out
    out=$(eval "$cmd" 2>&1 | head -1)
    if echo "$out" | grep -q "$expected_substr"; then
        ok "$mod → '$out' (expected substring: $expected_substr)"
    else
        fail "$mod → '$out' (expected substring: $expected_substr)"
    fi
}

check_version regenie  "regenie --version"                          "${EXPECTED_VERSION[regenie]}"
check_version plink    "plink --version"                            "v1.90"
check_version plink2   "plink2 --version"                           "${EXPECTED_VERSION[plink2]}"
check_version bcftools "bcftools --version | head -1"               "${EXPECTED_VERSION[bcftools]}"
check_version samtools "samtools --version | head -1"               "${EXPECTED_VERSION[samtools]}"
check_version htslib   "htsfile --version | head -1"                "${EXPECTED_VERSION[htslib]}"
check_version r        "R --version | head -1"                      "${EXPECTED_VERSION[r]}"
check_version python   "python3 --version"                          "${EXPECTED_VERSION[python]}"
check_version jq       "jq --version"                               "${EXPECTED_VERSION[jq]}"
# gcta has irregular version output and is named `gcta64` — match by major.minor only
check_version gcta     "gcta64 2>&1 | head -3 | tail -1"  "1.94"

# ── 3c. Real exec — actually run a binary, not just --version ──
section "Real execution (binary runs, not just --version)"
if regenie --help >/dev/null 2>&1; then ok "regenie --help executed"; else fail "regenie --help failed"; fi
if plink2 --help >/dev/null 2>&1;  then ok "plink2 --help executed";  else fail "plink2 --help failed";  fi
if Rscript -e 'cat("ok\n")' 2>&1 | grep -q ok; then ok "Rscript executed inline R"; else fail "Rscript failed"; fi
# gcta UX symlink — `gcta` should resolve to the same binary as `gcta64`
if [[ "$(readlink -f $(command -v gcta 2>/dev/null) 2>/dev/null)" == "$(readlink -f $(command -v gcta64 2>/dev/null) 2>/dev/null)" ]] && [[ -n "$(command -v gcta)" ]]; then
    ok "gcta symlink resolves to gcta64"
else
    fail "gcta symlink missing or broken — users have to type gcta64"
fi

# ── 4. Summary ──
TOTAL=$((PASS + FAIL))
echo
echo "${BOLD}╭──────────────────────────────────────────────────────────────╮${RESET}"
if [[ $FAIL -eq 0 ]]; then
    printf "${BOLD}│  ${GREEN}✓ PASS${RESET}${BOLD}   Spack + Lmod + Slurm chain healthy   ${PASS}/${TOTAL} checks  │${RESET}\n"
else
    printf "${BOLD}│  ${RED}✗ FAIL${RESET}${BOLD}   ${PASS}/${TOTAL} passed, ${RED}${FAIL}${RESET}${BOLD} failed                       │${RESET}\n"
fi
echo "${BOLD}╰──────────────────────────────────────────────────────────────╯${RESET}"
echo
field "Finished"   "$(date -Iseconds)"
exit $FAIL
