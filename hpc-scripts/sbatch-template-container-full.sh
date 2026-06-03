#!/bin/bash
# =============================================================================
# sbatch-template-container-full.sh — verbose reference template for
# container-based jobs with every common Pyxis directive documented.
#
# Use sbatch-template-container.sh for the lean version most users want.
#
# Container variant — uses Pyxis + Enroot to run inside a Docker image
# instead of loading modules. Pick this template when:
#   - You need an exact reproducible toolchain (e.g. burdentesting image)
#   - You have a workflow that already lives in a Docker container
#   - You need libraries not packaged in our Spack stack
#
# Usage:
#   cp ~/run-dir/sbatch-template-container-full.sh my-job.sh
#   $EDITOR my-job.sh        # edit the #SBATCH block + container-image + WORK
#   sbatch my-job.sh
#
# Watch progress:
#   squeue -u $USER
#   tail -f my-job-<jobid>.out
#
# After completion:
#   sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS,NodeList
# =============================================================================

# ── Slurm directives — TWEAK FOR YOUR JOB ─────────────────────────────────
#SBATCH -J my-container-job             # job name
#SBATCH -A informatics                  # billing account
#SBATCH -p cpu                          # partition
#SBATCH -n 1                            # tasks
#SBATCH -c 8                            # cores per task
#SBATCH --mem=8G                        # ⚠️ MINIMUM 3G for Pyxis squashfs build; 8G safe default
#SBATCH -t 4:00:00                      # walltime
#SBATCH -o %x-%j.out                    # stdout
#SBATCH --mail-user=ntailor             # @insmed.com appended automatically
#SBATCH --mail-type=END,FAIL

# ── Container config ─────────────────────────────────────────────────────
# Pyxis pulls the image once into /software/enroot-cache (NetApp-shared),
# then every job reuses it. First-pull time depends on image size:
# burdentesting (~700MB) ≈ 20s; pytorch:cuda12.4 (~4GB) ≈ 2-3 min.
#SBATCH --container-image=docker://egardner413/mrcepid-burdentesting:latest

# Mount host paths into the container. Common patterns:
#   /home/$USER         → user's home (scripts, configs)
#   /mnt/<volume>       → team data (compchem/humgen/informatics)
#   /scratch/$USER      → local fast scratch (per-node)
# Format: hostpath:containerpath,hostpath2:containerpath2
#SBATCH --container-mounts=/home/ntailor:/home/ntailor,/mnt/humgen:/data,/scratch/ntailor:/scratch

# For GPU jobs uncomment + change partition above to gpu01/gpu02/cgpu01:
##SBATCH --gres=gpu:h200_nvl:1

# ── Sanity (cheap, logs document what actually ran) ──────────────────────
echo "===== job ${SLURM_JOB_ID} on ${SLURM_JOB_NODELIST} ====="
echo "started:  $(date -Iseconds)"
echo "user:     $USER"
echo "container: ${SLURM_JOB_NAME}"
echo "tools in container:"
which regenie  && regenie --version | head -1
which plink2   && plink2 --version | head -1
which bcftools && bcftools --version | head -1
echo

# ── WORK — replace this with your actual commands ───────────────────────
cd /data                       # = /mnt/humgen on the host (per --container-mounts above)

# Example: regenie step 2 burden test inside the burdentesting container
# regenie --step 2 \
#         --bgen ukbb/chr1.bgen \
#         --phenoFile phenos/binary.tsv \
#         --bt --firth --approx \
#         --threads $SLURM_CPUS_PER_TASK \
#         --out /scratch/burden_chr1

echo "(no real work configured — edit this file)"

# ── End ──────────────────────────────────────────────────────────────────
echo "finished: $(date -Iseconds)"
