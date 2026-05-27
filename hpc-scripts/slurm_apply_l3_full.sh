#!/usr/bin/env bash
# ============================================================
# slurm_apply_l3_full.sh — Level 3
# ============================================================
# Pushes /etc/slurm/slurm.conf fleet-wide, restarts slurmd
# on every node, and restarts slurmctld on the controller.
#
# Use this for (slurm.conf changes that REQUIRE controller
# restart — scontrol reconfigure won't pick them up):
#   - AccountingStorageType / AccountingStorageHost
#   - AuthType, CryptoType
#   - ClusterName
#   - StateSaveLocation
#   - Adding or removing nodes (NodeName= entries)
#   - SwitchType
#   - Major plugin changes
#
# Disruption: slurmctld briefly down (~3-5 sec).
#   - Running jobs SURVIVE (slurmd + stepd continue).
#   - New submissions queue locally until controller back.
#   - sinfo / squeue / sbatch will fail briefly during restart.
#
# Usage: ./slurm_apply_l3_full.sh
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
SLURM_CONF=/etc/slurm/slurm.conf
[[ -f $SLURM_CONF ]] || { echo "[!] $SLURM_CONF missing"; exit 1; }

LOCAL_HASH=$(sha256sum $SLURM_CONF | awk '{print $1}')
echo "[*] Source:  $LOCAL_HOST:$SLURM_CONF"
echo "[*] Hash:    $LOCAL_HASH"
echo "[*] Targets: $REMOTE_NODES"
echo "[!] FULL RESTART — slurmctld will briefly be unavailable."
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

# ── 3. Restart slurmctld on the controller ────────────────
echo
echo "── restarting slurmctld on $LOCAL_HOST ──"
sudo systemctl restart slurmctld
sleep 5
echo "  [$(systemctl is-active slurmctld)]"

# ── 4. Verify ─────────────────────────────────────────────
echo
echo "── fleet state ──"
sinfo -lN
echo
echo "── recent slurmctld log ──"
sudo journalctl -u slurmctld --since "30 sec ago" --no-pager | tail -15
echo
echo "[OK] Level 3 apply complete."
