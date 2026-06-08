# slurm role

Codifies the Slurm controller and worker configuration across the
research cluster (`insiiukcpu01` + `insiiukgpu01` + `insiiukgpu02` +
`insiiukcgpu01`). Manages the canonical `slurm.conf`, `cgroup.conf`,
`plugstack.conf`, per-node `gres.conf`, the account hierarchy in
slurmdbd, and the QoS tiers.

## File layout

```
roles/slurm/
├── defaults/main.yml         vars — QoS definitions, expected version, ownership
├── files/
│   ├── slurm.conf            canonical (identical on every node, 4182B+)
│   ├── cgroup.conf           resource-enforcement plugin config
│   └── plugstack.conf        SPANK plugin loader (Pyxis)
├── templates/
│   └── gres.conf.j2          per-node GPU mapping; rendered with slurm_gpu_type
├── handlers/main.yml         restart slurmctld, restart slurmd
└── tasks/
    ├── main.yml              entry — imports config + accounting + validate
    ├── config.yml            push the 4 config files
    ├── accounting.yml        sacctmgr — accounts + QoSes + associations
    └── validate.yml          sinfo, daemon checks, slurmd -G GRES assertions
```

## Tags

| Tag | What runs |
|---|---|
| (default) | `config` + `accounting` + `validate` |
| `config` | Just push the 4 config files; handlers fire on diff |
| `accounting` | Just the sacctmgr ops (accounts + QoS + associations) |
| `validate` | Just the read-only health checks |

```bash
ansible-playbook playbooks/slurm.yml                        # apply everything
ansible-playbook playbooks/slurm.yml --tags config          # config push only
ansible-playbook playbooks/slurm.yml --tags accounting      # accounting only
ansible-playbook playbooks/slurm.yml --tags validate        # health check only
```

## Cluster topology

```
research-cluster
├── insiiukcpu01    controller  · 128 vCPU · 512 GB · no GPU
├── insiiukgpu01    compute     ·  64 vCPU · 256 GB · H200 NVL 141 GB
├── insiiukgpu02    compute     ·  64 vCPU · 256 GB · H200 NVL 141 GB
└── insiiukcgpu01   compute     ·  64 vCPU · 256 GB · L4 24 GB
```

slurmctld + slurmdbd + MariaDB live on cpu01. No MPI; jobs are
single-node-bound (`MaxNodes=1` on every partition).

## Partitions

Each compute node has its own partition (per-node isolation). `interactive`
spans two nodes for low-walltime interactive sessions, but jobs still
land on one node.

| Partition | Node(s) | Default | MaxTime | DefaultTime | DefaultQoS | AllowQoS |
|---|---|---|---|---|---|---|
| `cpu` | cpu01 | YES | 5d | 8h | normal | debug,normal |
| `gpu01` | gpu01 | NO | 5d | 4h | normal | debug,normal |
| `gpu02` | gpu02 | NO | 5d | 4h | normal | debug,normal |
| `cgpu01` | cgpu01 | NO | 2d | 2h | normal | debug,normal |
| `interactive` | cpu01 + cgpu01 | NO (PriorityTier=10) | 8h | 2h | normal | debug,normal |

