# Slurm configuration — research-cluster

Reference / source-of-truth for the Insmed cluster's Slurm setup. Facts only — pass to an LLM to expand into operational/user docs.

Last verified live against the cluster: 2026-06-04.

---

## 1. Cluster basics

| Item | Value |
|---|---|
| `ClusterName` | `research-cluster` |
| Slurm version | 23.11.4 (Ubuntu 24.04 apt) |
| Controller (slurmctld + slurmdbd) | `insiiukcpu01` |
| `AuthType` | `auth/munge` |
| Accounting | `slurmdbd` → MySQL on cpu01 |
| `SchedulerType` | `sched/backfill` |
| `SelectType` | `select/cons_tres` + `CR_CPU_Memory` (cores + memory tracked) |
| `ProctrackType` | `proctrack/cgroup` (cgroup v2) |
| `TaskPlugin` | `task/affinity,task/cgroup` |
| `JobAcctGatherType` | `jobacct_gather/cgroup` every 30s |
| `MailProg` | `/etc/slurm/slurm-mail.sh` (qualifies bare local-parts → `@insmed.com`) |
| `PreemptType` / `PreemptMode` | none / OFF — running jobs are never killed |
| `EnforcePartLimits` | `ALL` — jobs that exceed partition or QoS walltime rejected at submit |
| `GresTypes` | `gpu` |
| `AccountingStorageTRES` | `gres/gpu,gres/gpu:h200_nvl,gres/gpu:l4` |
| `AccountingStorageEnforce` | `associations,limits,qos` |

**Auto-restart:** `slurmctld` has a systemd drop-in (`Restart=on-failure`, `RestartSec=5s`) — handles the rare assoc_mgr deadlock in Slurm 23.11.x. State checkpointed to disk every ~30s; restart recovers in-flight jobs cleanly. Running jobs unaffected during the gap.

## 2. Nodes

| Node | Cores | Mem | GPU | Role |
|---|---|---|---|---|
| `insiiukcpu01` | 128 | 512 GB | — | controller + compute, free-for-all |
| `insiiukgpu01` | 64 | 256 GB | 1× H200 NVL | compute, free-for-all |
| `insiiukgpu02` | 64 | 256 GB | 1× H200 NVL | compute, **compchem only** |
| `insiiukcgpu01` | 64 | 256 GB | 1× L4 | compute, **compchem only** |

All Intel Xeon 6700-series (Granite Rapids), Ubuntu 24.04, on a NetApp NFSv4.2 fabric (`10.174.16.28`). `/home` and `/software` are NetApp-shared; `/scratch` is local-per-node XFS on ~7 TB NVMe.

## 3. Partitions

| Partition | Nodes | Default time | Max time | PriorityTier | AllowAccounts | Notes |
|---|---|---|---|---|---|---|
| **`cpu`** *(default)* | cpu01 | 8h | 5d | 1 | ALL | CPU-only work |
| `gpu01` | gpu01 | 4h | 5d | 5 | ALL | Free-for-all H200 |
| `gpu02` | gpu02 | 4h | 5d | 5 | **compchem** | Dedicated compchem H200 |
| `cgpu01` | cgpu01 | 2h | 2d | 5 | **compchem** | Dedicated compchem L4 |
| `interactive` | cpu01 | 2h | 8h | 10 | ALL | Highest priority for short jobs |
| `cpu-overflow` | cpu01 + gpu01 | 4h | 1d | 1 | ALL | Spillover CPU work onto the free-for-all H200 node's idle cores. `MaxCPUsPerNode=48` reserves 16 cores for GPU jobs. |

All partitions: `AllowQos=debug,normal`, `OverSubscribe=NO`, `MaxNodes=1` (no MPI across nodes), `DefMemPerCPU=4096` (4 GB/core).

**Access mechanism**: `AllowAccounts` (Slurm accounting), NOT `AllowGroups` (Linux/AD). Aligns with billing and avoids the admin-bypass complications of group-based gating.

## 4. Accounting tree

