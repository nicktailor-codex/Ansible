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

### 2026-05-31 — Ansible codification (everything ad-hoc is now a role)
Everything done by hand-rolled scripts in `run-dir/` has been re-implemented as idempotent Ansible roles under `~/ansible-dev/`. Initial commit `54bc3e6` covers 8 roles; same-day follow-ups add `monitoring` and finish `slurm` accounting/secrets/install. Repo currently at 9 roles, all `changed=0` on re-run.

- **`base`** — NOPASSWD sudoers drop-in, HPC sysctls (`vm.swappiness=10`, `net.core.somaxconn=4096`, `fs.file-max=2M`, etc.), policy-routing for NetApp (table 100 default, table 101 for `10.174.16.28/29`). Replaces the manual rules that kept getting lost on reboot.
- **`storage`** — NetApp NFSv4.2 mounts (`/software`, `/mnt/compchem`, `/mnt/humgen`, `/mnt/humgen_protected`, `/mnt/informatics`) with `vers=4.2,proto=tcp,rsize=wsize=1M,hard,nconnect=16,noatime`. fstab-managed; survives reboot. NFS-and-ACL items closed.
- **`nvidia`** — driver install path tag-gated `[install, never]` (3 conditional reboots); apt-mark hold + unattended-upgrades blacklist already in place. Deliberate upgrade path is unhold → apt upgrade → reboot → verify → re-hold.
- **`slurm`** — full config codified. `slurm.conf` (5 partitions then; 6 now — see 2026-06-01), `cgroup.conf`, `gres.conf`, prolog (`20-enroot-scratch.sh`), `EnforcePartLimits=ALL`, accounting tree (`research` parent → `bioinformatics` / `compchem` / `human_genetics`; later renamed `informatics`), QoSes (`normal` 5d default, `debug` priority=500 60min). Vault-managed munge key + `slurmdbd.conf`. `daemons.yml` masks `slurmctld` on compute and resets failed state. Tasks split: `install.yml`, `config.yml`, `accounting.yml`, `secrets.yml`, `daemons.yml`, `prolog.yml`, `validate.yml`.
- **`pyxis-enroot`** — Enroot 3.5.0 + Pyxis v0.20.0 built against Slurm 23.11.4 headers; SPANK plugin + `/etc/slurm/plugstack.conf`; shared `ENROOT_CACHE_PATH` on NetApp `/software/enroot-cache` (saves ~6.9 GB/node on burdentesting image); data/runtime/tmp stay local on `/scratch`.
- **`networking`** — policy routing made persistent via systemd-networkd drop-ins. Closes the "rules lost on reboot" footgun.
- **`mail`** — exim4 smarthost to EOP (`insmedinc.mail.protection.outlook.com:25`) with per-node sender (`cpu`/`cgpu`/`gpu01`/`gpu02` @ insmed.com). Slurm `MailProg=/etc/slurm/slurm-mail.sh` wraps bsd-mailx, qualifies bare `--mail-user=ntailor` with `@insmed.com`.
- **`raid`** — verify + diagnostic repair only. Never runs `mdadm --create`. `--tags repair` is opt-in.
- **`monitoring`** — `slurmrestd` + slurm-web (see below).
- **Vault setup:** password at `~/.ansible-vault-pass` (mode 0600). Key `Xbv8EC+edQ84lh/0/Q+GsGyunTCp1s0k6AOfnsAx7S0=`. **No recovery if lost — back this up offsite.**

### 2026-05-31 — Monitoring v1 (slurm-web v4 on Slurm 23.11)
Spent a chunk of the day fighting slurm-web compatibility. Source-install attempted at v6.1.0 and v5.2.0 — both blew up on Slurm 24.x schema requirements and Python dep chains (RacksDB → pycairo → PyGObject ≥3.50 → girepository-2.0 not in Ubuntu). Pivoted to rackslab's apt repo (`pkgs.rackslab.io/deb ubuntu24.04`) once we realized they ship version-pinned `slurmweb-3/4/5/6` components.

