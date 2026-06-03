#!/bin/bash
#SBATCH -J my-container-job
#SBATCH -A informatics
#SBATCH -p cpu
#SBATCH -n 1
#SBATCH -c 8
#SBATCH --mem=8G
#SBATCH -t 4:00:00
#SBATCH -o /home/%u/my-container-job-%j.out
#SBATCH --container-image=docker://egardner413/mrcepid-burdentesting:latest
#SBATCH --container-mounts=/home/ntailor:/home/ntailor

# Everything below runs INSIDE the container.

# Per-job output dir on NetApp (visible cluster-wide, survives node loss).
OUTDIR=/home/$USER/jobs/$SLURM_JOB_ID
mkdir -p "$OUTDIR"

echo "=== JOB ==="
echo "host:   $(hostname)"
echo "jobid:  $SLURM_JOB_ID"
echo "cores:  $SLURM_CPUS_PER_TASK"
echo "outdir: $OUTDIR"
echo

echo "=== TOOLS ==="
regenie --version 2>&1 | head -1
plink2 --version | head -1
bcftools --version | head -1
R --version | head -1
echo

echo "=== WORK ==="
# Your commands here. Example:
# regenie --step 2 --bgen chr1.bgen --phenoFile phenos.tsv --bt --firth \
#         --threads $SLURM_CPUS_PER_TASK --out $OUTDIR/burden_chr1

echo "DONE — results in $OUTDIR"
