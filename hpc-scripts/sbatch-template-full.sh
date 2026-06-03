#!/bin/bash -l
# =============================================================================
# sbatch-template-full.sh — verbose reference template with every common
# Slurm directive + alternates commented out for quick copy-in.
#
# Use sbatch-template.sh for the lean version most users want.
#
# Usage:
#   cp ~/run-dir/sbatch-template-full.sh my-job.sh
#   $EDITOR my-job.sh        # edit the #SBATCH block + the WORK section
#   sbatch my-job.sh
#
# Watch progress:
#   squeue -u $USER          # is it queued / running?
#   tail -f my-job-<jobid>.out
#
# After completion:
#   sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS,NodeList
# =============================================================================

# ── Slurm directives — TWEAK FOR YOUR JOB ─────────────────────────────────
#SBATCH -J my-job                       # job name (shows up in squeue)
#SBATCH -A informatics                  # billing account (informatics/compchem/human_genetics/bioinformatics)
#SBATCH -p cpu                          # partition: cpu / cpu-overflow / gpu01 / gpu02 / cgpu01 / interactive
#SBATCH -n 1                            # number of tasks (usually 1 for non-MPI)
#SBATCH -c 8                            # cores per task
#SBATCH --mem=32G                       # total memory; if loading container images, set ≥3G floor
#SBATCH -t 4:00:00                      # walltime — HH:MM:SS or D-HH:MM:SS (max per partition: see cheatsheet)
#SBATCH -o %x-%j.out                    # stdout — %x=job name, %j=job ID
#SBATCH -e %x-%j.err                    # stderr (omit this line to merge stderr into stdout)
#SBATCH --mail-user=ntailor             # @insmed.com is appended automatically
#SBATCH --mail-type=END,FAIL            # email on END, FAIL, BEGIN, REQUEUE, ALL

# For GPU jobs uncomment one:
##SBATCH --gres=gpu:1                   # any GPU
##SBATCH --gres=gpu:h200_nvl:1          # specific to gpu01/gpu02
##SBATCH --gres=gpu:l4:1                # specific to cgpu01

# For array jobs uncomment:
##SBATCH --array=1-100%10               # 100 tasks, max 10 concurrent — use $SLURM_ARRAY_TASK_ID inside

# ── Environment ──────────────────────────────────────────────────────────
# Load the tools you need. Versions optional; omit /X.Y to get default.
# module avail   on a login shell to see what's available.
module load regenie/3.4.1 plink2/2.00a5.11 bcftools/1.20

# ── Sanity (cheap, logs document what actually ran) ──────────────────────
echo "===== job ${SLURM_JOB_ID} on ${SLURM_JOB_NODELIST} ====="
echo "started:  $(date -Iseconds)"
echo "user:     $USER"
echo "tools:"
echo "  regenie  → $(which regenie)  ($(regenie --version 2>&1 | head -1))"
echo "  plink2   → $(which plink2)   ($(plink2 --version | head -1))"
echo "  bcftools → $(which bcftools) ($(bcftools --version | head -1))"
echo

# ── WORK — replace this with your actual commands ───────────────────────
cd /mnt/humgen/my-analysis     # or /mnt/compchem, /mnt/informatics, /scratch/$USER ...

# Example: regenie step 2 burden test
# regenie --step 2 \
#         --bgen ukbb/chr1.bgen \
#         --phenoFile phenos/binary.tsv \
#         --bt --firth --approx \
#         --threads $SLURM_CPUS_PER_TASK \
#         --out /scratch/$USER/burden_chr1

echo "(no real work configured — edit this file)"

# ── End ──────────────────────────────────────────────────────────────────
echo "finished: $(date -Iseconds)"