- **slurm-web v4 is the only component that talks Slurm 23.11's slurmrestd 0.0.39 cleanly.** v5/v6 expect 0.0.41+ (Slurm 24.x).
- **/stats one-line bug:** v4 reads `meta["slurm"]` from the ping response; 0.0.39 returns `meta["Slurm"]` (capital S — renamed to lowercase in 0.0.41+). Ansible task patches `version()` in `/usr/lib/python3/dist-packages/slurmweb/slurmrestd/__init__.py` to fall back; idempotent, re-applies after apt upgrade.
- **slurmrestd auth=local** required the agent to share the slurm user's UID — systemd drop-in runs `slurm-web-agent` as `slurm` (not `slurm-web`); slurm-web user added to the `slurm` group.
- **policy.ini** grants anonymous role full read (auth is off for dev). To be tightened before user-facing rollout.
- **Result:** all 7 endpoints (jobs / nodes / partitions / qos / accounts / reservations / stats) → HTTP 200 at `http://10.174.16.55:5011/`. UI renders real cluster data. Role idempotent.

### 2026-06-01 — cpu-overflow partition + cluster-status CLI
Realized the 192 CPU cores across gpu01/gpu02/cgpu01 were stranded — the `cpu` partition only saw cpu01, so CPU-only jobs never reached the GPU nodes' cores.

- **New `cpu-overflow` partition** spans all 4 nodes (320 cores in scope). `MaxCPUsPerNode=48` reserves 16 cores/node for host-side cores alongside GPU jobs. `MaxTime=1d`, `PriorityTier=1` (lower than GPU partitions). Verified live: a job submitted to `cpu-overflow` lands on whichever node has free cores.
- **GPU partitions bumped to `PriorityTier=5`** so a GPU job wins the scheduling race when both fit on the same node. No preemption (`PreemptMode=OFF`) — running jobs are never killed.
- **`cluster-status` CLI helper** deployed to `/usr/local/bin/` on all 4 nodes. One-shot snapshot of free cores / mem / GPU per node + per-partition `a/i/o/t` view + queue depth. No slurm-web round-trip needed.

### 2026-06-01 — Pyxis container memory floor dropped 8G → 3G (pre-existing config bug fixed)
Started by attempting a burdentesting smoke audit; every `sbatch --container-image=` job died with `ExitCode 0:53, Elapsed 00:00:01` while `srun` with the same image worked. Initially blamed NFS bind-mounts and script-file mode — both wrong.

- **Real cause: silent OOM during pyxis SquashFS build in stepd setup.** The OOM-kill happens before the user's command starts, so sacct's Elapsed timer shows 1s even though the kill happened minutes into the build. Made every failure look like an instant launch error.
- **Discovered pre-existing config-name typo:** `roles/pyxis-enroot/files/enroot.conf` had `ENROOT_SQUASH_OPTS` but enroot's scripts read `ENROOT_SQUASH_OPTIONS` (full word). Our `-comp lzo -noI -noD -noF -noX` line had been a **no-op since day one** — enroot was falling back to its built-in default (gzip), the most memory-hungry option.
- **Fix:** rename variable to `ENROOT_SQUASH_OPTIONS` and switch options to `-noI -noD -noF -noX -no-fragments` (uncompressed squashfs + skip fragment dedup).
- **Results:**
  - Memory floor: **8 GB → 3 GB safe minimum** (2 GB worked but with no headroom; MaxRSS peaks at ~2.08 GB during build)
  - First-container-start time: ~60 s LZO build → ~20 s direct pack
  - Tradeoff: per-user squashfs files ~3× larger (~2.3 GB for burdentesting vs gzip ~700 MB) — irrelevant given 7 TB local scratch
- **Docs updated** in `Slurm-Cheatsheet.md` to reflect new floor.

### 2026-06-01 — Spack + Lmod: native module system mirroring the burdentesting Docker stack
Pyxis containers stay the right path for heavy reproducible workloads, but users wanted to swap individual tool versions (e.g. plink 1.9 vs 2.0, regenie 3.4 vs 3.5) without rebuilding the whole 2.3 GB Docker image. Built out Spack + Lmod as the lightweight complement: each tool installed natively, side-by-side versions selectable with `module load <tool>/<version>`.

