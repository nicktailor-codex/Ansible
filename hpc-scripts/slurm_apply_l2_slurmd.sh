#!/usr/bin/env bash
# ============================================================
# slurm_apply_l2_slurmd.sh — Level 2
# ============================================================
# Pushes /etc/slurm/slurm.conf fleet-wide, restarts slurmd
# on EVERY node (including cpu01), and runs scontrol
# reconfigure on the controller.
#
# Use this for:
#   - cgroup config changes (cgroup.conf, ProctrackType,
#     TaskPlugin, ConstrainRAMSpace, etc.)
#   - Plugin path changes (SchedulerType, SelectType,
#     ProctrackType)
#   - GresTypes additions
#   - Anything that slurmd reads at startup and won't
#     pick up via reconfigure alone
#
# DON'T use this for (use l3 instead):
#   - AccountingStorageType, AuthType, ClusterName changes
#   - Adding or removing nodes
#   - StateSaveLocation changes
#
# Disruption: brief slurmd hiccup per node. Running jobs
# survive (slurmstepd is separate). New job dispatch pauses
# for ~2-3 seconds per node restart.
#
# Usage: ./slurm_apply_l2_slurmd.sh
# Runs from: cpu01 only, as ntailor (NOPASSWD sudo expected).
# SSH: uses ~/.ssh/config cluster-ops key.
# ============================================================
set -euo pipefail

LOCAL_HOST="$(hostname -s)"
case "$LOCAL_HOST" in
  *cpu01) ;;
  *)
    echo "[!] Must run from the Slurm controller (*cpu01)."
    echo "    Current host: $LOCAL_HOST"
    exit 1
    ;;
esac

REMOTE_NODES="${REMOTE_NODES:-insiiukgpu01 insiiukgpu02 insiiukcgpu01}"
ALL_NODES="$LOCAL_HOST $REMOTE_NODES"
SLURM_CONF=/etc/slurm/slurm.conf
[[ -f $SLURM_CONF ]] || { echo "[!] $SLURM_CONF missing"; exit 1; }

LOCAL_HASH=$(sha256sum $SLURM_CONF | awk '{print $1}')
echo "[*] Source:  $LOCAL_HOST:$SLURM_CONF"
echo "[*] Hash:    $LOCAL_HASH"
echo "[*] Targets: $REMOTE_NODES"
echo

# ── 1. Push slurm.conf to remote nodes ────────────────────
for host in $REMOTE_NODES; do
  echo "── pushing slurm.conf → $host ──"
  if ! scp -q "$SLURM_CONF" "ntailor@$host:/tmp/slurm.conf.new"; then
    echo "  [FAIL] scp to $host failed"; exit 1
  fi
  # set -e in the remote: if `install` fails (sudo/disk/perms/missing source),
  # the ssh returns non-zero and we catch it — instead of silently reading the
  # OLD file's hash and false-passing when content happens to match.
  REMOTE_OUT=$(ssh "ntailor@$host" "set -e
    sudo install -o slurm -g slurm -m 644 /tmp/slurm.conf.new /etc/slurm/slurm.conf
    rm -f /tmp/slurm.conf.new
    sha256sum /etc/slurm/slurm.conf | awk '{print \$1}'
  ") || { echo "  [FAIL] remote install failed on $host (check sudo / disk / perms)"; exit 1; }
  REMOTE_HASH=$(echo "$REMOTE_OUT" | tail -1)
  if [[ "$LOCAL_HASH" == "$REMOTE_HASH" ]]; then
    echo "  [OK] hash match"
  else
    echo "  [FAIL] hash mismatch on $host"
    echo "         local:  $LOCAL_HASH"
    echo "         remote: $REMOTE_HASH"
    exit 1
  fi
done

# ── 2. Restart slurmd on every node (including cpu01) ─────
echo
echo "── restarting slurmd on cpu01 (local) ──"
sudo systemctl restart slurmd
sleep 2
echo "  [$(systemctl is-active slurmd)]"

for host in $REMOTE_NODES; do
  echo "── restarting slurmd on $host ──"
  ssh "ntailor@$host" "sudo systemctl restart slurmd; sleep 2; systemctl is-active slurmd"
done

# ── 3. Reconfigure controller ─────────────────────────────
echo
echo "── scontrol reconfigure on $LOCAL_HOST ──"
sudo scontrol reconfigure
sleep 3

# ── 4. Verify ─────────────────────────────────────────────
echo
echo "── fleet state ──"
sinfo -lN
echo
echo "[OK] Level 2 apply complete."
