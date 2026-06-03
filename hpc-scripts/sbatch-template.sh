#!/bin/bash -l
#SBATCH -J my-job
#SBATCH -A informatics
#SBATCH -p cpu
#SBATCH -n 1
#SBATCH -c 8
#SBATCH --mem=16G
#SBATCH -t 4:00:00
#SBATCH -o /home/%u/my-job-%j.out      # NetApp-shared; visible from any node

module load regenie plink2 bcftools r

echo "=== JOB ==="
echo "host:   $(hostname)"
echo "jobid:  $SLURM_JOB_ID"
echo "cores:  $SLURM_CPUS_PER_TASK"
echo "node:   $SLURM_JOB_NODELIST"
echo

echo "=== TOOLS ==="
regenie --version 2>&1 | head -1
plink2 --version | head -1
bcftools --version | head -1
R --version | head -1
echo

echo "=== WORK ==="
# Your commands here. Write outputs to whatever path makes sense for you:
#   /home/$USER/...     → NetApp, visible everywhere, durable
#   /mnt/<team>/...     → NetApp team-shared (compchem/humgen/informatics)
#   /scratch/$USER/...  → fast local NVMe, per-node; copy to NetApp before exit if you need it later
#
# Example:
# regenie --step 2 --bgen chr1.bgen --phenoFile phenos.tsv --bt --firth \
#         --threads $SLURM_CPUS_PER_TASK --out /home/$USER/burden_chr1

echo "DONE"
