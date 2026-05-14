#!/usr/bin/env bash
# ============================================================
# 05 — SLURM single-controller cluster
# ============================================================
# Single SLURM cluster spanning all 4 nodes:
#   cpu01           → slurmctld + slurmd  (controller + CPU compute)
#   gpu01,gpu02,gpu03 → slurmd only        (compute nodes)
#
# Same /etc/slurm/slurm.conf written on every node (canonical).
# Per-node gres.conf is auto-generated on GPU nodes.
#
# Uses Ubuntu 24.04's slurm-wlm package (SLURM 23.11.4).
#
# Required env:
#   NODE_HOSTNAME      this host's short name (cpu01/gpu01/gpu02/gpu03)
# ============================================================
set -euo pipefail

: "${NODE_HOSTNAME:?set NODE_HOSTNAME}"

# ── Determine role ──────────────────────────────────────────
case "$NODE_HOSTNAME" in
  cpu01) ROLE="controller" ;;
  gpu01|gpu02|gpu03) ROLE="compute" ;;
  *)
    echo "[!] Unrecognized NODE_HOSTNAME='$NODE_HOSTNAME'."
    echo "    Expected one of: cpu01, gpu01, gpu02, gpu03"
    exit 1
    ;;
esac

echo "[*] Role: $ROLE on $NODE_HOSTNAME"

# ── GPU detection (for gres.conf only) ──────────────────────
HAS_GPU=false
GPU_COUNT=0
GPU_TYPE=""
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  HAS_GPU=true
  GPU_COUNT="$(nvidia-smi -L | wc -l)"

  # Detect type from model string for canonical-conf cross-check
  MODEL="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  case "$MODEL" in
    *H200*NVL*|*H200\ NVL*) GPU_TYPE="h200_nvl" ;;
    *H200*)                  GPU_TYPE="h200_nvl" ;;
    *L4*)                    GPU_TYPE="l4" ;;
    *)                        GPU_TYPE="$(echo "$MODEL" | tr '[:upper:] ' '[:lower:]_' | sed 's/[^a-z0-9_]//g')" ;;
  esac

  echo "[*] Detected $GPU_COUNT × $MODEL → gres type: $GPU_TYPE"

  # Cross-check against canonical config
  case "$NODE_HOSTNAME" in
    gpu01|gpu02)
      [[ "$GPU_TYPE" == "h200_nvl" ]] || \
        echo "[!] WARN: $NODE_HOSTNAME canonical type=h200_nvl, detected=$GPU_TYPE"
      [[ "$GPU_COUNT" == "1" ]] || \
        echo "[!] WARN: $NODE_HOSTNAME canonical GPU count=1, detected=$GPU_COUNT. Update slurm.conf if real count differs."
      ;;
    gpu03)
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
sudo tee /etc/slurm/slurm.conf >/dev/null <<'EOF'
# /etc/slurm/slurm.conf
# Research cluster - centralized SLURM controller on cpu01
# Canonical config; identical on all 4 nodes.

# === Cluster identity ===
ClusterName=research-cluster
SlurmctldHost=cpu01

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
AccountingStorageHost=cpu01
AccountingStorageEnforce=associations,limits,qos
AccountingStoreFlags=job_comment,job_script

# === MPI / topology ===
MpiDefault=none
TopologyPlugin=topology/none

# === Return-to-service after node failure ===
ReturnToService=2

# === Compute nodes ===
NodeName=cpu01 \
  NodeAddr=10.174.16.55 \
  CPUs=128 \
  Sockets=2 \
  CoresPerSocket=64 \
  ThreadsPerCore=1 \
  RealMemory=512000 \
  TmpDisk=8000000 \
  State=UNKNOWN

NodeName=gpu01 \
  NodeAddr=10.174.16.56 \
  CPUs=64 \
  Sockets=1 \
  CoresPerSocket=64 \
  ThreadsPerCore=1 \
  RealMemory=256000 \
  TmpDisk=8000000 \
  Gres=gpu:h200_nvl:1 \
  State=UNKNOWN

NodeName=gpu02 \
  NodeAddr=10.174.16.57 \
  CPUs=64 \
  Sockets=1 \
  CoresPerSocket=64 \
  ThreadsPerCore=1 \
  RealMemory=256000 \
  TmpDisk=8000000 \
  Gres=gpu:h200_nvl:1 \
  State=UNKNOWN

NodeName=gpu03 \
  NodeAddr=10.174.16.58 \
  CPUs=64 \
  Sockets=1 \
  CoresPerSocket=64 \
  ThreadsPerCore=1 \
  RealMemory=256000 \
  TmpDisk=8000000 \
  Gres=gpu:l4:1 \
  State=UNKNOWN

# === Partitions ===