```
root
└── research                  (parent — virtual; no jobs charged here)
    ├── bioinformatics
    ├── compchem
    └── human_genetics
informatics                   (separate top-level org root)
```

### Valid accounts users submit jobs against

| Account | Tied AD group | Description | Partition access |
|---|---|---|---|
| `bioinformatics` | (AD group TBD) | Bioinformatics research group | cpu, gpu01, interactive, cpu-overflow |
| `compchem` | `hpc_compchem` | Computational chemistry | **all partitions** (only account allowed on gpu02 + cgpu01) |
| `human_genetics` | `hpc_humgent` | Human genetics | cpu, gpu01, interactive, cpu-overflow |
| `informatics` | `hpc_informatics` | Informatics organisation root | cpu, gpu01, interactive, cpu-overflow |

Submit with `-A <account>`. Each user has a default account (set via `defaultaccount=`) used when `-A` is omitted.

Register a new user against an account:
```bash
sudo -u slurm sacctmgr add user <username> account=<acct> defaultaccount=<acct>
```

`AccountingStorageEnforce=associations,limits,qos` means jobs submitted without a valid user→account association are rejected at submit time.

### Admin levels

Slurm has three admin tiers, set per-user via `sacctmgr`. Operator and Administrator bypass `AllowAccounts` / `AllowGroups` / `AllowQos` restrictions — they can submit to any partition with any QoS regardless of account membership.

| Level | Capabilities |
|---|---|
| `None` *(default)* | Regular user. Bound by partition `AllowAccounts`. |
| `Operator` | Submit/cancel/scontrol on any partition; manage reservations. Cannot modify the accounting database. |
| `Administrator` | Everything `Operator` does + full sacctmgr (create/delete accounts, users, QoS). |

Current admins:

| User | Admin level | Why |
|---|---|---|
| `ntailor` | `Operator` | Cluster admin — needs to submit jobs everywhere for testing/maintenance; doesn't need to modify accounts |

Change with:
```bash
sudo -u slurm sacctmgr modify user <name> set adminlevel=Operator
```

## 5. QoS

| Name | Priority | MaxWall | Purpose |
|---|---|---|---|
| `normal` | 0 | 5d | Default for all production work |
| `debug` | 500 | 1h | Queue-jump for short interactive tests (`-q debug`) |

No per-user/account TRES limits today. Easy to add later via `sacctmgr modify qos ...` (GrpTRES, MaxJobsPU, MaxSubmitJobs, GrpTRESMins, etc.) when usage scales.

## 6. Scheduler & priority

### Settings

| Setting | Value | Meaning |
|---|---|---|
| `SchedulerType` | `sched/backfill` | Backfill scheduler — walks the queue looking for jobs that can fit in resource gaps without delaying higher-priority jobs |
| `SchedulerParameters` | *(empty)* | All Slurm defaults: `bf_window=1440min`, `bf_resolution=60s`, `bf_max_job_test=100`, `bf_interval=30s`, `bf_continue=No` |
| `SchedulerTimeSlice` | 30s | Backfill main-loop cycle |
| `PriorityType` | `priority/multifactor` | Multifactor priority plugin enabled |
| `PriorityWeight*` | **all 0** | No weights → multifactor sum is always 0 (see below) |
| `PriorityDecayHalfLife` | 7d | Usage decay window (irrelevant while weights are 0) |
| `PriorityMaxAge` | 7d | Cap on age-based priority growth (irrelevant while weights are 0) |

### How multifactor priority works (in theory)

Slurm calculates a priority number for each pending job by summing weighted factors:

```
priority = PriorityWeightFairshare × fairshare_score   (account usage history)
         + PriorityWeightAge       × age_score         (how long it's been waiting)
         + PriorityWeightJobSize   × size_score        (resource request size)
         + PriorityWeightPartition × partition_factor  (partition priority)
         + PriorityWeightQOS       × qos_factor        (QoS priority)
         + PriorityWeightTRES      × tres_factor       (per-resource weights)
         + PriorityWeightAssoc     × assoc_score
```

