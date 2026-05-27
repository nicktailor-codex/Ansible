# Pyxis + Enroot Setup — Step by Step

Goal: replace Apptainer-based container execution with Pyxis (Slurm SPANK plugin) + Enroot (NVIDIA's unprivileged container runtime). Users will run Docker images natively via `srun --container-image=docker://...`.

Cluster: `research-cluster` — cpu01 (controller) + gpu01 + gpu02 + cgpu01.

**Already done on cpu01:**
- `build-essential`, `pkg-config`, `libslurm-dev`, `curl`, `jq`, `squashfs-tools`, `parallel`, `zstd` installed
- Slurm headers verified (`/usr/include/slurm/spank.h`, `slurm.h` present)
- Slurm plugin dir confirmed: `/usr/lib/x86_64-linux-gnu/slurm-wlm/`

---

## Step 1 — Install Enroot (all 4 nodes)

Run on **cpu01, gpu01, gpu02, cgpu01** (paste into root shell on each):

```bash
ENROOT_VER=3.5.0
ARCH=$(dpkg --print-architecture)

cd /tmp
curl -sfSL -O https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VER}/enroot_${ENROOT_VER}-1_${ARCH}.deb
curl -sfSL -O https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VER}/enroot+caps_${ENROOT_VER}-1_${ARCH}.deb

apt install -y /tmp/enroot_${ENROOT_VER}-1_${ARCH}.deb /tmp/enroot+caps_${ENROOT_VER}-1_${ARCH}.deb

# Verify
enroot version
which enroot   # should be /usr/bin/enroot
```

The `enroot+caps` package grants the setuid-style capabilities Enroot needs (unprivileged user namespaces + mount). It's separate so you can audit it.

---

## Step 2 — Build Pyxis from source on cpu01

Pyxis isn't packaged — you build the SPANK plugin against your Slurm version.

```bash
# Build directory
mkdir -p /opt/build && cd /opt/build

# Pin to a release matching Slurm 23.11.x — v0.20.0 is the right tag
git clone --depth 1 --branch v0.20.0 https://github.com/NVIDIA/pyxis.git
cd pyxis

# Build (uses /usr/include/slurm headers automatically)
make CPPFLAGS="-I/usr/include/slurm" -j$(nproc)

# Confirm the .so was produced
ls -la spank_pyxis.so
```

If `make` complains about missing Slurm headers, double-check `libslurm-dev` is installed (`dpkg -l libslurm-dev`).

---

## Step 3 — Install Pyxis SPANK plugin on each node

The compiled `spank_pyxis.so` needs to land in Slurm's plugin dir on **every** node.

On cpu01 (where you built it):

```bash
# Install locally
install -m 644 /opt/build/pyxis/spank_pyxis.so /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so

# Distribute to the other nodes
for node in insiiukgpu01 insiiukgpu02 insiiukcgpu01; do
  scp /opt/build/pyxis/spank_pyxis.so ntailor@${node}:/tmp/
  ssh ntailor@${node} "sudo install -m 644 /tmp/spank_pyxis.so /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so"
done

# Verify on each node
for node in insiiukcpu01 insiiukgpu01 insiiukgpu02 insiiukcgpu01; do
  echo "=== $node ==="
  ssh ntailor@$node "ls -la /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so"
done
```

---

## Step 4 — Configure Slurm to load Pyxis (all 4 nodes)

Slurm reads `/etc/slurm/plugstack.conf` to discover SPANK plugins. This file doesn't currently exist — create it on every node.

```bash
# Run on each node (or via ssh loop)
cat <<'EOF' | sudo tee /etc/slurm/plugstack.conf
# SPANK plugin stack — loaded by slurmctld and slurmd at job submission/launch.
# Each entry: <required|optional> <path> [args]

required /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so
EOF

sudo chmod 644 /etc/slurm/plugstack.conf
```

`required` = if plugin fails to load, the job fails. Use `optional` during initial bring-up if you want it to fail soft.

---

## Step 5 — Configure Enroot (all 4 nodes)

Enroot needs to know where to cache pulled images, where to unpack per-user data, and where to put temp files. The defaults dump to `~/.local/share/enroot` which is wrong for HPC. Point everything at `/scratch` (per-user) plus a shared cluster cache.

```bash
# Run on each node
sudo mkdir -p /scratch/cluster-software/enroot-cache
sudo chmod 1777 /scratch/cluster-software/enroot-cache  # sticky world-writable

sudo tee /etc/enroot/enroot.conf <<'EOF'
# Enroot global configuration

# Shared image cache (read-mostly) — populated by `enroot import`
ENROOT_CACHE_PATH       /scratch/cluster-software/enroot-cache

# Per-user data (unpacked containers) — local to each node
ENROOT_DATA_PATH        /scratch/$USER/enroot-data

# Per-user runtime state
ENROOT_RUNTIME_PATH     /scratch/$USER/enroot-runtime

# Per-user temp (pull/unpack scratch)
ENROOT_TEMP_PATH        /scratch/$USER/enroot-tmp

# Reasonable defaults for HPC
ENROOT_CONNECT_TIMEOUT  30
ENROOT_TRANSFER_RETRIES 3
ENROOT_SQUASH_OPTS      -comp lzo -noI -noD -noF -noX

# Restrict capabilities passed into containers (security hardening)
ENROOT_RESTRICT_DEV     yes
EOF

# Each user will need their own subdirs the first time they run
# (Enroot creates them on demand, but pre-stage if you want)
```

Later, once NetApp `/software` is mounted, move `ENROOT_CACHE_PATH` to `/software/enroot-cache` so all nodes share one image catalog. For now, each node caches independently on `/scratch` — costs disk, but no broken-NIC dependency.

---

## Step 6 — Restart Slurm (all 4 nodes)

```bash
# On cpu01 (controller) — restart slurmctld AND slurmd
sudo systemctl restart slurmctld
sudo systemctl restart slurmd

# On gpu01, gpu02, cgpu01 — just slurmd
ssh insiiukgpu01 sudo systemctl restart slurmd
ssh insiiukgpu02 sudo systemctl restart slurmd
ssh insiiukcgpu01 sudo systemctl restart slurmd

# Verify Pyxis loaded
sudo journalctl -u slurmctld --since "1 min ago" | grep -i pyxis
sudo journalctl -u slurmd --since "1 min ago" | grep -i pyxis
```

Look for log lines like:

```
spank_pyxis.so: pyxis: version 0.20.0
spank-pyxis: enroot version 3.5.0
```

If you see "Failed to load" or "required plugin not found", check Step 3 (plugin path) and Step 4 (plugstack.conf syntax).

---

## Step 7 — Smoke test with `srun --container-image`

```bash
# Simplest possible test — hello-world container, prints from inside, exits
srun --partition=cpu --account=research --container-image=docker://hello-world hostname

# Better test — actual ubuntu image, run a command
srun --partition=cpu --account=research --container-image=docker://ubuntu:24.04 bash -c 'cat /etc/os-release'

# GPU test (once link issues fixed) — pull a CUDA image to a GPU partition
srun --partition=gpu01 --account=research --gres=gpu:1 \
     --container-image=docker://nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

What's happening behind the scenes:
1. Pyxis sees `--container-image` flag on the srun
2. Calls `enroot import` to pull the Docker image (cached in `/scratch/cluster-software/enroot-cache`)
3. Calls `enroot create` to make a per-job unpacked container
4. Calls `enroot start` to run your command inside the container
5. Cleans up the unpacked data on job exit

---

## Step 8 — Import the burdentesting image into Enroot

Once Pyxis is working, pull the existing burdentesting image (the one currently in Apptainer SIF format on `/scratch/cluster-software/containers/`):

```bash
# Import once (any node — will go into the shared cache)
export ENROOT_CACHE_PATH=/scratch/cluster-software/enroot-cache
enroot import docker://egardner413/mrcepid-burdentesting:latest

# Verify
ls -lh /scratch/cluster-software/enroot-cache/
# Should see a .sqsh file (Enroot's squashfs format, like Apptainer's SIF)
```

To use it via Slurm:

```bash
srun --partition=cpu --account=research \
     --container-image=/scratch/cluster-software/enroot-cache/egardner413+mrcepid-burdentesting+latest.sqsh \
     regenie --help
```

---

## Step 9 — Fleet rollout script (optional but recommended)

Wrap Steps 1, 3, 4, 5, 6 into a `register_pyxis.sh` mirroring your existing [register_gpu_nodes.sh](register_gpu_nodes.sh). Skeleton:

```bash
#!/usr/bin/env bash
# register_pyxis.sh — install Pyxis + Enroot fleet-wide
set -euo pipefail

SSH_USER="${SSH_USER:-ntailor}"
NODES="${NODES:-insiiukgpu01:10.174.16.57 insiiukgpu02:10.174.16.58 insiiukcgpu01:10.174.16.56}"
ENROOT_VER=3.5.0
PYXIS_SO=/opt/build/pyxis/spank_pyxis.so

for entry in $NODES; do
  HOST=${entry%%:*}
  IP=${entry##*:}
  echo "=== $HOST ==="

  # 1. Install enroot
  ssh -t "$SSH_USER@$IP" "
    cd /tmp
    curl -sfSL -O https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VER}/enroot_${ENROOT_VER}-1_amd64.deb
    curl -sfSL -O https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VER}/enroot+caps_${ENROOT_VER}-1_amd64.deb
    sudo apt install -y /tmp/enroot_${ENROOT_VER}-1_amd64.deb /tmp/enroot+caps_${ENROOT_VER}-1_amd64.deb
  "

  # 2. Push pyxis.so
  scp "$PYXIS_SO" "$SSH_USER@$IP:/tmp/"
  ssh -t "$SSH_USER@$IP" "sudo install -m 644 /tmp/spank_pyxis.so /usr/lib/x86_64-linux-gnu/slurm-wlm/"

  # 3. Push plugstack.conf
  ssh -t "$SSH_USER@$IP" "
    echo 'required /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so' | sudo tee /etc/slurm/plugstack.conf
  "

  # 4. Push enroot.conf (copy from cpu01)
  scp /etc/enroot/enroot.conf "$SSH_USER@$IP:/tmp/enroot.conf"
  ssh -t "$SSH_USER@$IP" "sudo install -m 644 /tmp/enroot.conf /etc/enroot/enroot.conf"

  # 5. Restart slurmd
  ssh -t "$SSH_USER@$IP" "sudo systemctl restart slurmd"
