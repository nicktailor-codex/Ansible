#!/usr/bin/env bash
# ============================================================
# slurm_apply_l1_reconfigure.sh — Level 1
# ============================================================
# Pushes /etc/slurm/slurm.conf fleet-wide and runs `scontrol
# reconfigure` on the controller. No daemon restarts.
# Minimal disruption (~1 sec, no service blip).
#
# Use this for:
#   - Partition wall-time changes
#   - AllowAccounts / AllowGroups changes
#   - QoS settings
#   - Priority weights
#   - Pre-emption settings
#   - Most other slurm.conf tuning
#
# DON'T use this for (use l3 instead):
#   - AccountingStorageType, AuthType, ClusterName changes
#   - Adding or removing nodes
#   - Plugin path changes
#   - cgroup config changes
#
# Usage: ./slurm_apply_l1_reconfigure.sh
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

NODES="${NODES:-insiiukgpu01 insiiukgpu02 insiiukcgpu01}"
SLURM_CONF=/etc/slurm/slurm.conf
[[ -f $SLURM_CONF ]] || { echo "[!] $SLURM_CONF missing"; exit 1; }

LOCAL_HASH=$(sha256sum $SLURM_CONF | awk '{print $1}')
echo "[*] Source:  $LOCAL_HOST:$SLURM_CONF"
echo "[*] Hash:    $LOCAL_HASH"
echo "[*] Targets: $NODES"
echo

# ── 1. Push slurm.conf to each target ─────────────────────
for host in $NODES; do
  echo "── pushing slurm.conf → $host ──"
  if ! scp -q "$SLURM_CONF" "ntailor@$host:/tmp/slurm.conf.new"; then
    echo "  [FAIL] scp to $host failed"; exit 1
  fi
  # set -e in the remote shell: if `install` fails (sudo/disk/perms), the ssh
  # command returns non-zero and we catch it — instead of silently reading the
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

# ── 2. Reconfigure controller + slurmd ────────────────────
echo
echo "── scontrol reconfigure on $LOCAL_HOST ──"
sudo scontrol reconfigure
sleep 2

# ── 3. Verify ─────────────────────────────────────────────
echo
echo "── fleet state ──"
sinfo -lN
echo
echo "[OK] Level 1 apply complete."