Each `*_score` is normalized 0.0–1.0; the weights scale them. Jobs are then ordered by priority descending — highest priority runs first when resources free up.

### How it actually works here (with all weights at 0)

Every term collapses to `0 × something = 0`. The sum is always 0. **Every job in the queue has the same numeric priority.**

When priorities tie, Slurm falls back to two cheap tiebreakers in order:

1. **Partition `PriorityTier`** (an integer per-partition, not a weight) — wins outright. `interactive`=10 beats `gpu*`=5 beats `cpu`/`cpu-overflow`=1. This is a hard ordering, not a weighted contribution.
2. **Submit time** — within the same tier, oldest submit wins (FIFO).

**Concrete example:**

| Job | Partition | Tier | Submitted | Scheduler order |
|---|---|---|---|---|
| C | cpu | 1 | 08:55 (oldest) | last |
| A | interactive | 10 | 09:00 | **first** |
| B | gpu01 | 5 | 09:01 | middle |

The scheduler tries A first (tier 10), then B (tier 5), then C (tier 1) — even though C was submitted earliest.

### Where backfill fits

Backfill runs on top of this ordering. It says: *"if there's a resource gap where a lower-priority job can fit without delaying any higher-priority job, start it now."*

So if A is waiting 4 hours for resources and B can complete in 30 minutes without touching A's eventual allocation, backfill starts B early. Same for C if there's room. This is what keeps the cluster utilised when the queue mixes big slow jobs and small fast ones.

### Subtle point: `debug` QoS doesn't actually queue-jump (yet)

The `debug` QoS has `Priority=500` configured. That priority field *only contributes if `PriorityWeightQOS` > 0*. Today it's 0, so `-q debug` doesn't actually run before `-q normal` jobs — it just enforces the 60-min walltime cap.

To make `debug` truly preferred (the typical reason to have it), the one-line change in slurm.conf is:
```
PriorityWeightQOS=10000
```
followed by `scontrol reconfigure`. No restart, no daemon disruption.

### Why we left it this way

- **Small cluster, small user base.** With 4 nodes and a handful of users, there's no real queue contention worth arbitrating. The complexity of fairshare/age tuning earns you nothing.
- **Predictable beats clever.** "What you submitted first runs first (modulo partition tier)" is trivially explainable to users. Tuning fairshare weights means now you have to explain why job X is running before job Y submitted earlier.
- **No migration cost later.** All the plumbing (multifactor plugin, slurmdbd, decay/age periods) is already in place. When usage scales up and someone starts hogging, flipping on fairshare is a slurm.conf edit + `scontrol reconfigure`:
  ```
  PriorityWeightFairshare=10000
  PriorityWeightAge=1000
  PriorityWeightQOS=10000
  ```
  No new daemons, no schema change.

### When to revisit

Turn on weights when **any** of these starts happening:
- One user/account fills the queue and others are stuck waiting for days
- Someone needs `-q debug` to actually queue-jump (not just walltime-cap)
- Long jobs are starving short ones (rare at this scale)

## 7. GPU resource tracking

GPUs registered as GRES with explicit types:
- `gpu01`, `gpu02` → `gpu:h200_nvl:1`
- `cgpu01` → `gpu:l4:1`

Users request via:
```bash
sbatch --gres=gpu:1               # any GPU
sbatch --gres=gpu:h200_nvl:1      # H200 specifically
sbatch --gres=gpu:l4:1            # L4 specifically
```