done
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `error: spank: Plugin "spank_pyxis.so" not found` | Plugin not in slurm-wlm dir on that node | Step 3, scp the .so |
| `error: spank: required plugin failed to load` | Pyxis built against wrong Slurm ABI | Rebuild with matching `libslurm-dev` version |
| Job hangs at "Pulling image..." | Bad network, slow registry | Check connectivity to docker.io / DNS |
| `enroot: failed to create rootfs` | `/scratch/$USER/enroot-data` doesn't exist or wrong perms | Pre-create with `mkdir -p /scratch/$USER/enroot-{data,runtime,tmp}` |
| `pivot_root: Permission denied` | User namespaces disabled | Check `sysctl kernel.unprivileged_userns_clone` returns 1 |
| Slow first job per image | Empty cache | First user "warms" the cache via `enroot import` — afterwards, all jobs pull from local cache |

---

## What about Apptainer?

User decision: drop Apptainer in favor of Pyxis+Enroot.

- The Apptainer binary (`/usr/bin/apptainer`) and the burdentesting SIF (`/scratch/cluster-software/containers/burdentesting-latest.sif`) can stay installed for now — they don't conflict with Pyxis+Enroot.
- Once you've validated the Enroot workflow with burdentesting end-to-end, you can:
  - `sudo apt remove apptainer` on all 4 nodes
  - `rm /scratch/cluster-software/containers/*.sif`
  - Update [Burdentesting_Container_Deployment_Guide.docx] to reference Enroot + Pyxis

---

## Cross-reference

- Original Apptainer install steps: [Apptainer](Apptainer)
- Slurm node registration script: [register_gpu_nodes.sh](register_gpu_nodes.sh)
- Existing slurm.conf: [/etc/slurm/slurm.conf](/etc/slurm/slurm.conf)
- Session log: [Progress.md](Progress.md)
