#!/bin/bash
JOB_SCRATCH=/scratch/jobs/$SLURM_JOB_ID
mkdir -p "$JOB_SCRATCH"
chown "$SLURM_JOB_USER:" "$JOB_SCRATCH"
chmod 700 "$JOB_SCRATCH"
