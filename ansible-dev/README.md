# research-cluster Ansible

Codifies the cluster build for the 4-node Slurm cluster (cpu01 + 3 GPU nodes).

## Layout
```
/home/ntailor/ansible-dev/
├── ansible.cfg          ← project-local config (auto-loaded here)
├── inventory/hosts.ini  ← 4 nodes, grouped
├── group_vars/          ← shared variables (all.yml etc.)
├── host_vars/           ← per-host overrides
├── playbooks/           ← entry points (e.g. site.yml, base.yml)
└── roles/               ← reusable components (base/, slurm/, pyxis/, ...)
```

## Run

Roles are applied via per-role playbooks under `playbooks/`. There is **no `site.yml`** — apply roles individually so each one's blast radius and target hosts are explicit.

### Connectivity check

```bash
cd /home/ntailor/ansible-dev
ansible all -m ping
```

### Dry-run conventions

Every playbook supports `--check --diff`:
- `--check` — Ansible reports what *would* change, no actions executed
- `--diff` — for file/template changes, show the unified diff that *would* be written

Some tasks (custom commands, scripts that don't expose `check_mode`) will report "skipped" in `--check` mode — that's expected. The output still shows everything else accurately.

### Narrowing scope (flags every role accepts)

```bash
# Only one node:
ansible-playbook playbooks/slurm.yml --check --diff --limit insiiukgpu01

# Only specific tasks (see per-role tag breakdown below):
ansible-playbook playbooks/slurm.yml --tags config --check --diff

# Multiple tags at once:
ansible-playbook playbooks/slurm.yml --tags "config,prolog" --check --diff

# Skip a tag:
ansible-playbook playbooks/base.yml --skip-tags mkhomedir

# Start from a specific task in the play:
ansible-playbook playbooks/base.yml --start-at-task "Install apt packages"

# List all tags a playbook would touch (no actions taken):
ansible-playbook playbooks/slurm.yml --list-tags
```

### Apply (after dry-run looks right)

Drop `--check --diff` from any command in this README:

```bash
ansible-playbook playbooks/<role>.yml [--tags <tag>] [--limit <host>]
```

---

## Roles reference — what each does + what its tags scope to

Each role is its own playbook. The role's *role tag* (same as the role name) runs everything; subtags scope to a sub-step. Many subtags exist so you can re-apply just one piece without re-running the whole role (e.g. push a new `slurm.conf` without bouncing daemons).

### `base` — every-node baseline

**What it does:** Cluster `/etc/hosts` block, required apt packages (`nfs-common`, `acl`, `nfs4-acl-tools`, `exim4`), removes packages that conflict with exim (`bsd-mailx`, `mailutils`), sysctl tuning (`kernel.unprivileged_userns_clone=1` for enroot), and the two PAM hooks that auto-create per-user home + scratch dirs on first login.

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/base.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `hosts` | `/etc/hosts` — cluster node names (short + FQDN for all 4 nodes) |
| `packages` | apt install/remove (`nfs-common`, `acl`, `nfs4-acl-tools`, `exim4`; removes `bsd-mailx`, `mailutils`) |
| `sysctl` | Kernel tunables — currently `unprivileged_userns_clone=1` so enroot can create user namespaces |
| `mkhomedir` | PAM `pam_mkhomedir` enabling — auto-creates `/home/<user>` on AD users' first login |
| `scratchdir` | Drops `/usr/local/sbin/ensure-scratch-dir` + pam-config; auto-creates `/scratch/<user>` (0700) on login. Mirrors what mkhomedir does for `/home` |

---

### `networking` — DNS + hostname resolution

**What it does:** Resolver config (nameservers, search domains), hostname assertion.

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/networking.yml --check --diff`

**Tags:** No subtags — single-purpose role. The role tag (`networking`) is the only one.

---

### `raid` — local NVMe stripe (per-node)

**What it does:** Validates the per-node `/dev/md1` RAID-0 across NVMe drives that backs `/scratch` (XFS on top). The `install` and `repair` paths are gated behind `never`-tags so they don't fire on a normal play run — they're explicit-opt-in one-shots for a fresh node or a degraded array.

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/raid.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `validate` | Asserts the md device + XFS mount are healthy and present |
| `install` | (Tagged `never`.) Fresh-node bootstrap: assemble the array, format XFS, add to fstab. Explicit opt-in: `--tags install` |
| `repair` | (Tagged `never`.) Repair instructions for a degraded array. Explicit opt-in: `--tags repair` |

---

### `storage` — NFS mounts + `/scratch` baseline + NFSv4 ID mapping

**What it does:** Creates mount points for `/software` + `/mnt/{compchem,humgen,informatics}`, mounts the NetApp NFSv4 volumes (writes fstab and mounts in one shot), configures NFSv4 ID-mapping domain to match AD (`insmed.local`), and enforces `/scratch` parent perms at 0755 (`/home` model).

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/storage.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `nfs` | NFS mount point dirs + `ansible.posix.mount` to mount NetApp volumes (writes/asserts fstab too). Used when remounting after a NetApp shrink/resize. |
| `idmapd` | `/etc/idmapd.conf` Domain= line; clears the nfsidmap cache on change |
| `scratch` | Sets `/scratch` parent to 0755 root:root (matches `/home`). Per-user subdirs handled by base role's `scratchdir` PAM hook + slurm prolog |

Team-mount perm management is **not** in this role — it lives in `team-volumes`. The team-volume entries in `group_vars/all.yml` have `manage_perms: false` so this role doesn't fight team-volumes over chgrp.

---

### `mail` — local MTA + Slurm mail wrapper

**What it does:** Configures `exim4` as a smarthost relay through Insmed's EOP. Drops `/etc/slurm/slurm-mail.sh` — the wrapper Slurm calls for `--mail-user=...` jobs, which qualifies bare local-parts to `<user>@insmed.com` so mail actually delivers.

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/mail.yml --check --diff`

**Tags:** No subtags — single-purpose role.

---

### `slurm` — controller + worker config, accounts, custom helpers

**What it does:** The heart of the cluster. Manages `slurm.conf`, `cgroup.conf`, `plugstack.conf`, per-node `gres.conf`, the slurmdbd account hierarchy (compchem/human_genetics/informatics under `research`), QoS definitions (normal/debug), the slurmctld auto-restart drop-in, the prolog/epilog scripts, and the four custom admin helpers (`cluster-status`, `jobinfo`, `purge-jobs`, `slurm-allow`).

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/slurm.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `config` | Push `slurm.conf` + `cgroup.conf` + `plugstack.conf` + `gres.conf` (no daemon restart, no validate) |
| `daemons` | Enable/restart slurmctld + slurmdbd + slurmd; installs the systemd `Restart=on-failure` drop-in for slurmctld |
| `secrets` | Munge key (vault-managed) + slurmdbd DB password — restricted perms |
| `accounting` | sacctmgr — assert the cluster, accounts (compchem/human_genetics/informatics), default QoS, admin levels |
| `prolog` | `/etc/slurm/prolog.d/` + `epilog.d/` scripts — per-job scratch dir, enroot scratch dirs |
| `validate` | Health checks: `scontrol show nodes`, `sinfo`, daemon status, smoke `srun` |
| `cluster-status` | Drops `/usr/local/bin/cluster-status` (fleet free cores/mem/GPU summary) |
| `jobinfo` | Drops `/usr/local/bin/jobinfo` (pretty sacct/scontrol wrapper) |
| `purge-jobs` | Drops `/usr/local/sbin/purge-jobs` (admin-only slurmdbd MySQL DELETE helper with backup); cpu01 only |
| `slurm-allow` | Drops `/usr/local/bin/slurm-allow` (runtime `AllowAccounts` partition editor) |

---

### `pyxis-enroot` — container runtime for Slurm

**What it does:** Installs enroot 3.5.0 + pyxis v0.20.0 SPANK plugin (built against Slurm 23.11.4 headers), drops `enroot.conf` with the shared NetApp cache + per-job local scratch, registers pyxis in `/etc/slurm/plugstack.conf`.

**Target hosts:** `all_cluster`
**Dry-run:** `ansible-playbook playbooks/pyxis-enroot.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `config` | `enroot.conf` + plugstack registration |
| `validate` | Smoke test — pull a tiny container, extract, run `true` inside it |

---

### `spack-lmod` — module system + package envs

**What it does:** Installs Lmod (apt, per-node) for the `module` command, clones Spack v0.23.1 to `/software/spack` (NetApp-shared), drops the Insmed package overlay (regenie + samtools/bcftools/gcta backports), deploys two Spack environments (`burden` for genetics tools, `cuda` for CUDA toolkits), drops `/etc/profile.d/spack.sh`, and the `spack-build-burden` tmux helper. **Does not run `spack install`** — that's a multi-hour admin task, see role README.

**Target hosts:** `all` (a few tasks gate on cpu01 only since `/software/spack` is NetApp)
**Dry-run:** `ansible-playbook playbooks/spack-lmod.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `lmod` | apt install lmod on every node |
| `spack` | Spack tree clone + site config + insmed overlay + env declarations |
| `profile` | `/etc/profile.d/spack.sh` (sources setup-env, exposes `module` to login shells) |
| `cuda` | Just the `cuda` env declaration (CUDA 12.4.1 + 12.6.2). Does NOT install — run `sudo spack -e cuda install` separately |

---

### `nvidia` — drivers, container toolkit, lockdown

**What it does:** Manages the NVIDIA driver + NVIDIA Container Toolkit on GPU nodes. Holds the driver + cuda packages via apt-mark to keep unattended-upgrades from desyncing kernel module ↔ userspace libs. Provides a fresh-node install path + ongoing validate.

**Target hosts:** `gpu_nodes`
**Dry-run:** `ansible-playbook playbooks/nvidia.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `runtime` | NVIDIA Container Toolkit config (so pyxis/docker can see GPUs) |
| `lockdown` | apt-mark hold on `nvidia-*`, `libnvidia-*`, `cuda-*`, `nsight-*`, `datacenter-gpu-manager`, `nvidia-container-*`; blacklists nouveau |
| `validate` | `nvidia-smi` health check on each GPU node |

---

### `slurm-ui` — Slurm web UIs (slurm-web v4 + sacctweb)

**What it does:** Codifies the two web UIs that sit in front of Slurm. **slurm-web v4** (rackslab apt repo, pinned to slurmweb-4 component) for the live queue/nodes/partitions view, plus the one-line `meta.Slurm` capitalisation patch needed for Slurm 23.11. **sacctweb** — the Flask job-history app we wrote because slurm-web v4 has no history view — deployed as `/usr/local/bin/sacctweb` + systemd unit running as the `slurm` user with `PrivateTmp` / `ProtectSystem` hardening. Plus rsyslog filters that drop the polling noise from both UIs.

> **Not** general monitoring (Prometheus, node_exporter, alerting, etc.). Just Slurm-facing web UIs. Renamed from `monitoring` on 2026-06-08 to make the boundary clear — `monitoring` is reserved for any future real-monitoring stack.

**Target hosts:** `controllers` (cpu01)
**Dry-run:** `ansible-playbook playbooks/slurm-ui.yml --check --diff`

| Tag | Scopes to |
|---|---|
| `sacctweb` | Deploys `/usr/local/bin/sacctweb` + systemd unit + service enable/restart. URL: `http://10.174.16.55:5013/` |
| `apt-hold` | Pins slurm-web to v4 (rackslab repo, `slurmweb-4` component, apt-mark hold + unattended-upgrades blacklist) |
| `history` | Applies the slurm-web `jobs()` patch that merges 7-day sacct history into the live view (slurm-web v4 only shows live jobs natively) |

---

### `team-volumes` — team mount permissions

**What it does:** Asserts chgrp to the right AD group + mode `2770` (setgid for inheritance) on `/mnt/compchem`, `/mnt/humgen`, `/mnt/informatics`. Driven by the `team_volumes` block in `group_vars/all.yml`. Runs on controller only since the perms apply to NetApp mounts seen from every node.

**Target hosts:** `slurm_controller` (defaults to `insiiukcpu01`)
**Dry-run:** `ansible-playbook playbooks/team-volumes.yml --check --diff`

**Tags:** No subtags — single-purpose role.

This is the role to re-run if team perms ever drift (or after a NetApp resize — though NetApp preserves perms across `volume size`).

---

## Common targeted invocations

```bash
# Re-push slurm.conf only (no daemon touch, no validate)
ansible-playbook playbooks/slurm.yml --tags config

# Re-mount NFS shares without touching idmapd or /scratch
ansible-playbook playbooks/storage.yml --tags nfs

# Apply just the /scratch baseline (parent perms)
ansible-playbook playbooks/storage.yml --tags scratch

# Apply just the PAM scratchdir hook
ansible-playbook playbooks/base.yml --tags scratchdir

# Install the CUDA env declarations (does NOT spack install — see spack-lmod role README)
ansible-playbook playbooks/spack-lmod.yml --tags cuda

# Refresh sacctweb service only
ansible-playbook playbooks/slurm-ui.yml --tags sacctweb

# Re-validate Slurm health
ansible-playbook playbooks/slurm.yml --tags validate

# Re-apply team mount perms (after AD changes or perm drift)
ansible-playbook playbooks/team-volumes.yml
```

### Apply-everything sweep (use sparingly)

When you genuinely want to re-apply every role to every node — typically after a fresh node or a major refactor:

```bash
# Dry-run the whole stack (order matters: base → storage → … → slurm last):
for p in base networking raid storage mail nvidia pyxis-enroot spack-lmod slurm slurm-ui team-volumes; do
  echo "=== $p (check) ==="
  ansible-playbook playbooks/$p.yml --check --diff || break
done
```

Drop `--check --diff` to apply. The `|| break` stops the loop on the first failure so you don't cascade broken state.

### Useful one-off ad-hoc commands

```bash
# Status of a service on every node:
ansible all -b -m ansible.builtin.systemd -a "name=slurmd"

# Shell command on a host group:
ansible gpu_nodes -m ansible.builtin.shell -a "nvidia-smi --query-gpu=name,driver_version --format=csv,noheader"

# Mount/unmount via ansible.posix.mount (preserves fstab with state=unmounted):
ansible all -b -m ansible.posix.mount -a "path=/mnt/compchem state=mounted"
```
