#!/bin/bash -l
# run-spack-smoke.sh — submit the spack smoke test via sbatch, wait for
# it to finish, then dump the output. One-command wrapper so you don't
# do the sbatch + sleep + cat dance manually.
#
# Usage:
#   ./run-spack-smoke.sh                    # default partition (gpu01)
#   ./run-spack-smoke.sh -p cpu             # override partition (any sbatch flag works)
#   ./run-spack-smoke.sh -p cgpu01 -t 2:00
set -euo pipefail

SMOKE=/home/ntailor/run-dir/spack_slurm_smoke.sh
OUTDIR=/home/ntailor

# ── Submit ──
echo "▸ Submitting spack smoke test via sbatch..."
SUBMIT_OUT=$(sbatch "$@" "$SMOKE")
echo "  $SUBMIT_OUT"

# Extract job ID from "Submitted batch job NNN"
JOBID=$(echo "$SUBMIT_OUT" | awk '/Submitted batch job/ {print $NF}')
if [[ -z "$JOBID" ]]; then
    echo "ERROR: couldn't parse job ID from sbatch output"
    exit 1
fi

# ── Wait ──
echo "▸ Waiting for job $JOBID to finish..."
START=$(date +%s)
while ! sacct -j "$JOBID" -X -n --format=State 2>/dev/null | grep -qE 'COMPLETED|FAILED|TIMEOUT|CANCELLED|NODE_FAIL'; do
    sleep 2
done
ELAPSED=$(( $(date +%s) - START ))
echo "  Job finished after ${ELAPSED}s wall-clock (including queue wait)"

# ── Final state ──
echo
echo "▸ Slurm state:"
sacct -j "$JOBID" --format=JobID,State,ExitCode,Elapsed,MaxRSS,NodeList

# ── Output ──
OUT="$OUTDIR/spack-smoke-$JOBID.out"
echo
echo "▸ Output ($OUT):"
echo "─────────────────────────────────────────────────────────────────"
if [[ -r "$OUT" ]]; then
    cat "$OUT"
else
    echo "  WARNING: output file $OUT not found"
fi
echo "─────────────────────────────────────────────────────────────────"

# ── Exit with the job's exit code so this script is CI-friendly ──
EXIT_RAW=$(sacct -j "$JOBID" -X -n --format=ExitCode 2>/dev/null | tr -d ' ')
EXIT_CODE="${EXIT_RAW%%:*}"   # strip ":signal" suffix
exit "${EXIT_CODE:-1}"
