#!/usr/bin/env bash
# ============================================================
# 05 — SLURM cluster (all 4 nodes, per-node partitions)
# ============================================================
# Single SLURM cluster spanning all 4 nodes. Everything goes
# through SLURM — users pick the node they want by selecting
# the matching partition.
#
#   cpu01           → slurmctld + slurmd  (controller + cpu partition)
#   gpu01/gpu02/gpu03 → slurmd only       (per-node gpu partitions)
#
# Partition design — one partition per node so users target
# explicitly:
#   cpu        → cpu01            (default for CPU work)
#   gpu01      → gpu01            (H200 NVL)
#   gpu02      → gpu02            (H200 NVL)
#   gpu03      → gpu03            (L4)
#   pipeline   → cpu01            (long-running orchestrators)
#   interactive → cpu01,gpu03     (short walltime, high priority)
#
# MaxNodes=1 everywhere — single-node jobs only (no IB fabric,
# workloads are single-node by nature).
#
# Same /etc/slurm/slurm.conf written on every node (canonical).
# Per-node gres.conf is auto-generated on GPU nodes.
#
# Uses Ubuntu 24.04's slurm-wlm package (SLURM 23.11.4).
#
# Hostname auto-detected from `hostname -s`. Suffix-match handles
# customer prefixes (e.g., insiiukcpu01).
# ============================================================
set -euo pipefail

NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname -s)}"
echo "[*] Hostname: $NODE_HOSTNAME"

# ── Determine role + derive cluster hostname prefix ─────────
case "$NODE_HOSTNAME" in
  *cpu01) ROLE="controller"; NODE_SUFFIX="cpu01" ;;
  *gpu01) ROLE="compute";    NODE_SUFFIX="gpu01" ;;
  *gpu02) ROLE="compute";    NODE_SUFFIX="gpu02" ;;
  *gpu03) ROLE="compute";    NODE_SUFFIX="gpu03" ;;
  *)
    echo "[!] Unrecognized NODE_HOSTNAME='$NODE_HOSTNAME'."
    echo "    Hostname must end in cpu01, gpu01, gpu02, or gpu03."
    exit 1
    ;;
esac

# Derive prefix and build the canonical 4-node hostname set
HOSTNAME_PREFIX="${NODE_HOSTNAME%$NODE_SUFFIX}"
CPU01_HOST="${HOSTNAME_PREFIX}cpu01"
GPU01_HOST="${HOSTNAME_PREFIX}gpu01"
GPU02_HOST="${HOSTNAME_PREFIX}gpu02"
GPU03_HOST="${HOSTNAME_PREFIX}gpu03"

echo "[*] Role: $ROLE on $NODE_HOSTNAME"
echo "[*] Hostname prefix: '${HOSTNAME_PREFIX:-<none>}'"
echo "[*] Cluster nodes: $CPU01_HOST, $GPU01_HOST, $GPU02_HOST, $GPU03_HOST"

# ── GPU detection (for gres.conf only) ──────────────────────
HAS_GPU=false
GPU_COUNT=0
GPU_TYPE=""
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  HAS_GPU=true
  GPU_COUNT="$(nvidia-smi -L | wc -l)"
  MODEL="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  case "$MODEL" in
    *H200*NVL*|*H200\ NVL*) GPU_TYPE="h200_nvl" ;;
    *H200*)                  GPU_TYPE="h200_nvl" ;;
    *L4*)                    GPU_TYPE="l4" ;;
    *)                        GPU_TYPE="$(echo "$MODEL" | tr '[:upper:] ' '[:lower:]_' | sed 's/[^a-z0-9_]//g')" ;;
  esac
  echo "[*] Detected $GPU_COUNT × $MODEL → gres type: $GPU_TYPE"

  # Cross-check against canonical slurm.conf NodeName entries
  case "$NODE_HOSTNAME" in
    *gpu01|*gpu02)
      [[ "$GPU_TYPE" == "h200_nvl" ]] || \
        echo "[!] WARN: $NODE_HOSTNAME canonical type=h200_nvl, detected=$GPU_TYPE"
      [[ "$GPU_COUNT" == "1" ]] || \
        echo "[!] WARN: $NODE_HOSTNAME canonical GPU count=1, detected=$GPU_COUNT. Update slurm.conf if real count differs."
      ;;
    *gpu03)
      [[ "$GPU_TYPE" == "l4" ]] || \
        echo "[!] WARN: $NODE_HOSTNAME canonical type=l4, detected=$GPU_TYPE"
      [[ "$GPU_COUNT" == "1" ]] || \
        echo "[!] WARN: $NODE_HOSTNAME canonical GPU count=1, detected=$GPU_COUNT. Update slurm.conf if real count differs."
      ;;
  esac
fi

# ── Install ─────────────────────────────────────────────────
echo "[*] Installing slurm-wlm + clients"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  slurm-wlm slurm-client

