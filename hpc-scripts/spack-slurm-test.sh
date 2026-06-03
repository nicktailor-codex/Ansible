#!/bin/bash -l
#SBATCH -J spack-slurm-test
#SBATCH -A informatics
#SBATCH -p gpu01
#SBATCH -n 2
#SBATCH --mem=4G
#SBATCH -t 5:00
#SBATCH -o /home/ntailor/spack-slurm-test-%j.out

echo "==================================="
echo "Spack + Lmod via Slurm — smoke test"
echo "==================================="
echo "Hostname:    $(hostname)"
echo "Job ID:      $SLURM_JOB_ID"
echo "Partition:   $SLURM_JOB_PARTITION"
echo "Node:        $SLURM_JOB_NODELIST"
echo "CPUs:        $SLURM_CPUS_ON_NODE"
echo "Started:     $(date -Iseconds)"
echo

echo "----- AVAILABLE MODULES -----"
module avail 2>&1 | grep -v '^$' | head -15

echo
echo "----- LOADING regenie + plink2 + bcftools + samtools + r -----"
module load regenie plink2 bcftools samtools r

echo
echo "----- BINARY PATHS (should resolve to /software/spack/opt/spack/...) -----"
for tool in regenie plink2 bcftools samtools R; do
    printf "%-10s -> %s\n" "$tool" "$(which $tool)"
done

echo
echo "----- VERSIONS -----"
regenie --version 2>&1 | head -1
plink2 --version | head -1
bcftools --version | head -1
samtools --version | head -1
R --version | head -1

echo
echo "----- ACTUAL WORK: plink2 dry-run (--help only) -----"
plink2 --help 2>&1 | head -5

echo
echo "----- REGENIE help -----"
regenie --help 2>&1 | head -10

echo
echo "Finished:    $(date -Iseconds)"
echo "DONE"
