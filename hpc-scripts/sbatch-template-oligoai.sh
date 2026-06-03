#!/bin/bash
#SBATCH -J oligoai
#SBATCH -A informatics
#SBATCH -p gpu01
#SBATCH --gres=gpu:h200_nvl:1
#SBATCH -c 8
#SBATCH --mem=32G
#SBATCH -t 4:00:00
#SBATCH -o /home/%u/oligoai-%j.out
#SBATCH --container-image=docker://pytorch/pytorch:2.1.0-cuda11.8-cudnn8-devel
#SBATCH --container-mounts=/home/ntailor:/home/ntailor,/scratch/ntailor:/scratch

set -u

# flash-attn 2.3.2 cu118 wheel — exact match to OligoAI's Dockerfile.
# --user install lands in ~/.local (NetApp), persists across jobs, so this
# is a fast no-op on subsequent runs.
pip install --user --quiet --no-cache-dir \
    https://github.com/Dao-AILab/flash-attention/releases/download/v2.3.2/flash_attn-2.3.2+cu118torch2.1cxx11abiFALSE-cp310-cp310-linux_x86_64.whl \
    pandas scipy lightning wandb ml_collections

cd /software/oligoai/src

python3 run_inference.py \
    /software/oligoai/models/test_aso.csv \
    --model_checkpoint /software/oligoai/models/OligoAI_11_09_25.ckpt \
    --output_path /software/oligoai/models/predictions.csv \
    --device cuda