The `Qos=normal` keyword on each partition is the partition's *default*
QoS (applies when user doesn't pass `--qos=`). `AllowQos=` is the
whitelist of which QoSes are valid on this partition.

## Accounting hierarchy

```
root
└── informatics                  (parent — organisation root)
    ├── bioinformatics            (empty — placeholder)
    ├── compchem                  (empty — placeholder)
    └── human_genetics            (empty — placeholder)
```

Users:
- `ntailor` → associated with `informatics` (default account)

Sub-accounts are empty placeholders today. When team members come on
board, add them to the appropriate sub-account (see *Common operations*
below).

### Naming note
The parent account was renamed from `research` → `informatics` on
2026-05-31 via a one-shot sacctmgr dance (Slurm 23.11 can't rename
accounts in-place; pattern was: add new → re-parent children → re-add
user with new default → delete user-from-old-account → delete old).
The role manages **forward state only** — a fresh cluster setup will
build `informatics` directly.

## QoS tiers

Two QoSes today. Both associated with `informatics` (and inherited by
sub-accounts).

| QoS | Priority | MaxWall | Intended use |
|---|---|---|---|
| `debug` | 500 | 1h | Quick test jobs that jump ahead of the normal queue |
| `normal` | 0 | 5d | Default for everything else |

Users opt into debug explicitly:
```bash
sbatch --qos=debug --time=30:00 ...
```

Anything without `--qos=` lands in `normal` (the partition default).

## Resource enforcement matrix

| Resource | Mechanism | When it kicks in |
|---|---|---|
| Walltime vs partition `MaxTime` | `EnforcePartLimits=ALL` | **Submit-time rejection** |
| Walltime vs partition's default QoS `MaxWall` | `EnforcePartLimits=ALL` | **Submit-time rejection** |
| Walltime vs explicit non-default QoS `MaxWall` | `AccountingStorageEnforce=limits` | Runtime kill at MaxWall (⚠️ not submit-time — see *Known limitations*) |
| Memory overrun (job uses more `--mem` than allocated) | `ConstrainRAMSpace=yes` in cgroup.conf | Runtime OOM kill |
| CPU pinning (job tries to escape allocated cores) | `ConstrainCores=yes` in cgroup.conf | Restricted; can't exceed |
| GPU device access (job opens unauthorized `/dev/nvidiaN`) | `ConstrainDevices=yes` in cgroup.conf | Blocked at the device level |
| Container runtime (Pyxis+Enroot) | `plugstack.conf` loads `spank_pyxis.so` | Job-time only |

Submit a job with `--time=10d` to the `cpu` partition (MaxTime=5d) and
you'll get an immediate rejection:
```
sbatch: error: Requested time limit is invalid (missing or exceeds some limit)
sbatch: error: Batch job submission failed: Job violates accounting/QOS policy
```

## Handlers

| Handler | Triggered by | Action |
|---|---|---|
| `restart slurmctld` | `slurm.conf` change | Restart slurmctld on cpu01 (~3s, running jobs survive) |
| `restart slurmd` | `cgroup.conf`, `plugstack.conf`, `gres.conf` change | Restart slurmd on the affected node |

**Why a full restart for `slurm.conf`?** Slurm 23.11's `scontrol
reconfigure` does NOT pick up several keywords, including:
- `AccountingStorageTRES`
- Partition `AllowQos` / `Qos=`
- `EnforcePartLimits`

We were bitten by this twice on 2026-05-31 (GPU TRES tracking + partition
QoS); fix is the full restart. Brief downtime; jobs continue.

## Common operations

### Add a new user
```bash
# 1. (One-time) Make sure the user's AD account resolves on the cluster:
ansible all_cluster -m shell -a "id <username>"

# 2. Associate with informatics (default account):
sudo sacctmgr -i add user <username> account=informatics

# 3. (Optional) Move them into a sub-account:
sudo sacctmgr -i add user <username> account=compchem
sudo sacctmgr -i modify user <username> set defaultaccount=compchem
```

### Add a new QoS

Edit `roles/slurm/defaults/main.yml`:
```yaml
slurm_qos_definitions:
  - { name: debug,  priority: 500, maxwall: "01:00:00" }
  - { name: normal, priority: 0,   maxwall: "5-00:00:00" }
  - { name: long,   priority: -50, maxwall: "14-00:00:00" }    # ← new
```

Update partition `AllowQos=` in `roles/slurm/files/slurm.conf` (add
`long` to each `AllowQos=debug,normal` line you want to allow `long`).

Apply:
```bash
ansible-playbook playbooks/slurm.yml --tags accounting,config
```

Re-apply to confirm idempotence (`changed=0` expected).

### Bump a QoS priority or walltime
Edit the value in `defaults/main.yml`, apply with `--tags accounting`.
The drift-correction task in `accounting.yml` detects the mismatch via a
snapshot-then-compare pattern and runs `sacctmgr modify qos ... set`.

### Submit a test job with debug QoS
```bash
sbatch --partition=cpu --qos=debug --time=30:00 --wrap='hostname'
```
Priority 500 means this jumps ahead of any `normal` jobs in the queue.
1h walltime cap (enforced at runtime).

### Submit a containerized job (Pyxis + Enroot)
See the `pyxis-enroot` role README. Smoke tests:
- `run-dir/pyxis_burden_smoke.sh` — runs the burdentesting container across
  all 4 partitions in parallel; 20 content checks per partition
- `run-dir/pyxis_gpu_smoke.sh` — validates GPU passthrough on a GPU
  partition by running `nvidia-smi` inside a CUDA container

## Known limitations

### Explicit non-default QoS isn't checked at submit
`EnforcePartLimits=ALL` rejects submissions that exceed partition limits
or the partition's **default** QoS limits. It does NOT re-check a
user-specified `--qos=` against that QoS's MaxWall at submit. The job
is accepted with the requested `--time`, and Slurm kills it at runtime
when the QoS MaxWall fires.

User-facing impact: `sbatch --qos=debug --time=2h` is accepted; `squeue`
shows `Timelimit=2h`; job dies at 1h with a `JobAcctGather` reason.
Confusing if the user wasn't expecting it.

Workaround (not implemented): a `job_submit/lua` plugin that intercepts
submits and validates explicit `--qos=` against the QoS's MaxWall.
Adding this is small but adds operational complexity (an out-of-tree
Lua script alongside slurm.conf). Deferred unless it bites someone.

### Sub-accounts have no users
`bioinformatics`, `compchem`, `human_genetics` exist as parent-association
placeholders only. Add users as teams come online.

### No fairshare configured
Priority today is FIFO + QoS-priority-boost (`debug` jumps over `normal`)
+ `PriorityTier=10` on `interactive`. No multifactor priority weighting
across users. With 1-2 users today this is fine; revisit when there's
real contention.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `sbatch: error: Requested time limit is invalid (missing or exceeds some limit)` | `--time` exceeds partition MaxTime or default QoS MaxWall | Reduce `--time`, switch partition, or `--qos=` something with a higher cap |
| `sbatch: error: Invalid account or account/partition combination` | User not associated with the account, or account not allowed on partition | `sacctmgr show association where user=<u>` to inspect; add assoc if needed |
| Job dies mid-run with `JobAcctGather` or `TimeLimit` reason | Hit the QoS MaxWall when `--qos=` was explicit | `sacct -j <id> --format=Reason,QOS`; lower `--time` next run or pick a roomier QoS |
| Job stuck `PENDING` with reason `AssocMaxJobsLimit` | A per-user `MaxJobsPU` cap was added (not in v1) | Wait or check `sacctmgr show qos` for `MaxJobsPU` |
| `scontrol reconfigure` ran but partition setting didn't update | 23.11 won't reload `AllowQos`/`Qos=`/`EnforcePartLimits` via reconfigure | Restart slurmctld: `sudo systemctl restart slurmctld` (or re-apply the role) |
| `Error: AccountingStorageTRES has been removed` after editing slurm.conf | Trying to remove a TRES from `AccountingStorageTRES` after it's been seen | Don't remove TRES entries from `AccountingStorageTRES` — only add. Removal needs slurmdbd schema work. |
| Pyxis jobs fail with `pyxis: required plugin failed to load` | `plugstack.conf` missing or wrong path | `ls -la /etc/slurm/plugstack.conf` + `ls -la /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so` |
| GPU job lands but `nvidia-smi` says "No devices found" | Likely `AccountingStorageTRES` missing `gres/gpu` (the 2026-05-31 bug) | Check `scontrol show node <node> \| grep CfgTRES` — should include `gres/gpu=1` |

## Cross-references

- **Partition proposal:** [/home/ntailor/run-dir/docs/paritition-review](../../../run-dir/docs/paritition-review) (source for the partition design + QoS tier decision)
- **Pyxis+Enroot setup:** [/home/ntailor/run-dir/PyxisEnroot-Setup.md](../../../run-dir/PyxisEnroot-Setup.md)
- **Smoke tests:** [/home/ntailor/run-dir/pyxis_burden_smoke.sh](../../../run-dir/pyxis_burden_smoke.sh), [/home/ntailor/run-dir/pyxis_gpu_smoke.sh](../../../run-dir/pyxis_gpu_smoke.sh)
- **TODO (next-session backlog):** [/home/ntailor/ansible-dev/TODO.md](../../TODO.md)
- **Related roles:** `pyxis-enroot` (container runtime), `nvidia` (driver lockdown), `storage` (NetApp mounts)
