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
#   2. Stage remote install script, then run it under `sudo` via a
#      separate `ssh -t` session so sudo can prompt for the password
#      on a real terminal. Installs slurm-wlm, places munge.key +
#      slurm.conf, enables/restarts daemons. ONE sudo prompt per node.
#   3. Cross-host munge round-trip verification
#   4. slurmd-is-active check
# Final: sinfo from cpu01 — should show all 4 nodes registered.
#
# Password handling: you'll be prompted for the SSH user's sudo
# password on each GPU node once (during step 2). No NOPASSWD
# sudo required. The script does NOT cache passwords — every
# node prompts independently.
#
# Prerequisites on cpu01:
#   - 05_slurm.sh + 06_accounting.sh already run (slurmctld up)
#   - munge.key exists at /etc/munge/munge.key
#   - SSH key access to each GPU node as $SSH_USER
#   - Run as your normal user (NOT sudo). The script will sudo once on
#     cpu01 to read /etc/munge/munge.key, and once per GPU node during
#     remote install. Running under sudo breaks ssh-agent forwarding to
#     your user's key.
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

SSH_USER="${SSH_USER:-ntailor}"

# ── Sanity checks ───────────────────────────────────────────
sudo test -f /etc/munge/munge.key || { echo "[!] /etc/munge/munge.key missing on cpu01"; exit 1; }
[[ -f /etc/slurm/slurm.conf ]] || { echo "[!] /etc/slurm/slurm.conf missing on cpu01"; exit 1; }

# Don't run as root — we need the invoking user's SSH agent/keys to
# reach the GPU nodes. We sudo only for the one file that needs it.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "[!] Do not run this script with sudo."
  echo "    It needs your user's SSH key/agent to reach the GPU nodes as $SSH_USER."
  echo "    Run as your normal user. You'll be prompted once for sudo on $LOCAL_HOST"
  echo "    (to read /etc/munge/munge.key), and once per GPU node for sudo on the target."
  exit 1
fi

echo "[*] Reading /etc/munge/munge.key (sudo prompt on $LOCAL_HOST)..."
MUNGE_KEY_B64="$(sudo base64 -w0 /etc/munge/munge.key)"
SLURM_CONF_B64="$(base64 -w0 < /etc/slurm/slurm.conf)"

# Derive GPU hostnames from cpu01's prefix so customer naming flows through
PREFIX="${LOCAL_HOST%cpu01}"

# Default GPU node list (override with GPU_NODES="host1:ip1 host2:ip2 ...")
DEFAULT_GPU_NODES="${PREFIX}cgpu01:10.174.16.56 ${PREFIX}gpu01:10.174.16.57 ${PREFIX}gpu02:10.174.16.58"
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
  echo "[1/4] Testing SSH..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$IP" 'true' 2>/dev/null; then
    echo "  [FAIL] Cannot SSH to $SSH_USER@$IP"
    echo "         Confirm SSH key auth is set up."
    FAIL_NODES+=("$HOST")
    continue
  fi
  echo "  [OK]"

  # ── 2. Stage remote script, then run it under sudo ───────
  # Two ssh calls: (a) write the script body to a temp file on the node
  # (no tty needed; stdin is the heredoc), (b) execute it via `ssh -t`
  # so sudo has a real terminal to prompt for the password.
  echo "[2/4] Installing + configuring on $HOST (will prompt for sudo password)..."
  REMOTE_TMP="/tmp/register_gpu_nodes.$$.sh"

  if ! ssh "$SSH_USER@$IP" "cat > $REMOTE_TMP" <<'REMOTE'
set -euo pipefail
MUNGE_KEY_B64="$1"
SLURM_CONF_B64="$2"

# Install slurm-wlm (idempotent — apt no-op if already installed)
DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y slurm-wlm slurm-client

# Place munge.key
echo "$MUNGE_KEY_B64" | base64 -d > /etc/munge/munge.key
chown munge: /etc/munge/munge.key
chmod 400 /etc/munge/munge.key

# Place slurm.conf
mkdir -p /etc/slurm
echo "$SLURM_CONF_B64" | base64 -d > /etc/slurm/slurm.conf
chown slurm:slurm /etc/slurm/slurm.conf
chmod 644 /etc/slurm/slurm.conf

# Enable + restart daemons
systemctl enable --now munge
systemctl restart munge
sleep 2
systemctl enable --now slurmd
systemctl restart slurmd

echo "[remote-done] $(hostname -s)"
REMOTE
  then
    echo "  [FAIL] Could not stage remote script on $HOST"
    FAIL_NODES+=("$HOST")
    continue
  fi

  if ssh -t "$SSH_USER@$IP" "sudo bash $REMOTE_TMP '$MUNGE_KEY_B64' '$SLURM_CONF_B64'; rc=\$?; rm -f $REMOTE_TMP; exit \$rc"; then
    echo "  [OK]"
  else
    echo "  [FAIL] Setup failed on $HOST. Output above shows where."
    ssh "$SSH_USER@$IP" "rm -f $REMOTE_TMP" 2>/dev/null || true
    FAIL_NODES+=("$HOST")
    continue
  fi

  sleep 3

  # ── 3. Cross-host munge verification ─────────────────────
  echo "[3/4] Verifying cpu01 → $HOST munge round-trip..."
  if sudo munge -n 2>/dev/null | ssh "$SSH_USER@$IP" 'unmunge' >/dev/null 2>&1; then
    echo "  [OK] munge token from cpu01 decodes on $HOST"
  else
    echo "  [FAIL] munge round-trip failed — keys differ or munge not running"
    FAIL_NODES+=("$HOST")
    continue
  fi

  # ── 4. Verify slurmd is active ───────────────────────────
  echo "[4/4] Verifying slurmd is running on $HOST..."
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