cgroup v2 enforces device isolation: `/dev/nvidia*` only visible to GPU-allocated jobs (other jobs on the same node can't accidentally see/use the GPU).

## 8. Per-job lifecycle

| Phase | What happens |
|---|---|
| Submit | `EnforcePartLimits=ALL` checks walltime; `AllowAccounts`/`AllowQos` checks authorization; association/limits/QoS checked via slurmdbd |
| Prolog | `/etc/slurm/prolog.d/20-enroot-scratch.sh` creates `/scratch/$USER/enroot/{data,runtime,tmp}` for Pyxis containers |
| Run | slurmstepd manages the job in a cgroup; jobacct samples every 30s; jobinfo records CPU·time, MaxRSS, etc. |
| Epilog | `/etc/slurm/epilog.d/` (currently empty — reserved for future cleanup hooks) |
| Mail | If `--mail-user=...` set, `slurm-mail.sh` wraps `bsd-mailx`, qualifies bare local-parts with `@insmed.com`, sends via Insmed's EOP relay |

## 9. Filesystems & where state lives

| Path | Purpose | Location |
|---|---|---|
| `/var/spool/slurmctld` | `StateSaveLocation` — job state checkpoints | cpu01 only (NOT NetApp; intentionally local for performance) |
| `/var/log/slurm/` | slurmctld + slurmd logs | per-node |
| `/etc/slurm/slurm.conf` | main config | every node (identical) |
| `/etc/slurm/cgroup.conf` | cgroup constraints | every node |
| `/etc/slurm/gres.conf` | GPU device mapping | GPU nodes only |
| `/etc/slurm/plugstack.conf` | SPANK plugins (Pyxis) | every node |
| `/etc/slurm/slurmdbd.conf` | DB credentials (vault-managed) | cpu01 only |
| `/etc/munge/munge.key` | shared cluster auth key (vault-managed) | every node, mode 0400 |

## 10. Day-to-day admin commands

```bash
sinfo                                  # node + partition health
squeue                                 # current queue (any state)
sacct                                  # job history (slurmdbd)
sacct -a -X --starttime=now-1day       # all users, last 24h, job-level only
scontrol show node <node>              # node state + last reason
scontrol show partition <partition>    # partition details
scontrol reconfigure                   # reload slurm.conf without restart (most keywords)
systemctl restart slurmctld            # full restart (needed for some keywords; auto-restart on crash)

# Custom helpers (installed by the slurm role to /usr/local/bin/):
cluster-status                         # free cores/mem/GPU per node + partition view
jobinfo <jobid>                        # pretty per-job summary
jobinfo last                           # last job submitted by $USER
purge-jobs <id>... [--confirm]         # slurmdbd MySQL DELETE (admin-only, cpu01)
slurm-allow show <part>                # show AllowAccounts on a partition
slurm-allow add <part> <acct>          # grant an account access to a partition (runtime)
slurm-allow remove <part> <acct>       # revoke
slurm-allow set <part> a1,a2,a3        # replace whole list
slurm-allow open <part>                # back to AllowAccounts=ALL
```

## 11. Notable design decisions

- **No preemption.** Once a job is running, nothing kills it but its walltime, OOM, scancel, or node failure. Predictable for users.
- **Account-gated access**, not group-gated. Partition restrictions via `AllowAccounts` (Slurm accounting tree), not `AllowGroups` (Linux). Cleaner ownership; aligns with billing.
- **No MPI.** `MaxNodes=1` everywhere — a job lives on one node. Multi-node parallelism would require explicit re-enabling + adding `pmix`/`pmi2`.
- **Slurm pinned to Ubuntu's 23.11.4.** No upgrade path planned — the deadlock + slurm-web limitations are absorbed via patches/workarounds rather than taking on the rackslab apt-repo / source-build maintenance burden.
- **slurmctld auto-restart.** systemd `Restart=on-failure` + 5s delay means the rare assoc_mgr deadlock recovers without human intervention.

## 12. Related docs

- [`Slurm-Cheatsheet.md`](Slurm-Cheatsheet.md) — user-facing command reference + cluster-specific gotchas
- [`Spack-Lmod-Guide.md`](Spack-Lmod-Guide.md) — module system + burden stack
- [`Progress.md`](Progress.md) — session log + every gotcha we've learned the hard way
- `~/ansible-dev/roles/slurm/` — Ansible source of truth; if it's not here, it didn't happen
- `~/ansible-dev/TODO.md` — outstanding work