**Infrastructure (`spack-lmod` role):**
- Lmod 8.6.19 (apt) on all 4 nodes; provides `module load/avail/list`
- Spack v0.23.1 cloned to `/software/spack` (NetApp-shared → build once on cpu01, every node sees binaries + modules immediately via NFS)
- Site-scoped `repos.yaml` registers our custom overlay so it survives Spack version bumps
- `/etc/profile.d/spack.sh` on every node — wires `MODULEPATH` to Spack's module tree
- `spack-build-burden` helper on cpu01 kicks off the multi-hour build in a detached tmux session (`tmux attach -t spack-build` to watch, Ctrl-b d to detach — survives SSH disconnects)

**Burden environment (`/software/spack/var/spack/environments/burden/spack.yaml`):**
Audited the burdentesting Docker image to get exact versions. Spack ↔ image alignment:

| Tool | Image | Spack | How |
|---|---|---|---|
| regenie | 3.4.1 | 3.4.1 | Custom package in `insmed` overlay — installs the upstream static gz binary |
| plink2 | 2.00a5.11 | 2.00a5.11 | Builtin, exact |
| htslib | 1.20 | 1.20 | Builtin, exact |
| r | 4.3.3 | 4.3.3 | Builtin, exact |
| samtools | 1.20 | 1.20 | `insmed` overlay — backport (subclass of builtin) |
| bcftools | 1.20 | 1.20 | `insmed` overlay — backport |
| gcta | 1.94.4 | 1.94.1 | `insmed` overlay — image's 1.94.4 only published on Yang Lab CN host (blocked from cpu01); GitHub has up to 1.94.1 |
| plink | 1.90b7.2 | 1.9-beta6.27 | Functionally identical (plink 1.9 has been perpetual-beta for ~10 years) |
| python | 3.8.10 | 3.11.9 | 3.8 EOL'd from Spack; users running burdentesting via container still get 3.8 |

129 packages total (10 root specs + transitive deps). Build wall-time ~2 hr on cpu01's 128 cores. Output cached on NetApp — repeat builds nearly instant.

**Two real bugs hit + fixed during the build:**
- **Backport subclasses don't inherit version-qualified `depends_on`.** Our initial samtools/bcftools 1.20 packages just added a `version()` line. Upstream binds htslib to bcftools via `depends_on("htslib", when="@1.19:1.19.X")` — our 1.20 fell outside the `when=` so concretization skipped htslib → `KeyError: 'No spec with name htslib'` at configure_args. Fix: explicit `depends_on("htslib@1.20", when="@1.20")` in the backport.
- **Lmod module-name clashes** between duplicate transitive deps (two curl variants, two zstd variants concretized with different build options). Aborted the initial `spack module lmod refresh`. Fix: `hide_implicits: true` in modules.yaml so transitive deps stop competing for the same `curl/8.10.1.lua` filename. Users only see the 10 root tools in `module avail` anyway; deps still autoload behind the scenes via `autoload: direct`.

**End-to-end Slurm validation (job 91):**
- Submitted to `gpu01` (real compute node, not the controller)
- `module load regenie plink2 bcftools r` worked
- All 5 binaries resolved to `/software/spack/opt/spack/<pkg>-<hash>/bin/` via NetApp
- 62 transitive dep modules autoloaded automatically
- Versions confirmed: regenie 3.4.1, plink2 2.00a5.11 AVX2, bcftools 1.20, R 4.3.3
- Total elapsed: 3 seconds

**One real gotcha for users:** Slurm batch shells are non-login by default, so `/etc/profile.d/lmod.sh` isn't sourced → `module: command not found`. Fix: start the batch script with `#!/bin/bash -l` (login shell) or explicitly `source /etc/profile.d/lmod.sh`. Documented in [Spack-Lmod-Guide.md](Spack-Lmod-Guide.md) and added to Slurm-Cheatsheet.md gotchas.

**Adding a new version is now ~5 minutes of admin time:**
```bash
sudo -i; source /software/spack/share/spack/setup-env.sh
spack env activate burden
# edit /software/spack/var/spack/environments/burden/spack.yaml — add line: - regenie@3.5.0
spack concretize -f && spack install && spack module lmod refresh --delete-tree -y
# users immediately see both regenie/3.4.1 and regenie/3.5.0 in module avail
```

**Docs written:** [Spack-Lmod-Guide.md](Spack-Lmod-Guide.md) — full user + admin guide with the sbatch template, module commands quick reference, troubleshooting, layer-cake of how `module load` resolves to the NetApp share.