# ── Directories ─────────────────────────────────────────────
sudo mkdir -p /etc/slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chmod 755 /var/spool/slurmctld /var/spool/slurmd

# ── Canonical slurm.conf (identical on every node) ──────────
echo "[*] Writing /etc/slurm/slurm.conf"
sudo tee /etc/slurm/slurm.conf >/dev/null <<EOF
# /etc/slurm/slurm.conf
# Research cluster — centralized SLURM controller on $CPU01_HOST.
# Canonical config; identical on all 4 nodes.
# Per-node partitions: users target a specific node via partition.

# === Cluster identity ===
ClusterName=research-cluster
SlurmctldHost=$CPU01_HOST

# === Authentication ===
AuthType=auth/munge
CryptoType=crypto/munge

# === User and paths ===
SlurmUser=slurm
SlurmdUser=root
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld

# === Logging ===
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info

# === Timers ===
SlurmctldTimeout=300
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# === Scheduling ===
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory

# === Resource enforcement (cgroup v2) ===
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup
PrologFlags=Alloc,Contain
JobAcctGatherType=jobacct_gather/cgroup
JobAcctGatherFrequency=30

# === Prolog / epilog (per-job scratch) ===
Prolog=/etc/slurm/prolog.d/*
Epilog=/etc/slurm/epilog.d/*

# === GPU resources ===
GresTypes=gpu

# === Job completion and accounting ===
JobCompType=jobcomp/none
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=$CPU01_HOST
AccountingStorageEnforce=associations,limits,qos
AccountingStoreFlags=job_comment,job_script

# === MPI / topology ===
MpiDefault=none
TopologyPlugin=topology/none

# === Return-to-service after node failure ===
ReturnToService=2

# === Compute nodes ===
NodeName=$CPU01_HOST \\
  NodeAddr=10.174.16.55 \\
  CPUs=128 \\
  Sockets=2 \\
  CoresPerSocket=64 \\
  ThreadsPerCore=1 \\
  RealMemory=512000 \\
  TmpDisk=8000000 \\
  State=UNKNOWN

NodeName=$GPU01_HOST \\
  NodeAddr=10.174.16.56 \\
  CPUs=64 \\
  Sockets=1 \\
  CoresPerSocket=64 \\
  ThreadsPerCore=1 \\
  RealMemory=256000 \\
  TmpDisk=8000000 \\
  Gres=gpu:h200_nvl:1 \\
  State=UNKNOWN

NodeName=$GPU02_HOST \\
  NodeAddr=10.174.16.57 \\
  CPUs=64 \\
  Sockets=1 \\
  CoresPerSocket=64 \\
  ThreadsPerCore=1 \\
  RealMemory=256000 \\
  TmpDisk=8000000 \\
  Gres=gpu:h200_nvl:1 \\
  State=UNKNOWN

NodeName=$GPU03_HOST \\
  NodeAddr=10.174.16.58 \\
  CPUs=64 \\
  Sockets=1 \\
  CoresPerSocket=64 \\
  ThreadsPerCore=1 \\
  RealMemory=256000 \\
  TmpDisk=8000000 \\
  Gres=gpu:l4:1 \\
  State=UNKNOWN

# === Partitions — one per node so users target explicitly ===

# Default CPU partition
PartitionName=cpu \\
  Nodes=$CPU01_HOST \\
  Default=YES \\
  MaxTime=72:00:00 \\
  DefaultTime=08:00:00 \\
  MaxNodes=1 \\
  DefMemPerCPU=4096 \\
  State=UP \\
  AllowGroups=ALL \\
  OverSubscribe=NO

# H200 NVL — gpu01 (first H200 node)
PartitionName=gpu01 \\
  Nodes=$GPU01_HOST \\
  Default=NO \\
  MaxTime=48:00:00 \\
  DefaultTime=04:00:00 \\
  MaxNodes=1 \\
  DefMemPerCPU=4096 \\
  State=UP \\
  AllowGroups=ALL \\
  OverSubscribe=NO

# H200 NVL — gpu02 (second H200 node)
PartitionName=gpu02 \\
  Nodes=$GPU02_HOST \\
  Default=NO \\
  MaxTime=48:00:00 \\
  DefaultTime=04:00:00 \\
  MaxNodes=1 \\
  DefMemPerCPU=4096 \\
  State=UP \\
  AllowGroups=ALL \\
  OverSubscribe=NO

# L4 — gpu03 (lightweight GPU node)
PartitionName=gpu03 \\
  Nodes=$GPU03_HOST \\
  Default=NO \\
  MaxTime=24:00:00 \\
  DefaultTime=02:00:00 \\
  MaxNodes=1 \\
  DefMemPerCPU=4096 \\
  State=UP \\
  AllowGroups=ALL \\
  OverSubscribe=NO

# Interactive — short walltime, high priority, on cpu01 + gpu03
PartitionName=interactive \\
  Nodes=$CPU01_HOST,$GPU03_HOST \\
  Default=NO \\
  MaxTime=08:00:00 \\
  DefaultTime=02:00:00 \\
  MaxNodes=1 \\
  DefMemPerCPU=4096 \\
  PriorityTier=10 \\
  State=UP \\
  AllowGroups=ALL \\
  OverSubscribe=NO

# Pipeline orchestrators — long-running Snakemake/Nextflow controllers on cpu01
PartitionName=pipeline \\
  Nodes=$CPU01_HOST \\
  Default=NO \\
  MaxTime=168:00:00 \\
  DefaultTime=24:00:00 \\
  MaxNodes=1 \\
  DefMemPerCPU=4096 \\
  PriorityTier=1 \\
  State=UP \\
  AllowGroups=ALL \\
  OverSubscribe=NO
EOF

# ── cgroup.conf ─────────────────────────────────────────────
# CgroupPlugin=autodetect       Ubuntu 24.04 → cgroup v2 unified hierarchy.
# ConstrainCores=yes            Pin job processes to allocated CPUs only.
# ConstrainRAMSpace=yes         Hard memory limit. Job killed cleanly via OOM
#                               if it exceeds requested --mem.
# ConstrainDevices=yes          GPU isolation — only allocated nvidia devices
#                               visible to the job.
# ConstrainSwapSpace=no         No swap on these nodes by design.
sudo tee /etc/slurm/cgroup.conf >/dev/null <<'EOF'
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
ConstrainSwapSpace=no
EOF

# ── gres.conf (only on GPU nodes) ───────────────────────────
if [[ "$HAS_GPU" == "true" ]]; then
  GRES_LINES=""
  for i in $(seq 0 $((GPU_COUNT - 1))); do
    GRES_LINES+="NodeName=$NODE_HOSTNAME Name=gpu Type=$GPU_TYPE File=/dev/nvidia$i"$'\n'
  done

  sudo tee /etc/slurm/gres.conf >/dev/null <<EOF
# Auto-detected on $NODE_HOSTNAME: $GPU_COUNT × $GPU_TYPE
$GRES_LINES
EOF
fi

# ── Prolog / epilog scripts ─────────────────────────────────
sudo mkdir -p /etc/slurm/prolog.d /etc/slurm/epilog.d

sudo tee /etc/slurm/prolog.d/10-job-scratch.sh >/dev/null <<'EOF'
#!/bin/bash
JOB_SCRATCH=/scratch/jobs/$SLURM_JOB_ID
mkdir -p "$JOB_SCRATCH"
chown "$SLURM_JOB_USER:" "$JOB_SCRATCH"
chmod 700 "$JOB_SCRATCH"
EOF
sudo chmod +x /etc/slurm/prolog.d/10-job-scratch.sh

sudo tee /etc/slurm/epilog.d/90-job-scratch.sh >/dev/null <<'EOF'
#!/bin/bash
JOB_SCRATCH=/scratch/jobs/$SLURM_JOB_ID
[ -d "$JOB_SCRATCH" ] && rm -rf "$JOB_SCRATCH"
EOF
sudo chmod +x /etc/slurm/epilog.d/90-job-scratch.sh

# ── Permissions ─────────────────────────────────────────────
sudo chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
[[ -f /etc/slurm/gres.conf ]] && sudo chown slurm:slurm /etc/slurm/gres.conf

# ── Daemons ─────────────────────────────────────────────────
# All nodes run slurmd. Only cpu01 also enables slurmctld
# (started by 06_accounting.sh after slurmdbd is up).
echo "[*] Enabling and starting slurmd"
sudo systemctl enable slurmd
sudo systemctl restart slurmd
sleep 2

if [[ "$ROLE" == "controller" ]]; then
  echo "[*] Controller role: enabling slurmctld (started by 06_accounting.sh)"
  sudo systemctl enable slurmctld
fi

echo
echo "── slurmd status ────────────────────────────────────────"
sudo systemctl --no-pager status slurmd | head -12 || true

echo
echo "[OK] SLURM configured on $NODE_HOSTNAME (role: $ROLE)."
echo
if [[ "$ROLE" == "controller" ]]; then
  cat <<HERE
Next steps:
  1. On this node:   sudo SLURMDB_PASSWORD='real-pw' ./06_accounting.sh
  2. On each gpu node (gpu01/gpu02/gpu03):
       a. scp munge.key and slurm.conf from this node (or rely on 04_munge.sh
          having distributed munge.key, and re-running 05_slurm.sh on each
          gpu node — it generates the same canonical slurm.conf)
       b. sudo ./05_slurm.sh
  3. From this node: sinfo  (should show all 4 nodes, 6 partitions)
HERE
else
  cat <<HERE
Compute role on $NODE_HOSTNAME. slurmd running, waiting for cpu01's slurmctld
to come up. Once cpu01 runs 06_accounting.sh, this node will register.

Verify from cpu01:  sinfo   (should show $NODE_HOSTNAME)
HERE
fi
