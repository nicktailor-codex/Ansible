#!/usr/bin/env bash
# ============================================================
# burdentesting_smoke.sh — Validate the MRC EPID burdentesting
# container end-to-end. Runs interactively (no Slurm) and
# returns non-zero if any check fails.
#
# Usage:
#   ./burdentesting_smoke.sh [path-to-sif]
#
# Defaults to /scratch/cluster-software/containers/burdentesting-latest.sif
# When NetApp is up, point at /software/containers/burdentesting-<ver>.sif
# ============================================================
set -uo pipefail

SIF="${1:-/scratch/cluster-software/containers/burdentesting-latest.sif}"
FAILS=0
PASSES=0

if [[ ! -f "$SIF" ]]; then
    echo "[!] SIF not found: $SIF"
    exit 1
fi

if ! command -v apptainer >/dev/null 2>&1; then
    echo "[!] apptainer not installed"
    exit 1
fi

echo "═══════════════════════════════════════════════════════"
echo " Burdentesting container smoke test"
echo " SIF: $SIF"
echo " Size: $(ls -lh "$SIF" | awk '{print $5}')"
echo "═══════════════════════════════════════════════════════"

# Helper: run a check, report pass/fail
check() {
    local label="$1"
    shift
    if apptainer exec "$SIF" "$@" >/dev/null 2>&1; then
        printf "  [PASS] %s\n" "$label"
        ((PASSES++))
    else
        printf "  [FAIL] %s\n" "$label"
        ((FAILS++))
    fi
}

# Helper: run a check that's allowed to exit non-zero (tools with no --help
# or that exit non-zero when given --version they don't recognize). Passes
# if the tool produces ANY output on stdout or stderr.
check_runs() {
    local label="$1"
    shift
    local output
    output=$(apptainer exec "$SIF" "$@" 2>&1 || true)
    if [[ -n "$output" ]]; then
        printf "  [PASS] %s\n" "$label"
        ((PASSES++))
    else
        printf "  [FAIL] %s (no output)\n" "$label"
        ((FAILS++))
    fi
}

echo
echo "── 1. Binary tools ──"
check "regenie"           regenie --help
check "bolt"              bolt --help
check "samtools"          samtools --version
check "bcftools"          bcftools --version
check "plink"             plink --version
check "plink2"            plink2 --version
check "bedtools"          bedtools --version
check_runs "metal"        bash -c 'echo QUIT | metal'
check_runs "gcta"         gcta64
check "qctool"            qctool -help
check "bgenix"            bgenix -help

echo
echo "── 2. R stack ──"
check "R interpreter"     R --version

R_LIBS="library(GENESIS); library(GMMAT); library(STAAR); \
        library(SKAT); library(MetaSKAT); library(tidyverse)"

if apptainer exec "$SIF" R -e "$R_LIBS" >/dev/null 2>&1; then
    echo "  [PASS] R packages: GENESIS, GMMAT, STAAR, SKAT, MetaSKAT, tidyverse"
    ((PASSES++))
else
    echo "  [FAIL] R packages — one or more failed to load"
    echo "         Re-run interactively to see which:"
    echo "         apptainer exec $SIF R -e '$R_LIBS' 2>&1 | tail -20"
    ((FAILS++))
fi

echo
echo "── 3. SAIGE custom-build scripts ──"
check "step1_fitNULLGLMM.R"  step1_fitNULLGLMM.R  --help
check "step2_SPAtests.R"     step2_SPAtests.R     --help
check "step3_LDmat.R"        step3_LDmat.R        --help
check "createSparseGRM.R"    createSparseGRM.R    --help

echo
echo "── 4. VEP and Python ──"
check_runs "VEP (perl)"   perl /ensembl-vep/vep --help
check "python"            python --version
check "general_utilities" python -c "import general_utilities"

echo
echo "═══════════════════════════════════════════════════════"
echo " Result: $PASSES passed, $FAILS failed"
echo "═══════════════════════════════════════════════════════"

exit $FAILS