## Open / next up

**External / waiting on others**
- [ ] Network team — cpu01 secondary and cgpu01 both at ~3% CRC error rate; links work via TCP retransmits but throughput will suffer under bulk NFS load
- [ ] cpu01 reboot (ops) — pending kernel/package updates
- [ ] NetApp exports still pending: `/projects`, `/datasets`, `/home`, `/archive`
- [ ] Team AD groups (`compchem`, `human_genetics`, `bioinformatics`) — pending IT
- [ ] AD/SSSD complete; `/etc/idmapd.conf` umich_ldap config remaining

**Ansible work**
- [ ] `nvidia` install.yml real-world test on a fresh GPU node (only code-reviewed so far)
- [ ] `slurm` install.yml fresh-node bootstrap — same (untested in anger)
- [ ] Submit-time enforcement for explicit non-default QoS — Slurm 23.11 only rejects at job-start, not at submit. Needs a `job_submit/lua` script.
- [ ] Sudoers NOPASSWD cleanup for ntailor (currently broad `apt` grant)

**Monitoring → prod-ready** (deferred until rest of cluster is done)
- [ ] Lock down slurm-web auth (LDAP or JWT — currently anonymous)
- [ ] Apache reverse proxy + TLS cert in front of slurm-web
- [ ] AD-integrated auth via Apache (mod_auth_kerb or Okta forward-auth)
- [ ] Internal DNS entry for slurm-web (IT ticket)

**Repo hygiene**
- [ ] Push `ansible-dev/` to a remote (currently local-only)
- [ ] Offsite backup of `~/.ansible-vault-pass` — no recovery if lost
- [ ] CI hook so role changes are `--check`'d against the cluster before merge

### 2026-06-02 — slurmctld auto-restart (workaround for assoc_mgr deadlock in 23.11.x)
Hit a `fatal: assoc_mgr_lock: pthread_rwlock_rdlock(): Resource deadlock avoided` during a spack smoke test submit. Known race in Slurm 23.11.0–23.11.5 between the backfill scheduler and association cache updates — fixed upstream in 23.11.6+ and gone in 24.05+. We're on Ubuntu's 23.11.4.

- **Manual recovery:** `sudo systemctl restart slurmctld` — slurmctld checkpoints state every ~30s, so restart recovers all in-flight jobs cleanly. Running jobs are **unaffected during the outage** — slurmd on each compute node manages them independently of slurmctld. Only new submissions / scheduling decisions / squeue / scancel block during the gap.
- **Cheap insurance:** systemd drop-in at `/etc/systemd/system/slurmctld.service.d/restart.conf` (codified in `roles/slurm/files/slurmctld.service.d-restart.conf`, deployed by the `daemons` task):
  ```
  [Service]
  Restart=on-failure
  RestartSec=5s
  StartLimitBurst=10
  StartLimitIntervalSec=300s
  ```
  Tested by SIGKILL'ing slurmctld — back active in ~5 seconds, scheduler immediately responsive, all nodes IDLE. Real bug recurrence is now invisible: humans don't need to be in the loop.
- **Real fix is the Slurm upgrade.** Tracked separately (24.05+ or 25.05+ via rackslab apt repo) — also unblocks slurm-web v5/v6 native support and slurmrestd JWT auth (drops the UID-match drop-in hack we did for slurm-web-agent).

## Notes / gotchas learned

