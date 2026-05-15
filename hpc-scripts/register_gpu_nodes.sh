#!/usr/bin/env bash
# ============================================================
# register_gpu_nodes.sh — Sync auth + config across GPU nodes
# ============================================================
# Runs FROM cpu01. Independent script — does not invoke any
# other script. Installs slurm-wlm (which includes slurmd +
# munge as a dependency) on each GPU node, syncs auth + config
# from cpu01, and starts the daemons so the GPU nodes register
# with cpu01's slurmctld.
#
# Architecture: GPU nodes are compute nodes. SLURM dispatches
# GPU jobs to them via per-node partitions (gpu01, gpu02,
# gpu03) defined in cpu01's canonical slurm.conf. Users select
# the target node by partition: `sbatch -p gpu02 myjob.sh`.
#
# For each GPU node:
#   1. SSH connectivity check
#   2. Install slurm-wlm (pulls slurmd + munge as deps; idempotent)
#   3. Push /etc/munge/munge.key from cpu01 (correct owner + perms)
#   4. Push /etc/slurm/slurm.conf from cpu01 (canonical config)
#   5. Restart munge + slurmd on the target
#   6. Verify cross-host munge round-trip
#   7. Verify slurmd is active
# Final: sinfo from cpu01 — should show all 4 nodes registered.
#
# Prerequisites on cpu01:
#   - 05_slurm.sh + 06_accounting.sh already run (slurmctld up)
#   - munge.key exists at /etc/munge/munge.key
#   - SSH key access to each GPU node as $SSH_USER
#   - $SSH_USER has passwordless sudo on each GPU node
#
# Prerequisites on each GPU node:
#   - OS installed + NVIDIA driver installed (01_os_base, 03_nvidia)
#   - Hostname set correctly (so slurmd reports the right NodeName)
#   - Internet access (or local apt mirror) to install slurm-wlm
#
# Env vars:
#   SSH_USER     default: ntail (override if you SSH as a different user)
#   GPU_NODES    default: derived from cpu01's hostname prefix +
#                IP suffixes .56/.57/.58
# ============================================================
set -euo pipefail

# ── Refuse on non-cpu01 ─────────────────────────────────────
LOCAL_HOST="$(hostname -s)"
case "$LOCAL_HOST" in
  *cpu01) ;;
  *)
    echo "[!] register_gpu_nodes.sh must be run from the SLURM controller (*cpu01)."
    echo "    Current host: $LOCAL_HOST"
    exit 1
    ;;
esac

SSH_USER="${SSH_USER:-ntail}"

# ── Sanity checks ───────────────────────────────────────────
[[ -f /etc/munge/munge.key ]] || { echo "[!] /etc/munge/munge.key missing on cpu01"; exit 1; }
[[ -f /etc/slurm/slurm.conf ]] || { echo "[!] /etc/slurm/slurm.conf missing on cpu01"; exit 1; }

# Derive GPU hostnames from cpu01's prefix so customer naming flows through
PREFIX="${LOCAL_HOST%cpu01}"

# Default GPU node list (override with GPU_NODES="host1:ip1 host2:ip2 ...")
DEFAULT_GPU_NODES="${PREFIX}gpu01:10.174.16.56 ${PREFIX}gpu02:10.174.16.57 ${PREFIX}gpu03:10.174.16.58"
GPU_NODES="${GPU_NODES:-$DEFAULT_GPU_NODES}"

echo "[*] Controller:    $LOCAL_HOST"
echo "[*] SSH user:      $SSH_USER"
echo "[*] Target nodes:"
for entry in $GPU_NODES; do echo "      $entry"; done
echo

FAIL_NODES=()

