# Cluster Build Progress — Session 3 (2026-05-21)

Running log for this session. Append as we go.

## What got done today

### Validation
- Re-ran [burden_without_slurm_smoke.sh](burden_without_slurm_smoke.sh) on cpu01 — 20/20 PASS
- Re-ran [burden_with_slurm_smoke.sh](burden_with_slurm_smoke.sh) on cpu01 — full Slurm+container chain PASS (job 7, 1s elapsed)

### Network / fabric diagnosis (the big thing)
PHY-level health check via `nick_check.sh` (`ethtool -S` filtered on `phy|crc|symbol`).

| Node | Primary `f0np0` | Secondary `f1np1` |
|---|---|---|
| cpu01  (.55/.60) | Clean — 1,419 errors / 4.5M pkts | **Broken** — 4.6B+ errors, RX power low alarm |
| cgpu01 (.56/.61) | **Catastrophic** — 142B errors / 1.8M pkts | **Broken** — 18M errors |
| gpu01  (.57/.62) | Clean | Clean |
| gpu02  (.58/.63) | Clean | Clean |

**Root cause: optical / physical layer.** Confirmed not netplan / not BIOS / not driver — the SFP's own RX-power sensor is reporting `low alarm` (below -13.9 dBm threshold) on the bad cpu01 link, and the PCS lane symbol errors all climb together across all 4 lanes. Software cannot cause these.

