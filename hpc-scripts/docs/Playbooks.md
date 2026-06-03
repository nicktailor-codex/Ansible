# Ansible Playbooks — runbook

All playbooks live at `~/ansible-dev/playbooks/`. Run from `~/ansible-dev/`.

```bash
cd ~/ansible-dev
ansible-playbook playbooks/<name>.yml                          # full run
ansible-playbook playbooks/<name>.yml --tags <tag>             # subset
ansible-playbook playbooks/<name>.yml --limit insiiukcpu01     # one node
ansible-playbook playbooks/<name>.yml --check                  # dry-run (no changes)
```

All playbooks are idempotent — re-running with no upstream changes should report `changed=0`.

## Idempotence status (verified 2026-06-04)

| Playbook | Idempotent | Notes |
|---|---|---|
| base | ✓ | |
| networking | ✓ | |
| storage | ✓ | Group/mode on `/mnt/<team>` is owned by `team-volumes`, not `storage` |
| raid | ✓ | |
| nvidia | ✓ | Protect-only mode; install path is tag-gated |
| slurm | ✓ | |
| pyxis-enroot | ✓ | |
| mail | ✓ | |
| monitoring | ✓ | |
| spack-lmod | ✓ | |
| team-volumes | ~ | Recursive `file:` task always reports `changed=1` due to Ansible quirk on `recurse: yes`; functionally idempotent (no actual file changes) |

---

## Run order (fresh-cluster bootstrap)

If you're rebuilding from scratch, run in this order:

1. `base.yml` — foundation (sudoers, sysctls, policy-routing prerequisites)
2. `networking.yml` — persistent policy routing for NetApp traffic
3. `storage.yml` — NetApp NFS mounts
4. `raid.yml` — verify local RAID arrays (read-only)
5. `nvidia.yml` — GPU driver install (`--tags install` for first build)
6. `slurm.yml` — slurmctld + slurmd + accounting
7. `pyxis-enroot.yml` — container runtime
8. `mail.yml` — exim4 → EOP relay
9. `monitoring.yml` — slurmrestd + slurm-web + sacctweb
10. `spack-lmod.yml` — module system
11. `team-volumes.yml` — AD group ownership on shared NetApp mounts

After steady-state, you'll only run the ones whose roles changed.

---

## 1. base

Foundation layer applied to every node.

```bash
ansible-playbook playbooks/base.yml
```

- NOPASSWD sudoers drop-in for `ntailor`
- HPC sysctls (`vm.swappiness=10`, `net.core.somaxconn=4096`, `fs.file-max=2M`, etc.)
- Hostname + /etc/hosts consistency
- Idempotent

---

## 2. networking

Policy-routing rules for NetApp traffic (so it always goes out the dedicated secondary NIC).

```bash
ansible-playbook playbooks/networking.yml
```

- systemd-networkd drop-ins persist routes/rules across reboots
- Routes `10.174.16.28/29` (NetApp HA pair) via the secondary NIC table 101
- Idempotent

---

## 3. storage

NetApp NFSv4.2 mounts.

```bash
ansible-playbook playbooks/storage.yml
```

- `/home`, `/software`, `/mnt/{compchem,humgen,informatics}` — all NFSv4.2 nconnect=16
- Local `/scratch` (XFS on local NVMe) ensured present
- Writes `/etc/fstab` entries; survives reboot
- Idempotent

---

## 4. raid

Verify (and optionally repair) local RAID arrays.

```bash
ansible-playbook playbooks/raid.yml
ansible-playbook playbooks/raid.yml --tags repair    # diagnostic repair (opt-in)
```

- Reads `/proc/mdstat` + `mdadm --detail`
- Healthy → `changed=0`. Degraded → flags. Broken → fails loud.
- **Never** runs `mdadm --create` — fresh array build is deliberate, manual
- Idempotent

---

## 5. nvidia

GPU driver hold/install/protect.

```bash
ansible-playbook playbooks/nvidia.yml                       # default: protect-only (apt-mark hold + blacklist)
ansible-playbook playbooks/nvidia.yml --tags install,never  # opt-in install on a fresh GPU node
```

- Default run: ensures `apt-mark hold` on driver/dkms/kernel-modules/cuda/container-toolkit packages
- Unattended-upgrades blacklist at `/etc/apt/apt.conf.d/51-nvidia-blacklist`
- Install path: install driver + reboot 3 times (tag-gated to prevent accidental triggering)
- Idempotent in protect mode

---

## 6. slurm

slurmctld + slurmdbd on controller, slurmd everywhere, accounting tree, partitions, QoS, prologs.

