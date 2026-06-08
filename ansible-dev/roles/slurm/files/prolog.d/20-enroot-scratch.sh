#!/bin/bash
# Per-user enroot working dirs on local /scratch.
# Image cache is on shared NetApp /software/enroot-cache and managed
# elsewhere; this prolog only creates the per-user/per-node state
# directories enroot writes into during a job.
set -e

USER_SCRATCH="/scratch/${SLURM_JOB_USER}"
for sub in data runtime tmp; do
    mkdir -p "${USER_SCRATCH}/enroot/${sub}"
done
chown -R "${SLURM_JOB_USER}:" "${USER_SCRATCH}"
chmod 700 "${USER_SCRATCH}"
