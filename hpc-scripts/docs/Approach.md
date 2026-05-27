# Cluster Software Distribution — Approach

Date: 2026-05-22
Status: cpu01 validated. Fleet rollout pending. NetApp `/software` volume pending creation.

## TL;DR

- **Container runtime:** Pyxis (Slurm SPANK plugin) + Enroot (NVIDIA's unprivileged runtime), consuming **Docker images** natively. **Apptainer is being retired.**
- **Software distribution:** Single shared NetApp volume at `/software` (2 TB, NFS v4.2) — Spack tree + container catalog + per-user namespace.
- **Two-tier I/O:** **Pull from `/software` (NFS), run on `/scratch` (local NVMe).** Sequential reads from shared catalog, high-IOPS execution stays local.
- **Fleet rollout pattern:** Mirrors existing [register_gpu_nodes.sh](register_gpu_nodes.sh) — script on cpu01 pushes Enroot install + Pyxis binary + configs to each node via SSH, restarts slurmd, verifies.

---

## Why this stack

The earlier choice was **Apptainer** (Singularity-derived, file-format SIFs). It works, but stakeholder direction now favors **Pyxis + Enroot** for these reasons:

1. **Native Slurm integration.** Pyxis is a SPANK plugin — users add `--container-image=docker://...` directly to `srun`/`sbatch`. No wrapper scripts.
2. **Docker images first-class.** Enroot pulls and converts Docker images on demand. The existing burdentesting image lives at Docker Hub (`egardner413/mrcepid-burdentesting`); no separate SIF build step required.
3. **NVIDIA HPC standard.** NVIDIA's reference HPC stack uses Pyxis + Enroot. GPU passthrough via `nvidia-container-toolkit` is well-trodden.
4. **Unprivileged, rootless.** Enroot uses unprivileged user namespaces. No daemon. No setuid risks.

Apptainer's strengths (immutable SIF, OCI compatibility) are well-served by the .sqsh format Enroot uses internally — same squashfs-based immutability.

---

## Architecture

### Storage layout

```
NetApp 10.174.16.28 (NFSv4.2)
└── /software  (2 TB)
    ├── /spack/                    ← Spack tree + Lmod modulefiles
    ├── /enroot-cache/             ← Pulled Docker images (.sqsh files), shared
    ├── /containers/               ← Curated catalog (versioned, per sub-account)
    │   ├── bioinformatics/
    │   ├── compchem/
    │   ├── human_genetics/
    │   └── users/<ad-name>/       ← per-user namespace (quota'd)
    └── /modulefiles/              ← Lmod modulefiles for both Spack and container wrappers

Local on each node
└── /scratch  (8 TB NVMe per node, sticky 1777)
    ├── /cluster-software/         ← bootstrap area, pre-NetApp
    │   └── enroot-cache/          ← will move to /software/enroot-cache once /software is mounted
    └── /<user>/
        ├── enroot-data/           ← unpacked rootfs per running job
        ├── enroot-runtime/        ← per-job state
        └── enroot-tmp/            ← pull/unpack scratch
```

### Why two storage tiers

| Concern | NFS `/software` | Local `/scratch` |
|---|---|---|
| **Latency** | Higher (10G to NetApp, NFS overhead) | NVMe-direct, microseconds |
| **IOPS ceiling** | Shared, capped by NIC + filer | Per-node, full NVMe bandwidth |
| **Cost of failure** | Whole-fleet impact | One node only |
| **Suits** | Sequential reads of big artifacts | Millions of small reads/writes |

A container starts by extracting its rootfs from a `.sqsh` file into `ENROOT_DATA_PATH`. That's millions of small files (every R package, every shared library, every binary). If this happened on NFS, every job start would saturate the storage NIC and contend with other nodes' jobs. So:

- **`ENROOT_CACHE_PATH=/software/enroot-cache`** → bulk sequential reads, fine on NFS
- **`ENROOT_DATA_PATH=/scratch/$USER/enroot-data`** → high IOPS, local only

### System-level vs shared

Three categories of artifact, three locations:

| Artifact | Where | Why |
|---|---|---|
| `/usr/bin/enroot`, `enroot+caps` | Per-node OS (apt-installed) | OS-level binary, can't be NFS |
| `/usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so` | Per-node | Loaded by slurmd at startup — must be on local FS |
| `/etc/slurm/plugstack.conf`, `/etc/enroot/enroot.conf` | Per-node | Read by daemons at start/invocation — must be local |
| Image cache (`.sqsh` files) | NetApp `/software` | Big, immutable, shared across fleet |
| Spack tree | NetApp `/software` | Build once, mount everywhere |
| Per-user containers | NetApp `/software/containers/users/<ad>/` | Personal namespace, quota'd |

---

## Job execution — where files live during each phase

A single job touches multiple storage tiers. Understanding the split is critical because each tier has different performance, durability, and sharing characteristics.

### Per-phase storage map

| Phase | Path | Storage tier | Why |
|---|---|---|---|
| **Container catalog** (read) | `/software/enroot-cache/` | NetApp NFS | Shared `.sqsh` files. Pulled once per image, read by all nodes. Sequential reads — NFS is fine. |
| **Container unpack** (write, then exec) | `/scratch/$USER/enroot-data/` | Local NVMe per node | Millions of small file reads/writes during job. Must be fast local; NFS would serialize all jobs through one storage NIC. |
| **Per-job runtime state** | `/scratch/$USER/enroot-runtime/` | Local NVMe | Mount info, namespace handles. Job-scoped. |
| **Pull/unpack scratch** | `/scratch/$USER/enroot-tmp/` | Local NVMe | Temp working space for enroot operations. |
| **Job working dir** (`--chdir`) | `/projects/<account>/<user>/<runname>/` | NetApp NFS | Where the user's `sbatch` actually runs and writes its output. Durable, visible across nodes. |
| **Job stdout/stderr** (`--output`/`--error`) | Inside working dir, or `/projects/.../logs/` | NetApp NFS | Persists after job ends, retrievable from any node. |
| **Reference data** (read-only) | `/datasets/` | NetApp NFS, mounted `ro` | Big shared corpora (UKB, reference genomes). Pull from NFS, never modify. |
| **User home** | `/home/$USER/` | NetApp NFS (`fallback_homedir` for new AD users) | Scripts, configs, history. Available on every node. |
| **Spack tree + modulefiles** | `/software/spack/`, `/software/modulefiles/` | NetApp NFS, `ro` after install | Source-built native tools, fleet-wide. |

### The rule

**Pull from NFS, run on /scratch, write back to NFS.**

- Read-mostly inputs and the container library → NFS (`/software`, `/datasets`, `/home`)
- Hot working state during the job → local `/scratch`
- Durable outputs the user wants to keep → NFS (`/projects`)

### Why per-user `/scratch/$USER/` must be created per node

`/scratch` is local NVMe on each node — not shared. Each compute node needs:

```
/scratch/$USER/
├── enroot-data/      # unpacked container rootfs
├── enroot-runtime/   # per-job state
└── enroot-tmp/       # pull/unpack scratch
```

If these don't exist on a node when a job lands there, the container can't unpack and the job hangs in `RUNNING` until cancelled — no useful error in slurmd logs.

Three ways to handle this:

1. **Manual pre-creation** (current state — bootstrapping): `mkdir -p /scratch/$USER/enroot-{data,runtime,tmp}` on each node, owned by `$USER`. Works for a small fleet.
2. **Slurm Prolog script** (recommended once AD is in): `/etc/slurm/prolog.d/10-user-scratch.sh` creates `/scratch/$SLURM_JOB_USER/{enroot-data,enroot-runtime,enroot-tmp}` if missing, before each job starts. Fully automatic.
3. **`pam_mkhomedir`-style approach**: create on first SSH login. Less reliable than Prolog because not every job has a preceding SSH.

The cluster previously had Prolog/Epilog scripts referenced in `slurm.conf` that didn't exist (caused every job to drain the node). They're currently commented out. When AD/SSSD lands, restore them with the per-user scratch logic baked in.

### Current state vs target state

| Mount | Now | Target | Notes |
|---|---|---|---|
| `/software` | ✅ mounted (gpu01, gpu02) | All 4 nodes | Cable swaps pending for cpu01, cgpu01 |
| `/projects` | ❌ not mounted | All 4 nodes, NetApp | Blocked on NetApp volume creation |
| `/datasets` | ❌ not mounted | All 4 nodes, NetApp, `ro` | Blocked on NetApp volume creation |
| `/home` | ❌ local on each node | All 4 nodes, NetApp + AD/SSSD `fallback_homedir` | Blocked on NetApp + AD join |
| `/scratch/$USER/` | manually created on cpu01, gpu01, gpu02 | Auto-created by Slurm Prolog on every node | Bootstrap script for now; Prolog when AD lands |

Until `/projects` is mounted, real workload outputs have to go somewhere awkward (local `/scratch`, ephemeral). Bootstrapping jobs should still use containers + `/software/enroot-cache`, but final results should wait or pin to a known node's `/scratch`.

---

## Workflow examples

**Pull a new image into the shared catalog (one-time, any node):**

```bash
export ENROOT_CACHE_PATH=/software/enroot-cache   # once /software is mounted
enroot import docker://egardner413/mrcepid-burdentesting:latest
```

Resulting `.sqsh` file is visible to all 4 nodes instantly.

**Run a job using a cached image (Slurm-native):**

```bash
srun --partition=cpu --account=research \
     --container-image=docker://egardner413/mrcepid-burdentesting:latest \
     regenie --step 1 --bgen mydata.bgen --pheno phen.txt
```

Pyxis sees the flag, asks Enroot to use the cached image (no re-pull), unpacks to `/scratch/$USER/enroot-data/`, runs `regenie` inside the container, cleans up on exit.

**GPU job (once nvidia-container-toolkit is installed):**

```bash
srun --partition=gpu01 --account=research --gres=gpu:1 \
     --container-image=docker://nvidia/cuda:12.4.0-base-ubuntu22.04 \
     nvidia-smi
```

---

## Fleet rollout pattern

Modeled on `register_gpu_nodes.sh` — a single script run from cpu01 that:

1. Base64-encodes the locally-built `spank_pyxis.so`, `plugstack.conf`, and `enroot.conf`
2. SSHes to each target node as `ntailor`
3. Stages a remote install script that:
   - Downloads + installs Enroot .deb from GitHub releases
   - Drops `spank_pyxis.so` in Slurm's plugin dir
   - Writes `plugstack.conf` and `enroot.conf`
   - Restarts slurmd
4. Verifies Pyxis loaded by grepping `journalctl -u slurmd | grep 'pyxis: version'`
5. Verifies enroot binary callable, slurmd active

Script: [register_pyxis.sh](register_pyxis.sh). Companion smoke tests: [pyxis_smoke.sh](pyxis_smoke.sh) (no Slurm) and [pyxis_slurm_smoke.sh](pyxis_slurm_smoke.sh) (via srun).

**Why this pattern over Ansible:** matches the existing operator workflow on this cluster. One script, one SSH session per node, one sudo prompt per node, no agent or playbook tooling to install. Reuse beats novelty.

---

## Migration path

### Pre-`/software` (now)

- `ENROOT_CACHE_PATH=/scratch/cluster-software/enroot-cache` per node
- Cache is per-node — first user on each node pays the pull cost
- Disk: each .sqsh duplicated 4× across the fleet
- Works without any NetApp dependency

### Post-`/software` (when mounted)

One change on each node:

```bash
sudo sed -i 's|^ENROOT_CACHE_PATH.*|ENROOT_CACHE_PATH       /software/enroot-cache|' /etc/enroot/enroot.conf
sudo mkdir -p /software/enroot-cache && sudo chmod 1777 /software/enroot-cache
rsync -av /scratch/cluster-software/enroot-cache/ /software/enroot-cache/   # one-time
```

No slurmd restart — enroot reads `enroot.conf` at every invocation.

After: pull once per image, all 4 nodes see it. Single source of truth for the container catalog.

### Apptainer retirement

Once Pyxis+Enroot is validated fleet-wide with the burdentesting workload:

- `sudo apt remove apptainer` on all 4 nodes
- `rm /scratch/cluster-software/containers/*.sif`
- Update `Burdentesting_Container_Deployment_Guide.docx` to reference Enroot syntax
- Update any user-facing scripts that referenced `apptainer exec ...`

Until validated end-to-end (including GPU passthrough on gpu nodes), Apptainer stays installed as a fallback. Coexistence has no cost.

---

## Open / dependencies

These items unlock the full design — none are blocking cpu01's current state, but each is needed for fleet rollout:

| Item | Owner | Status | Blocking |
|---|---|---|---|
| Network team to fix optical links (cpu01 secondary, cgpu01 both NICs) | IT/network | In progress | NetApp mounts on cpu01 + cgpu01; cgpu01 cluster fabric reliability |
| NetApp `/software` volume creation + export | Storage team | Pending | Shared image catalog, Spack tree |
| Pyxis+Enroot rollout to gpu01, gpu02, cgpu01 | Us | Script ready | Fleet validation, GPU smoke tests |
| `nvidia-container-toolkit` install on GPU nodes | Us | Not started | GPU passthrough inside containers |
| AD/SSSD join across fleet | Us | Pending | Per-user namespace (needs UID resolution) |
| `/etc/idmapd.conf` umich_ldap | Us | Pending | NFSv4 ID mapping consistency |
| Slurm partition + QoS rewrite | Awaiting David sign-off + AD group name | Pending | Final partition layout |

---

## What we explicitly chose against

- **Plain Docker Engine** — daemon-based, requires root or docker-group membership, no Slurm integration, terrible HPC fit.
- **Podman in place of Pyxis** — Docker-CLI compatible but no Slurm integration; users would still hand-roll wrapper scripts.
- **Slurm OCI / scrun** — too new, complex setup, sharp performance edges per NVIDIA's documentation.
- **Charliecloud / Sarus** — niche, less momentum than Pyxis+Enroot.
- **Keeping Apptainer as primary** — design moved away from it; coexistence during transition only.
- **Per-node Spack installs** — would defeat the point of having NetApp. Single shared tree.
- **Putting `ENROOT_DATA_PATH` on NFS** — would serialize container startup across the cluster behind NFS contention.

---

## Cross-reference

- Install how-to: [PyxisEnroot-Setup.md](PyxisEnroot-Setup.md)
- Session log: [Progress.md](Progress.md)
- Apptainer setup notes (legacy): [Apptainer](Apptainer)
- Existing Slurm reg script (template): [register_gpu_nodes.sh](register_gpu_nodes.sh)
- New rollout script: [register_pyxis.sh](register_pyxis.sh)
- Smoke tests: [pyxis_smoke.sh](pyxis_smoke.sh), [pyxis_slurm_smoke.sh](pyxis_slurm_smoke.sh)
- Prior session summary: [Summary](Summary)
