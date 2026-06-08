#!/bin/bash
JOB_SCRATCH=/scratch/jobs/$SLURM_JOB_ID
[ -d "$JOB_SCRATCH" ] && rm -rf "$JOB_SCRATCH"