**Mitigations attempted on cpu01 secondary:**
- Reseated SFP — alarm cleared briefly, warning persisted, errors still climbed
- Swapped SFP (new SN `ACW24471FXH`) — link came down completely, no carrier
- Swapped cable — still no carrier, RX alarm back on
- Reboot to kernel 6.8.0-117 — no change (kernel can't fix optics)
- Conclusion: far-end SFP / switch port is the remaining suspect on cpu01's link

**Handed to network team:** 3 broken links, gpu01/gpu02 as known-good baseline, per-port PHY counters as evidence. Awaiting their investigation.

### Side wins
- Kernel upgrade picked up on cpu01 (6.8.0-111 → 6.8.0-117) after reboot
- `nfs-common` installed on cpu01 — `/sbin/mount.nfs` (nfs-utils 2.6.4) in place
- NOPASSWD sudoers drop-in created at `/etc/sudoers.d/ntailor-apt` (ntailor can drive `apt`/`apt-get`/`dpkg` non-interactively)
- Policy routing rules on cpu01 for NetApp (`to 10.174.16.28 lookup 101`, etc.) were lost in reboot — not persisted

### NFS mounts on gpu01 (validated healthy node)
- `/mnt/compchem` — mounted with `vers=4.2, proto=tcp, rsize=wsize=1MB, hard, nconnect=16, noatime`
- Mounting three more: `/humgen`, `/humgen_protected`, `/informatics` (in progress — checking pre-existing contents)

## Current state of the world

- **NetApp service:** ✅ alive and reachable on 10.174.16.28
- **gpu01 + gpu02:** ✅ both NICs clean, NetApp mounts work
- **cpu01 cluster fabric (primary):** ✅ functional
- **cpu01 NetApp fabric (secondary):** ❌ no carrier after swaps — waiting on network team to inspect far end
- **cgpu01 both NICs:** ❌ both broken; primary "works" only via TCP retransmits
- **Cluster (Slurm + container chain):** ✅ working end-to-end on cpu01

### Slurm accounting
- Renamed account `cheminformatics` → `compchem` (matches NetApp volume name). Clean rename — account had no users, no default-account assignments, no historical jobs. Method: `sacctmgr add account compchem parent=research` then `remove account cheminformatics`. Slurm 23.11.4 doesn't support direct `set Name=` on accounts.
- Renamed account `statistical_genetics` → `human_genetics` (2026-05-26). Same clean rename — no users, no jobs. Final research-family tree: `bioinformatics`, `compchem`, `human_genetics`. Updated `Approach.md` container catalog tree to match.

### Container runtime direction change
- Stakeholder direction: drop Apptainer, adopt **Pyxis + Enroot** (NVIDIA's HPC stack — SPANK plugin + unprivileged container runtime that consumes Docker images natively).
- Pre-reqs installed on cpu01: `build-essential`, `pkg-config`, `libslurm-dev` (23.11.4), `curl`, `jq`, `squashfs-tools`, `parallel`, `zstd`. Slurm headers verified.
- Slurm plugin dir confirmed: `/usr/lib/x86_64-linux-gnu/slurm-wlm/`. Userns enabled (`kernel.unprivileged_userns_clone = 1`).
- Full step-by-step install + rollout doc written: [PyxisEnroot-Setup.md](PyxisEnroot-Setup.md)
- **cpu01 fully installed and validated.** Enroot 3.5.0 + Pyxis v0.20.0 built against Slurm 23.11.4 headers.
- **Both new smoke tests pass on cpu01:**
  - [pyxis_smoke.sh](pyxis_smoke.sh) — 8/8: enroot binary, userns, config, import, create, start, exec inside container, cleanup
  - [pyxis_slurm_smoke.sh](pyxis_slurm_smoke.sh) — job 12 COMPLETED, ExitCode 0:0, 225 lines of REGENIE 3.4.1 output from inside the burdentesting container, dispatched via `sbatch --container-image=docker://egardner413/mrcepid-burdentesting:latest`. First-run 218s dominated by 2.3 GB docker pull; subsequent runs cached.
- Build artifact at `/opt/build/pyxis/spank_pyxis.so` (60 KB) — ready to scp to gpu01, gpu02, cgpu01.
- Burdentesting image now cached at `/scratch/cluster-software/enroot-cache/` on cpu01.
- Rollout script written: [register_pyxis.sh](register_pyxis.sh) — separate file, models on register_gpu_nodes.sh pattern, not yet executed.
- Cache architecture decision: `ENROOT_CACHE_PATH` on `/software` (NetApp) once mounted — shared image catalog. `ENROOT_DATA_PATH`, `ENROOT_RUNTIME_PATH`, `ENROOT_TEMP_PATH` stay on local `/scratch` per node (high-IOPS during job execution, would saturate NFS otherwise).
- Migration when /software lands: one-line `sed` on enroot.conf to swap `ENROOT_CACHE_PATH`, plus `rsync` of existing cache. No slurmd restart needed.

### NetApp `/software` mounted (2026-05-22)
- Volume created (2 TB) and exported from `10.174.16.28:/software` + `10.174.16.29:/software` (HA pair).
- **gpu01 and gpu02 mounted via secondary NIC** (policy routing intact post-reboot — traffic via `ens4059f1np1`, NetApp dedicated fabric). 2.0 TB, 1.9 TB free.
- fstab entries added on both — survives reboot.
- cpu01 still blocked (its secondary NIC still NO-CARRIER, awaiting network team final fix).
- cgpu01 not yet mounted — its secondary still showing 8,776 residual CRC errors after rework; need stability check before mounting.
- Ownership shows `nobody:nogroup` — normal pre-AD; resolves once idmapd/SSSD are in place.

### SSH key distribution
- ntailor's `~/.ssh/id_ed25519.pub` distributed to gpu01, gpu02, cgpu01 via sshpass (one-time bootstrap with temp password `test123`, scheduled for rotation).
- cpu01 → all-nodes pubkey auth working (caller needs ssh-agent loaded since key is passphrase-protected).
- Known_hosts pre-populated on cpu01 (40 entries — hostname + IP × multiple key types).
- `sshpass` installed on cpu01 — remove after temp password rotation.

### Network fabric — partial recovery
- Network team identified root cause as **wrong cable type** (OM1/OM2 instead of OM3/OM4 for 10G-SR 850nm).
- **cgpu01 primary fully recovered** — was 142B CRC errors yesterday, now 0.
- **cgpu01 secondary** still showing 8,776 errors but post-reboot fresh state; watch for stability.
- **cpu01 secondary** still NO-CARRIER — pending further work.
- gpu01 + gpu02: both NICs clean.

### 2026-05-26 — cpu01 + cgpu01 secondaries restored (still marginal)
- Both secondary NICs now `LOWER_UP` after network team's work.
- `/software` mounted on **all 4 nodes** via dedicated secondary NICs:
  - cpu01 via 10.174.16.60
  - gpu01 via 10.174.16.62
  - gpu02 via 10.174.16.63
  - cgpu01 via 10.174.16.61
- All see same shared enroot-cache (3.2 GB) via NFS.
- fstab updated on all 4 — persists across reboots.
- **Still flagging to network team**: cpu01 secondary at ~3% CRC error rate, cgpu01 similar. Links work via TCP retransmits but throughput will suffer under bulk NFS load. Not done yet.
- `nfs-common` installed on cgpu01 (was missing).

### Workload volumes mounted fleet-wide (2026-05-26)
- 4 additional NetApp exports mounted at `/mnt/<vol>` on all 4 nodes:
  - `/mnt/compchem` (2.1 TB)
  - `/mnt/humgen` (2.1 TB)
  - `/mnt/humgen_protected` (8.1 TB)
  - `/mnt/informatics` (8.1 TB)
- All via dedicated secondary NIC (policy routing intact post-network-fix).
- fstab entries on every node — persist across reboots.
- Total NetApp visibility: ~22.4 TB per node.
- Still pending NetApp exports: `/projects`, `/datasets`, `/home`, `/archive` (volumes not yet created on NetApp side).

### 2026-05-27 — AD joined + GPU node recovery + driver hold
- **AD/SSSD join complete** (reported by ops). Still waiting on the new NetApp mount points and the OM3/OM4 cable swaps for cpu01/cgpu01 secondaries.
- **GPU nodes went `inval` after running `slurm_apply_l1_reconfigure.sh`.** The reconfigure forced slurmd to re-validate gres; surfaced two latent problems:
  1. **NVIDIA driver/library mismatch** on gpu01 + gpu02 — userspace libs at 580.159 but stale kernel module loaded. `nvidia-smi` failed with "Driver/library version mismatch." Pending-reboot flag was set. Needed reboot.
  2. **Missing `/etc/slurm/gres.conf` on all 3 GPU nodes** — the real long-standing cause. Even cgpu01 (whose nvidia-smi worked) reported 0 GPUs because slurmd had no device mapping. Reason timestamp showed this started 2026-05-26.
- **Fix:**
  - Created `gres.conf` on all 3 GPU nodes — explicit mapping `Name=gpu Type=<l4|h200_nvl> File=/dev/nvidia0` (avoids NVML autodetect type-mismatch risk).
  - cgpu01: gres.conf + slurmd restart → went IDLE immediately (driver was already fine). Validated the approach before touching the others.
  - gpu01 + gpu02: `apt upgrade` + reboot synced the driver; gres.conf already staged → came back with `nvidia-smi` working, `/software` remounted (policy routing survived reboot), GPUs detected. Resumed from drain → IDLE.
- **NVIDIA packages protected against accidental updates — two layers:**
  - Layer 1: `apt-mark hold` on driver, dkms, kernel modules, CUDA tools, container toolkit (~21 pkgs/node). Blocks manual `apt upgrade`.
  - Layer 2: unattended-upgrades blacklist at `/etc/apt/apt.conf.d/51-nvidia-blacklist` (patterns: `nvidia-`, `libnvidia-`, `cuda-`, `nsight-`, `datacenter-gpu-manager`, `nvidia-container`). Blocks the automatic overnight updater — the main "accidental" vector that would silently desync the driver and drain the GPU nodes.
  - Deliberate driver update procedure: `apt-mark unhold` → `apt upgrade` → reboot → verify `nvidia-smi` → re-`apt-mark hold`.
- **Three Slurm config-apply scripts created** in run-dir, mirroring the register pattern (run from cpu01, hash-verify push, sinfo at end):
  - `slurm_apply_l1_reconfigure.sh` — push + `scontrol reconfigure` (wall times, AllowAccounts, QoS, priority, pre-emption)
  - `slurm_apply_l2_slurmd.sh` — push + slurmd restart fleet-wide + reconfigure (cgroup, plugin paths, GresTypes)
  - `slurm_apply_l3_full.sh` — push + slurmd restart + slurmctld restart (AccountingStorage, AuthType, ClusterName, node add/remove)
- **Fleet final state:** all 4 nodes IDLE; gpu:l4:1 on cgpu01, gpu:h200_nvl:1 on gpu01/gpu02, cpu01 GPU-less. `/software` mounted on all 4.
- **cpu01 reboot** deferred to ops (can't reboot the controller from its own session; no driver issue there anyway — just pending package/kernel updates).

## Open / next up

- [ ] cpu01 reboot (ops — pending kernel/package updates; no driver mismatch)
- [ ] Network team to inspect far-end SFPs / switch ports for cpu01 secondary, cgpu01 primary, cgpu01 secondary
- [ ] Persist policy routing rules (so they survive reboot — netplan or systemd-networkd)
- [ ] Once secondary links healthy: add `/etc/fstab` entries on all 4 nodes for NetApp mounts
- [ ] Mirror gpu01's NFS mounts to gpu02 (also healthy)
- [ ] Mount + content audit of `/humgen`, `/humgen_protected`, `/informatics`
- [ ] AD/SSSD join across fleet (punch-list item, pre-existing)
- [ ] `/etc/idmapd.conf` umich_ldap config (punch-list item)
- [ ] Slurm config rewrite (partitions + QoS + AllowGroups) — held until David sign-off + AD group name from IT

## Notes / gotchas learned

- **Don't blow on fiber connectors** — moisture/saliva degrades RX power. Use a one-click cleaner or 99% IPA + lint-free wipe.
- **`ip link set up` doesn't create photons** — physical-layer failures can't be fixed in software.
- **TCP retransmits can hide PHY corruption** for low-bandwidth traffic (SSH, slurm heartbeats), but the link will collapse under real load. cgpu01 primary is in this state right now.
- **Netplan / netplan-style configs operate at L3** — they can't cause RX power alarms or PCS symbol errors. Same for BIOS.
- **Asymmetry is diagnostic** — if a config theory were right, all four boxes would behave the same. They didn't, so it's hardware.
- **GPU detection needs `gres.conf`** — a `Gres=gpu:...` line in slurm.conf alone isn't enough. slurmd needs `/etc/slurm/gres.conf` with a device mapping (or `AutoDetect=nvml`) or it reports 0 GPUs and the node auto-drains, even when `nvidia-smi` works.
- **Hold the NVIDIA driver** (`apt-mark hold`) on GPU nodes. An unattended `apt upgrade` bumps the userspace libs but not the loaded kernel module → "Driver/library version mismatch" until reboot. Holding makes driver updates a deliberate, planned action.
- **`scontrol reconfigure` re-validates gres** — it forces slurmd to re-check GPU detection, which can surface latent gres.conf problems that were masked since the last slurmd start. Not a bug, just a thing to know: a config push can expose a pre-existing GPU issue.

