# OligoAI on the Insmed Research Cluster

Quick-start for running [OligoAI](https://github.com/barneyhill/OligoAI) — Barney Hill's ML model for predicting ASO efficacy. **End-to-end validated on H200 (gpu01) as of 2026-06-02** — a 2-row synthetic test CSV produced real predictions through the full pipeline (jobs 114, 115).

---

## What's where

| Item | Location |
|---|---|
| Source code | `/software/oligoai/src/` (NetApp, visible from any node) |
| Container image | `docker://pytorch/pytorch:2.1.0-cuda11.8-cudnn8-devel` (cached in `/software/enroot-cache` after first pull, ~7 GB) |
| flash-attn 2.3.2 wheel | Auto-installed to `~/.local/lib/python3.10/site-packages/` on first run; persists across jobs (NetApp) |
| Pre-trained checkpoint | `/software/oligoai/models/OligoAI_11_09_25.ckpt` (3.1 GB; downloaded from HuggingFace `barneyhill/OligoAI`) |
| Robert's fine-tuned checkpoint | He brings his own |

---

## sbatch template — copy + edit + submit

```bash
#!/bin/bash
#SBATCH -J oligoai
#SBATCH -A informatics                  # or your team's account
#SBATCH -p gpu01                        # or gpu02
#SBATCH --gres=gpu:h200_nvl:1
#SBATCH -c 8
#SBATCH --mem=32G
#SBATCH -t 4:00:00
#SBATCH -o /home/%u/oligoai-%j.out
#SBATCH --container-image=docker://pytorch/pytorch:2.1.0-cuda11.8-cudnn8-devel
#SBATCH --container-mounts=/home/ntailor:/home/ntailor,/scratch/ntailor:/scratch

set -u

# One-time install (no-op on subsequent jobs since ~/.local persists on NetApp)
pip install --user --quiet --no-cache-dir \
    https://github.com/Dao-AILab/flash-attention/releases/download/v2.3.2/flash_attn-2.3.2+cu118torch2.1cxx11abiFALSE-cp310-cp310-linux_x86_64.whl \
    pandas scipy lightning wandb ml_collections

cd /software/oligoai/src

python3 run_inference.py \
    /path/to/your/input.csv \
    --model_checkpoint /software/oligoai/models/OligoAI_11_09_25.ckpt \
    --output_path /software/oligoai/models/predictions.csv \
    --device cuda
```

**Submit:** `sbatch oligoai.sh`
**Watch:** `tail -f /home/$USER/oligoai-<jobid>.out`

---

## Input CSV format

The script takes the data path as the **first positional arg** (no `--data_path` flag). Required columns:

| Column | Type | Example |
|---|---|---|
| `custom_id` | str | `test-001` (any unique identifier) |
| `aso_sequence_5_to_3` | DNA string | `GCATCTACGCTAGCTAGCTAG` (gets T→U converted internally) |
| `rna_context` | RNA string | `AUGCUACGUACG...` (flanking context, can be empty) |
| `inhibition_percent` | float | `50.0` (label — used for eval, not prediction) |
| `sugar_mods` | Python-list string | `"['MOE','MOE','DNA',...]"` — length must equal ASO length, values: `DNA`/`MOE`/`cET` |
| `backbone_mods` | Python-list string | `"['PS','PS',...]"` — length must equal ASO length, values: `PO`/`PS` |
| `transfection_method` | str | `Lipofection`/`Electroporation`/`Gymnosis`/`Other` |
| `dosage` | float | `100.0` |
| `split` | str | `test` (or train/val) — used for split-aware eval stats |

Need ≥2 rows for `pearsonr` correlation stats to compute (single-row inference works but the script crashes at the eval stage). A working example lives at `/software/oligoai/models/test_aso.csv`.

---

## Why these exact pins

| Pin | Reason |
|---|---|
| `pytorch:2.1.0-cuda11.8-cudnn8-devel` | OligoAI's own Dockerfile uses cu118; flash-attn 2.3.2 has cu118 wheels but no cu121 wheels. **`-devel`** (not `-runtime`) is required — Triton JIT-compiles flash-attn's rotary kernel launcher and needs `gcc`/headers, which the runtime image lacks. |
| `flash-attn==2.3.2` cu118+torch2.1+cp310 wheel | Exact-match pre-built wheel — installs in seconds, avoids the 45-min source compile. URL is hard-coded; any deviation 404s. |
| `--user` pip install | Container's `/opt/conda/` is read-only (squashfs overlay); `~/.local` is NetApp-writable and persists across jobs. |

---

## Performance caveat on H200

flash-attn 2.3.2 (October 2023) **predates full Hopper (sm_90) native kernels**. The wheel was built for `sm_70;sm_75;sm_80;sm_86+PTX`. On H200 the code runs via PTX JIT from the sm_86 path — functional but not using H200's native Hopper attention kernels.

If you need peak H200 throughput, you'd need flash-attn ≥ 2.4 — talk to Barney about loosening the upstream pin. For correctness-validation runs and small-scale inference, the current setup is fine (job 115 ran inference in 45 s on a 2-row CSV).

---

## Where to get a checkpoint

- **OligoAI checkpoint:** [`barneyhill/OligoAI/OligoAI_11_09_25.ckpt`](https://huggingface.co/barneyhill/OligoAI) on HuggingFace (3.1 GB) — already downloaded to `/software/oligoai/models/`
- **Robert's fine-tuned variant:** ask Robert
- **RinaLM base (used by OligoAI):** [Zenodo](https://zenodo.org/records/15043668/files/rinalmo_giga_pretrained.pt) — ~1 GB

Place new checkpoints on NetApp (`/home/$USER/models/` or `/mnt/compchem/models/`) so they're visible from any node and survive node loss.

---

## Troubleshooting

**`RuntimeError: Failed to find C compiler. Please specify via CC environment variable.`**
- You're on the `:runtime` image. Switch to `:cuda11.8-cudnn8-devel` — Triton JIT-compiles a launcher stub for flash-attn's rotary kernel on first use, and it needs `gcc`. The devel image has it.

**`KeyError: 'custom_id'`** (or any other column)
- Your CSV is missing a required column. See the Input CSV table above — all 9 columns must be present even for inference.

**`ValueError: 'x' and 'y' must have length at least 2`**
- Single-row inference works, but the eval stats computation requires ≥2 rows. Add a dummy second row or strip the eval block.

**`ModuleNotFoundError: No module named 'flash_attn'`**
- `~/.local` install didn't run, or pip couldn't reach the GitHub wheel URL. Check the `pip install --user` step ran cleanly. URL is exact-match — anything different will 404.

**`RuntimeError: CUDA kernel not compiled for compute capability 9.0`**
- flash-attn version too old for fp32 on H200. Use fp16/bf16 (PTX JIT path works). The probe used bfloat16 successfully.

**Container hangs on first launch**
- Pyxis is pulling the ~7 GB pytorch:cuda11.8-devel image. ~3 minutes on first node use, ~5 seconds on subsequent uses (cached on /software/enroot-cache).

**`Defaulting to user installation because normal site-packages is not writeable`**
- Expected. Container is read-only; `--user` puts deps in `~/.local`. This is by design.
