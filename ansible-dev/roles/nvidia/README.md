# nvidia role

Manages the NVIDIA driver, CUDA toolkit, and NVIDIA Container Toolkit
on the 3 GPU nodes (`insiiukgpu01`, `insiiukgpu02`, `insiiukcgpu01`).
Includes a full fresh-node install path and ongoing lockdown to prevent
unattended-upgrades from desyncing the kernel module and userspace libs.

## File layout

```
roles/nvidia/
├── defaults/main.yml         versions, held package list, install vars
├── files/
│   ├── 51-nvidia-blacklist     unattended-upgrades blacklist (live identical)
│   ├── blacklist-nouveau.conf  modprobe nouveau blacklist
│   └── cuda.sh                 /etc/profile.d wrapper (PATH/LD_LIBRARY_PATH/CUDA_HOME)
├── handlers/main.yml         update-initramfs (notified by nouveau blacklist)
└── tasks/
    ├── main.yml              entry — imports tagged sub-files
    ├── install.yml           ⚠️ fresh-node bootstrap (--tags install only)
    ├── lockdown.yml          apt-mark hold + unattended-upgrades blacklist
    ├── runtime.yml           nvidia-persistenced active
    └── validate.yml          driver version assertion
```

## Tags

| Tag | What runs | Reboots? |
|---|---|---|
| `(default)` | lockdown + runtime + validate | No |
| `install` | full fresh-node bootstrap (5 phases, 22 tasks) | Up to 3 conditional reboots |
| `lockdown` | apt-mark hold + blacklist file only | No |
| `runtime` | nvidia-persistenced started | No |
| `validate` | driver version assert | No |

**`install` is opt-in via `--tags install`** thanks to a `[install, never]`
tag combination. Without that explicit tag, default playbook runs skip
install.yml entirely — no risk of accidental reboots on a healthy node.

## Current state on every GPU node (codified)

| Item | Value |
|---|---|
| Driver | `580.159.03` (headless `nvidia-driver-580-server`) |
| CUDA toolkit | `cuda-toolkit-12-6` (12.6.3-1) |
| NVIDIA Container Toolkit | `nvidia-container-toolkit` (held with the rest) |
| Held packages | 21 (driver + CUDA libs + container toolkit) |
| Blacklist file | `/etc/apt/apt.conf.d/51-nvidia-blacklist` blocks `nvidia-`, `libnvidia-`, `cuda-`, `nsight-`, `datacenter-gpu-manager`, `nvidia-container` globs in unattended-upgrades |
| Persistence | `nvidia-persistenced` static-active (keeps driver loaded between jobs) |
| Per-GPU type | gpu01/gpu02 → H200 NVL, cgpu01 → L4 |

## Install flow (`--tags install`)

Five phases, each idempotent. Each reboot is **conditional on the prior
task changing state** — so re-running on a fully-installed node is a
no-op (no reboots).

```
Phase 1 — apt cache refresh + upgrade
            (reboot only if kernel was bumped)

Phase 2 — install build-essential, dkms, linux-headers-<running-kernel>
          drop /etc/modprobe.d/blacklist-nouveau.conf
          update-initramfs -u
            (reboot only if nouveau blacklist changed — fully unloads nouveau)
          verify lsmod shows no nouveau

Phase 3 — download cuda-keyring deb
          install keyring (adds NVIDIA CUDA apt repo)
          apt update
          install nvidia-driver-580-server
            (reboot only if driver was installed — loads new kernel module)
          verify nvidia-smi works

Phase 4 — install cuda-toolkit-12-6
          drop /etc/profile.d/cuda.sh (PATH / LD_LIBRARY_PATH / CUDA_HOME)

Phase 5 — install NVIDIA Container Toolkit
          (keyring + apt repo + nvidia-container-toolkit package)
```

After install completes, the default `lockdown` + `runtime` + `validate`
tasks lock things in (apt-mark hold, unattended-upgrades blacklist,
persistence service, driver version assertion).

## Common invocations

```bash
# Default — lockdown + runtime + validate (idempotent, no reboots)
ansible-playbook playbooks/nvidia.yml

# Fresh-node bootstrap (with conditional reboots)
ansible-playbook playbooks/nvidia.yml --tags install

# Full from-scratch bootstrap on a fresh node
ansible-playbook playbooks/nvidia.yml --tags install,nvidia

# Just verify the driver version on running nodes
ansible-playbook playbooks/nvidia.yml --tags validate
```

## Driver upgrade runbook

The lockdown is meant to be **deliberate** — driver updates require
unholding, upgrading, rebooting, re-holding.

```bash
# 1. Drain the cluster (or schedule a maintenance window)
sudo scontrol update nodename=insiiukgpu01,insiiukgpu02,insiiukcgpu01 state=drain reason='nvidia upgrade'

# 2. Unhold the packages on the GPU nodes
ansible gpu_nodes -m shell -a "
  for pkg in {{ nvidia_held_packages | join(' ') }}; do
    sudo apt-mark unhold \$pkg
  done
"

# 3. Bump the version in roles/nvidia/defaults/main.yml:
#      nvidia_expected_driver_version: "<new-version>"
#    Replace any "-580-server" suffixed package names with the new branch
#    (e.g., "-590-server").

# 4. apt upgrade
ansible gpu_nodes -m apt -a "name=<new-driver-pkg> state=present"

# 5. Reboot each GPU node (one at a time, verify nvidia-smi after each)
ansible insiiukgpu01 -m reboot -a "msg='nvidia upgrade'"
# ... wait, verify, repeat ...

# 6. Re-apply lockdown to re-hold at the new version
ansible-playbook playbooks/nvidia.yml --tags lockdown

# 7. Resume nodes
sudo scontrol update nodename=insiiukgpu01,insiiukgpu02,insiiukcgpu01 state=resume
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `nvidia-smi: No devices were found` | Driver/kernel module mismatch (kernel updated without driver re-build) | Reboot, or re-run `--tags install` (DKMS rebuilds the module) |
| `apt upgrade` wants to install a new driver | `apt-mark hold` not in place | Re-run `--tags lockdown` |
| Job dies with `CUDA error: no CUDA-capable device is detected` inside a container | Pyxis GPU passthrough chain broken | Verify `slurmd -G` on the node, check `CfgTRES` has `gres/gpu`, see `pyxis_gpu_smoke.sh` |
| Driver version on validate doesn't match expected | Manual driver upgrade happened outside this role | Re-pin `nvidia_expected_driver_version` in `defaults/main.yml` OR revert the manual upgrade |
| `nvidia-persistenced` not active | Service masked or driver install incomplete | `--tags runtime` to (re-)start it |

## Cross-references

- **NVIDIA install source script:** [run-dir/nvidiainstall.sh](../../../run-dir/nvidiainstall.sh) — the manual install steps this role codifies
- **GPU passthrough smoke:** [run-dir/pyxis_gpu_smoke.sh](../../../run-dir/pyxis_gpu_smoke.sh)
- **Related roles:** `pyxis-enroot` (container runtime), `slurm` (GRES scheduling)
- **TODO backlog:** [/home/ntailor/ansible-dev/TODO.md](../../TODO.md)