# Heavy GPU work on H200 NVL (default partition)
PartitionName=gpu \
  Nodes=gpu01,gpu02 \
  Default=YES \
  MaxTime=48:00:00 \
  DefaultTime=04:00:00 \
  MaxNodes=1 \
  DefMemPerCPU=4096 \
  State=UP \
  AllowGroups=ALL \
  OverSubscribe=NO

# Lightweight GPU on L4 (inference, fine-tuning, dev)
PartitionName=gpu-small \
  Nodes=gpu03 \
  Default=NO \
  MaxTime=24:00:00 \
  DefaultTime=02:00:00 \
  MaxNodes=1 \
  DefMemPerCPU=4096 \
  State=UP \
  AllowGroups=ALL \
  OverSubscribe=NO

# CPU-only, high-memory (genetics, big-memory workloads)
PartitionName=cpu \
  Nodes=cpu01 \
  Default=NO \
  MaxTime=72:00:00 \
  DefaultTime=08:00:00 \
  MaxNodes=1 \
  DefMemPerCPU=4096 \
  State=UP \
  AllowGroups=ALL \
  OverSubscribe=NO

# Interactive sessions (Jupyter, dev work)
PartitionName=interactive \
  Nodes=gpu03,cpu01 \
  Default=NO \
  MaxTime=08:00:00 \
  DefaultTime=02:00:00 \
  MaxNodes=1 \
  DefMemPerCPU=4096 \
  PriorityTier=10 \
  State=UP \
  AllowGroups=ALL \
  OverSubscribe=NO

# Long-running pipeline orchestrators (Snakemake/Nextflow controllers)
PartitionName=pipeline \
  Nodes=cpu01 \
  Default=NO \
  MaxTime=168:00:00 \
  DefaultTime=24:00:00 \
  MaxNodes=1 \
  DefMemPerCPU=4096 \
  PriorityTier=1 \
  State=UP \
  AllowGroups=ALL \
  OverSubscribe=NO

# Catch-all (lightweight jobs, opportunistic use)
PartitionName=all \
  Nodes=ALL \
  Default=NO \
  MaxTime=24:00:00 \
  DefaultTime=04:00:00 \
  MaxNodes=1 \
  DefMemPerCPU=4096 \
  PriorityTier=1 \
  State=UP \
  AllowGroups=ALL \
  OverSubscribe=NO
EOF

# ── cgroup.conf (identical on every node) ───────────────────
# CgroupPlugin=autodetect       Ubuntu 24.04 → cgroup v2 unified hierarchy.
# ConstrainCores=yes            Pin job processes to allocated CPUs only.
# ConstrainRAMSpace=yes         Hard memory limit. Job killed cleanly via OOM
#                               if it exceeds requested --mem.
# ConstrainDevices=yes          GPU isolation — only allocated nvidia devices
#                               are visible to the job. Requires PrologFlags
#                               with Contain (set in slurm.conf).
# ConstrainSwapSpace=no         Intentional — no swap on these nodes by design.
#                               Do not flip without re-evaluating swap policy.
sudo tee /etc/slurm/cgroup.conf >/dev/null <<'EOF'
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
ConstrainSwapSpace=no
EOF

# ── gres.conf (only on GPU nodes) ───────────────────────────
if [[ "$HAS_GPU" == "true" ]]; then
  # Generate one File= line per detected GPU device
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
# Per-job scratch dir per Setup Plan
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
# All nodes run slurmd. Only cpu01 runs slurmctld (started by 06).
echo "[*] Enabling and starting slurmd"
sudo systemctl enable slurmd
sudo systemctl restart slurmd
sleep 2

if [[ "$ROLE" == "controller" ]]; then
  # Don't start slurmctld yet — slurmdbd has to come up first (06).
  echo "[*] Controller role: slurmctld will be started by 06_accounting.sh"
  sudo systemctl enable slurmctld
fi

echo
echo "── slurmd status ────────────────────────────────────────"
sudo systemctl --no-pager status slurmd | head -12 || true

echo
echo "[OK] SLURM configured on $NODE_HOSTNAME (role: $ROLE)."
echo
if [[ "$ROLE" == "controller" ]]; then
  echo "Next: 06_accounting.sh on this node (cpu01) — starts slurmdbd + slurmctld + bootstraps accounting."
  echo "After 06 finishes here, on each compute node:"
  echo "  - 05 has already been run there → slurmd is running"
  echo "  - Just verify with: sinfo (from cpu01) — should show all 4 nodes"
else
  echo "Compute role: slurmd is running. Waiting for cpu01's slurmctld to come up."
  echo "Once cpu01 runs 06_accounting.sh, this node will register with the cluster."
  echo "Verify from cpu01: sinfo (should show $NODE_HOSTNAME)"
fi