```bash
ansible-playbook playbooks/slurm.yml
ansible-playbook playbooks/slurm.yml --tags config           # just slurm.conf + reconfigure
ansible-playbook playbooks/slurm.yml --tags daemons          # daemon state only
ansible-playbook playbooks/slurm.yml --tags accounting       # accounts/QoS via sacctmgr
ansible-playbook playbooks/slurm.yml --tags secrets          # vault: munge.key + slurmdbd.conf
ansible-playbook playbooks/slurm.yml --tags install,never    # fresh-node install
ansible-playbook playbooks/slurm.yml --tags validate         # sinfo + daemon checks only
ansible-playbook playbooks/slurm.yml --tags cluster-status   # redeploy /usr/local/bin/cluster-status
ansible-playbook playbooks/slurm.yml --tags jobinfo          # redeploy /usr/local/bin/jobinfo
ansible-playbook playbooks/slurm.yml --tags purge-jobs       # redeploy /usr/local/bin/purge-jobs (cpu01 only)
ansible-playbook playbooks/slurm.yml --tags slurm-allow      # redeploy /usr/local/bin/slurm-allow
```

- Vault-encrypted secrets (`munge.key`, `slurmdbd.conf` with DB password)
- `EnforcePartLimits=ALL`, `PreemptMode=OFF`
- slurmctld auto-restart drop-in (assoc_mgr deadlock recovery)
- Idempotent

---

## 7. pyxis-enroot

Container runtime (Enroot 3.5.0 + Pyxis SPANK plugin).

```bash
ansible-playbook playbooks/pyxis-enroot.yml
```

- Enroot installed from NVIDIA `.deb` release
- Pyxis built against Slurm 23.11 headers, drops `spank_pyxis.so` into Slurm's plugin dir
- `/etc/enroot/enroot.conf` — uncompressed squashfs (key gotcha: variable is `ENROOT_SQUASH_OPTIONS`, not `_OPTS`)
- Shared image cache at `/software/enroot-cache` (NetApp)
- Idempotent

---

## 8. mail

exim4 smarthost relay to Microsoft 365 EOP.

```bash
ansible-playbook playbooks/mail.yml
```

- Smarthost: `insmedinc.mail.protection.outlook.com:25`
- Per-host sender: `cpu`/`cgpu`/`gpu01`/`gpu02@insmed.com`
- Slurm `MailProg=/etc/slurm/slurm-mail.sh` wraps bsd-mailx; qualifies bare local-parts with `@insmed.com`
- Idempotent

---

## 9. monitoring

slurmrestd + slurm-web (v4) + sacctweb.

```bash
ansible-playbook playbooks/monitoring.yml
ansible-playbook playbooks/monitoring.yml --tags sacctweb    # just the sacct web UI
ansible-playbook playbooks/monitoring.yml --tags apt-hold    # hold slurm-web .deb's at v4
```

- slurmrestd on cpu01 (Unix socket + JWT key)
- slurm-web v4 via rackslab apt — agent on 5012, gateway on 5011
- One-line patch for `meta.Slurm`/`meta.slurm` capitalisation bug in slurm-web's slurmrestd version() call
- **sacctweb** Flask UI on port 5013 (cpu01-only) — fills v4's missing history view
- Idempotent

---

## 10. spack-lmod

Lmod (every node) + Spack (cpu01, NetApp-shared).

```bash
ansible-playbook playbooks/spack-lmod.yml
ansible-playbook playbooks/spack-lmod.yml --tags spack       # spack-only tasks
ansible-playbook playbooks/spack-lmod.yml --tags profile     # /etc/profile.d/spack.sh only
```

- Lmod 8.6.19 via apt
- Spack v0.23.1 cloned to `/software/spack`
- `insmed` overlay repo (regenie + samtools/bcftools/gcta backports)
- `burden` env at `/software/spack/var/spack/environments/burden/spack.yaml`
- `/etc/profile.d/spack.sh` on every node makes `module avail` work
- Role is infrastructure-only; actual `spack install` is admin-driven via `sudo spack-build-burden`
- Idempotent

---

## 11. team-volumes

AD-group ownership on shared NetApp mounts.

```bash
ansible-playbook playbooks/team-volumes.yml
```

- Maps `/mnt/compchem` → `hpc_compchem`, `/mnt/humgen` → `hpc_humgent`, `/mnt/informatics` → `hpc_informatics`
- Recursive chgrp + setgid (2770) on each volume
- Verifies each AD group resolves via SSSD before touching anything
- cpu01-only (NetApp is shared — one chgrp visible everywhere)
- Idempotent

---

## Vault password

Several playbooks (`slurm.yml` for secrets, future ones) decrypt vault-encrypted files. The password file is `~/.ansible-vault-pass` (mode 0600) — `ansible.cfg` references it automatically.

If you ever lose it, **no recovery is possible** — the munge.key and slurmdbd.conf would need to be regenerated and reset across the cluster.

---

## Quick health check

After any playbook run, sanity-check the cluster with:

```bash
cluster-status                       # fleet free cores/mem/GPU
sinfo                                # partition + node state
squeue                               # current queue
sudo /usr/local/bin/spack_slurm_smoke.sh    # end-to-end Slurm + Spack + module smoke
```