# ── Loop over each GPU node ─────────────────────────────────
for entry in $GPU_NODES; do
  HOST="${entry%%:*}"
  IP="${entry##*:}"

  echo "═══════════════════════════════════════════════════════"
  echo " $HOST ($IP)"
  echo "═══════════════════════════════════════════════════════"

  # ── 1. SSH connectivity ──────────────────────────────────
  echo "[1/7] Testing SSH..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$IP" 'true' 2>/dev/null; then
    echo "  [FAIL] Cannot SSH to $SSH_USER@$IP"
    echo "         Confirm SSH key auth is set up + sudo NOPASSWD."
    FAIL_NODES+=("$HOST")
    continue
  fi
  echo "  [OK]"

  # ── 2. Install slurm-wlm (includes slurmd, pulls munge as dep) ──
  echo "[2/7] Installing slurm-wlm on $HOST (no-op if already installed)..."
  if ssh "$SSH_USER@$IP" 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null && \
                          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y slurm-wlm slurm-client'; then
    echo "  [OK]"
  else
    echo "  [FAIL] apt install slurm-wlm failed on $HOST"
    FAIL_NODES+=("$HOST")
    continue
  fi

  # ── 3. Push munge.key from cpu01 ─────────────────────────
  echo "[3/7] Pushing /etc/munge/munge.key..."
  if sudo cat /etc/munge/munge.key | \
       ssh "$SSH_USER@$IP" 'sudo tee /etc/munge/munge.key >/dev/null && \
                            sudo chown munge: /etc/munge/munge.key && \
                            sudo chmod 400 /etc/munge/munge.key'; then
    echo "  [OK]"
  else
    echo "  [FAIL]"
    FAIL_NODES+=("$HOST")
    continue
  fi

  # ── 4. Push slurm.conf from cpu01 (canonical) ────────────
  echo "[4/7] Pushing /etc/slurm/slurm.conf..."
  if sudo cat /etc/slurm/slurm.conf | \
       ssh "$SSH_USER@$IP" 'sudo mkdir -p /etc/slurm && \
                            sudo tee /etc/slurm/slurm.conf >/dev/null && \
                            sudo chown slurm:slurm /etc/slurm/slurm.conf && \
                            sudo chmod 644 /etc/slurm/slurm.conf'; then
    echo "  [OK]"
  else
    echo "  [FAIL]"
    FAIL_NODES+=("$HOST")
    continue
  fi

  # ── 5. Enable + restart munge + slurmd ───────────────────
  echo "[5/7] Enabling + restarting munge + slurmd on $HOST..."
  ssh "$SSH_USER@$IP" 'sudo systemctl enable --now munge && \
                       sudo systemctl restart munge && \
                       sleep 2 && \
                       sudo systemctl enable --now slurmd && \
                       sudo systemctl restart slurmd'
  sleep 3

  # ── 6. Cross-host munge verification ─────────────────────
  echo "[6/7] Verifying cpu01 → $HOST munge round-trip..."
  if munge -n 2>/dev/null | ssh "$SSH_USER@$IP" 'unmunge' >/dev/null 2>&1; then
    echo "  [OK] munge token from cpu01 decodes on $HOST"
  else
    echo "  [FAIL] munge round-trip failed — keys differ or munge not running"
    FAIL_NODES+=("$HOST")
    continue
  fi

  # ── 7. Verify slurmd is active ───────────────────────────
  echo "[7/7] Verifying slurmd is running on $HOST..."
  if ssh "$SSH_USER@$IP" 'systemctl is-active --quiet slurmd'; then
    echo "  [OK] slurmd active on $HOST"
  else
    echo "  [FAIL] slurmd not active. SSH in and check:"
    echo "         sudo systemctl status slurmd"
    echo "         sudo journalctl -u slurmd -n 50"
    FAIL_NODES+=("$HOST")
  fi
  echo
done

# ── Final cluster check from cpu01 ──────────────────────────
echo "═══════════════════════════════════════════════════════"
echo " Final cluster state (from $LOCAL_HOST)"
echo "═══════════════════════════════════════════════════════"
sleep 5    # give slurmd a moment to register with slurmctld
echo
sinfo

echo
scontrol show nodes 2>&1 | grep -E "^NodeName|State=" || true

# ── Summary ─────────────────────────────────────────────────
echo
if [[ ${#FAIL_NODES[@]} -eq 0 ]]; then
  echo "[OK] All GPU nodes registered."
  echo
  echo "If any node still shows down* or unknown in sinfo, give it 30s,"
  echo "then check:  scontrol show node <host>"
else
  echo "[FAIL] These nodes had issues: ${FAIL_NODES[*]}"
  echo
  echo "For each failed node, SSH in and check:"
  echo "  - munge:  sudo systemctl status munge && munge -n | unmunge"
  echo "  - slurmd: sudo systemctl status slurmd"
  echo "           sudo journalctl -u slurmd -n 50"
  exit 1
fi