- **Don't blow on fiber connectors** — moisture/saliva degrades RX power. Use a one-click cleaner or 99% IPA + lint-free wipe.
- **`ip link set up` doesn't create photons** — physical-layer failures can't be fixed in software.
- **TCP retransmits can hide PHY corruption** for low-bandwidth traffic (SSH, slurm heartbeats), but the link will collapse under real load. cgpu01 primary is in this state right now.
- **Netplan / netplan-style configs operate at L3** — they can't cause RX power alarms or PCS symbol errors. Same for BIOS.
- **Asymmetry is diagnostic** — if a config theory were right, all four boxes would behave the same. They didn't, so it's hardware.
- **GPU detection needs `gres.conf`** — a `Gres=gpu:...` line in slurm.conf alone isn't enough. slurmd needs `/etc/slurm/gres.conf` with a device mapping (or `AutoDetect=nvml`) or it reports 0 GPUs and the node auto-drains, even when `nvidia-smi` works.
- **Hold the NVIDIA driver** (`apt-mark hold`) on GPU nodes. An unattended `apt upgrade` bumps the userspace libs but not the loaded kernel module → "Driver/library version mismatch" until reboot. Holding makes driver updates a deliberate, planned action.
- **`scontrol reconfigure` re-validates gres** — it forces slurmd to re-check GPU detection, which can surface latent gres.conf problems that were masked since the last slurmd start. Not a bug, just a thing to know: a config push can expose a pre-existing GPU issue.
- **slurmrestd `auth=local` uses Unix-socket peercred** — the connecting process must share UID with the slurm user, or it 401s. Vendor .deb runs `slurm-web-agent` as `slurm-web`; a systemd drop-in switches it to `slurm`. Avoid if `auth=jwt` is available (Slurm 25.05+).
- **slurm-web ↔ slurmrestd schema versions matter.** v6/v5 expect Slurm 24.x's `0.0.41+`; on 23.11 (`0.0.39`) only `slurmweb-4` works, and even that needs a one-line patch for the `meta.slurm` → `meta.Slurm` capitalization change. Pin the rackslab component and the `version=` line in `agent.ini` together.
- **`MaxCPUsPerNode` caps a partition's total allocation per node**, not per-job. Useful for reserving cores on shared nodes (e.g. cpu-overflow capped at 48/64 leaves 16 for GPU-job host cores).
- **`PriorityTier` ≠ preemption.** It only changes scheduling order when resources free up. Running jobs are never killed unless `PreemptMode` is set. We deliberately leave preemption off.
- **`sinfo -N` emits one row per (node, partition) pair** — a node in 3 partitions shows up 3 times. Dedupe with `awk '!seen[$1]++'` or use `sinfo -e` for the unique view.
- **Enroot config variable is `ENROOT_SQUASH_OPTIONS` (full word), not `ENROOT_SQUASH_OPTS`.** Typos in `/etc/enroot/enroot.conf` silently fail — the variable just isn't read and enroot uses defaults. Verify any new enroot config line by grepping the enroot scripts for the exact variable name.
- **Pyxis SquashFS build is the memory-hungry step**, not the user's command. OOM there shows as `ExitCode 0:53, Elapsed 00:00:01` in sacct because the kill happens in stepd setup before the elapsed timer starts. With uncompressed squashfs (`-noI -noD -noF -noX -no-fragments`) the floor is ~2-3 GB; with gzip default it's ~8 GB.
- **Spack package subclasses don't inherit version-qualified `depends_on`.** Adding a new `version()` line to a backport class isn't enough — if the parent declares `depends_on("htslib", when="@1.19:1.19.X")`, the new version falls outside the `when=` clause and concretization skips the dep. Always re-declare deps explicitly in the subclass with a `when=` matching the new version.
- **Spack v1.x (Jan 2025+) split the builtin package repo into a separate Python package.** v0.23.1 is the last release where `var/spack/repos/builtin/packages/` lives inside the spack git tree. Bumping past v0.23.x requires installing `spack-packages` separately. Pin to v0.23.1 unless you want that migration.
- **Lmod `hide_implicits: true` prevents module-name clashes** between duplicate transitive deps (Spack often concretizes two variants of curl/zstd/openssl with different build options). Hidden deps still autoload from `module load <user-facing-tool>` so behavior is unchanged.
- **Slurm batch scripts using `module` need `#!/bin/bash -l`.** Slurm runs batch shells non-login by default, so `/etc/profile.d/lmod.sh` doesn't auto-source and `module: command not found`. The `-l` flag is the cleanest fix.
- **slurmctld auto-restart hides the assoc_mgr deadlock.** `Restart=on-failure` + `RestartSec=5s` systemd drop-in means a dead controller is back in ~5s with no human action. State is checkpointed every 30s so jobs survive cleanly. Running jobs are unaffected during the gap — only new submits/scheduling/squeue/scancel briefly block.
- **Slurm scheduler crashes don't kill running jobs.** slurmd on each compute node manages its allocated jobs independently of slurmctld. Job processes keep running, stdout keeps writing, cgroup limits stay enforced; only the scheduler-side metadata is paused until slurmctld comes back.

