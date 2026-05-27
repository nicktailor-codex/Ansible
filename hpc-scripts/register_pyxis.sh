#!/usr/bin/env bash
# ============================================================
# register_pyxis.sh — Install Pyxis + Enroot fleet-wide
# ============================================================
# Runs FROM cpu01. Installs Enroot (.deb) on each target node,
# places the prebuilt spank_pyxis.so + plugstack.conf + enroot.conf,
# pre-stages /scratch/cluster-software/enroot-cache, and restarts
# slurmd so Slurm picks up the SPANK plugin.
#
# Models after register_gpu_nodes.sh — one sudo prompt per node,
# no NOPASSWD required. The user's SSH agent reaches the nodes.
#
# Prerequisites on cpu01:
#   - Pyxis already built: /opt/build/pyxis/spank_pyxis.so
#   - /etc/enroot/enroot.conf already in place
#   - SSH key access to each target as $SSH_USER
#   - Run as your normal user (NOT sudo)
#
# Prerequisites on each target node:
#   - OS installed, slurm-wlm + slurmd already running (i.e.
#     register_gpu_nodes.sh has been run successfully first)
#   - Internet access (or local mirror) to GitHub for Enroot .deb
#
# Env vars:
#   SSH_USER     default: ntailor
#   NODES        default: cgpu01:.56  gpu01:.57  gpu02:.58
#   ENROOT_VER   default: 3.5.0
#   PYXIS_SO     default: /opt/build/pyxis/spank_pyxis.so
# ============================================================
set -euo pipefail

# ── Refuse on non-cpu01 ─────────────────────────────────────
LOCAL_HOST="$(hostname -s)"
case "$LOCAL_HOST" in
  *cpu01) ;;
  *)
    echo "[!] register_pyxis.sh must be run from the SLURM controller (*cpu01)."
    echo "    Current host: $LOCAL_HOST"
    exit 1
    ;;
esac

SSH_USER="${SSH_USER:-ntailor}"
ENROOT_VER="${ENROOT_VER:-3.5.0}"
PYXIS_SO="${PYXIS_SO:-/opt/build/pyxis/spank_pyxis.so}"

# Don't run as root — we need the invoking user's SSH agent/keys
if [[ "$(id -u)" -eq 0 ]]; then
  echo "[!] Do not run this script with sudo."
  echo "    It needs your user's SSH key/agent to reach the nodes as $SSH_USER."
  exit 1
fi

# ── Sanity checks on cpu01 ──────────────────────────────────
[[ -f "$PYXIS_SO" ]] || { echo "[!] $PYXIS_SO missing — build pyxis first"; exit 1; }
[[ -f /etc/enroot/enroot.conf ]] || { echo "[!] /etc/enroot/enroot.conf missing on cpu01"; exit 1; }
[[ -f /etc/slurm/plugstack.conf ]] || { echo "[!] /etc/slurm/plugstack.conf missing on cpu01"; exit 1; }

# Pre-encode the binary + configs for inline transport
PYXIS_B64="$(base64 -w0 "$PYXIS_SO")"
ENROOT_CONF_B64="$(base64 -w0 /etc/enroot/enroot.conf)"
PLUGSTACK_B64="$(base64 -w0 /etc/slurm/plugstack.conf)"

# Derive node prefix from cpu01
PREFIX="${LOCAL_HOST%cpu01}"
DEFAULT_NODES="${PREFIX}cgpu01:10.174.16.56 ${PREFIX}gpu01:10.174.16.57 ${PREFIX}gpu02:10.174.16.58"
NODES="${NODES:-$DEFAULT_NODES}"

echo "[*] Controller:    $LOCAL_HOST"
echo "[*] SSH user:      $SSH_USER"
echo "[*] Enroot ver:    $ENROOT_VER"
echo "[*] Pyxis .so:     $PYXIS_SO ($(wc -c < "$PYXIS_SO") bytes)"
echo "[*] Target nodes:"
for entry in $NODES; do echo "      $entry"; done
echo

FAIL_NODES=()

# ── Loop over each target node ──────────────────────────────
for entry in $NODES; do
  HOST="${entry%%:*}"
  IP="${entry##*:}"

  echo "═══════════════════════════════════════════════════════"
  echo " $HOST ($IP)"
  echo "═══════════════════════════════════════════════════════"

  # ── 1. SSH connectivity ──────────────────────────────────
  echo "[1/5] Testing SSH..."
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$IP" 'true' 2>/dev/null; then
    echo "  [FAIL] Cannot SSH to $SSH_USER@$IP"
    FAIL_NODES+=("$HOST")
    continue
  fi
  echo "  [OK]"

  # ── 2. Stage remote install script ───────────────────────
  echo "[2/5] Staging + executing remote install on $HOST (sudo prompt)..."
  REMOTE_TMP="/tmp/register_pyxis.$$.sh"

  if ! ssh "$SSH_USER@$IP" "cat > $REMOTE_TMP" <<'REMOTE'
set -euo pipefail
ENROOT_VER="$1"
PYXIS_B64="$2"
ENROOT_CONF_B64="$3"
PLUGSTACK_B64="$4"

ARCH="$(dpkg --print-architecture)"

# 1. Install Enroot from NVIDIA releases (.deb)
cd /tmp
curl -sfSL -O "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VER}/enroot_${ENROOT_VER}-1_${ARCH}.deb"
curl -sfSL -O "https://github.com/NVIDIA/enroot/releases/download/v${ENROOT_VER}/enroot+caps_${ENROOT_VER}-1_${ARCH}.deb"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "/tmp/enroot_${ENROOT_VER}-1_${ARCH}.deb" \
  "/tmp/enroot+caps_${ENROOT_VER}-1_${ARCH}.deb"
rm -f "/tmp/enroot_${ENROOT_VER}-1_${ARCH}.deb" "/tmp/enroot+caps_${ENROOT_VER}-1_${ARCH}.deb"

# 2. Drop spank_pyxis.so into Slurm plugin dir
SLURM_PLUGIN_DIR="/usr/lib/x86_64-linux-gnu/slurm-wlm"
echo "$PYXIS_B64" | base64 -d > "${SLURM_PLUGIN_DIR}/spank_pyxis.so"
chown root:root "${SLURM_PLUGIN_DIR}/spank_pyxis.so"
chmod 644 "${SLURM_PLUGIN_DIR}/spank_pyxis.so"

# 3. Place plugstack.conf
mkdir -p /etc/slurm
echo "$PLUGSTACK_B64" | base64 -d > /etc/slurm/plugstack.conf
chown root:root /etc/slurm/plugstack.conf
chmod 644 /etc/slurm/plugstack.conf

# 4. Place enroot.conf + pre-stage shared cache dir
mkdir -p /etc/enroot
echo "$ENROOT_CONF_B64" | base64 -d > /etc/enroot/enroot.conf
chown root:root /etc/enroot/enroot.conf
chmod 644 /etc/enroot/enroot.conf

mkdir -p /scratch/cluster-software/enroot-cache
chmod 1777 /scratch/cluster-software/enroot-cache

# 5. Restart slurmd to pick up Pyxis
systemctl restart slurmd
sleep 2

# Report
echo "[remote-done] $(hostname -s)"
echo "  enroot:        $(enroot version 2>/dev/null || echo MISSING)"
echo "  spank_pyxis.so $(ls -la ${SLURM_PLUGIN_DIR}/spank_pyxis.so | awk '{print $5,$NF}')"
echo "  slurmd:        $(systemctl is-active slurmd)"
REMOTE
  then
    echo "  [FAIL] Could not stage remote script on $HOST"
    FAIL_NODES+=("$HOST")
    continue
  fi

  if ssh -t "$SSH_USER@$IP" "sudo bash $REMOTE_TMP '$ENROOT_VER' '$PYXIS_B64' '$ENROOT_CONF_B64' '$PLUGSTACK_B64'; rc=\$?; rm -f $REMOTE_TMP; exit \$rc"; then
    echo "  [OK]"
  else
    echo "  [FAIL] Remote install failed on $HOST"
    ssh "$SSH_USER@$IP" "rm -f $REMOTE_TMP" 2>/dev/null || true
    FAIL_NODES+=("$HOST")
    continue
  fi

  sleep 2

  # ── 3. Verify Pyxis loaded by slurmd ──────────────────────
  echo "[3/5] Checking Pyxis loaded in slurmd journal on $HOST..."
  if ssh "$SSH_USER@$IP" "sudo journalctl -u slurmd --since '1 min ago' --no-pager 2>/dev/null | grep -qE 'pyxis: version'"; then
    echo "  [OK] Pyxis loaded"
  else
    echo "  [WARN] No 'pyxis: version' log line found. Plugin may not be loaded — check:"
    echo "         ssh $SSH_USER@$IP 'sudo journalctl -u slurmd --since \"5 min ago\" | grep -i pyxis'"
  fi

  # ── 4. Verify enroot binary works ─────────────────────────
  echo "[4/5] Checking enroot binary on $HOST..."
  if ssh "$SSH_USER@$IP" 'enroot version >/dev/null 2>&1'; then
    echo "  [OK]"
  else
    echo "  [FAIL] enroot not callable on $HOST"
    FAIL_NODES+=("$HOST")
  fi

  # ── 5. Verify slurmd still active ─────────────────────────
  echo "[5/5] Verifying slurmd is still active on $HOST..."
  if ssh "$SSH_USER@$IP" 'systemctl is-active --quiet slurmd'; then
    echo "  [OK]"
  else
    echo "  [FAIL] slurmd not active after restart on $HOST"
    FAIL_NODES+=("$HOST")
  fi

  echo
done

# ── Final fleet check ───────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo " Final fleet state"
echo "═══════════════════════════════════════════════════════"
sleep 3
sinfo
echo

# ── Summary ─────────────────────────────────────────────────
if [[ ${#FAIL_NODES[@]} -eq 0 ]]; then
  echo "[OK] All nodes have Pyxis + Enroot installed."
  echo
  echo "Smoke-test from any node:"
  echo "  srun --partition=cpu --account=research \\"
  echo "       --container-image=docker://ubuntu:24.04 \\"
  echo "       bash -c 'cat /etc/os-release | head -3'"
  echo
  echo "GPU smoke-test (once optical links healthy):"
  echo "  srun --partition=gpu01 --account=research --gres=gpu:1 \\"
  echo "       --container-image=docker://nvidia/cuda:12.4.0-base-ubuntu22.04 \\"
  echo "       nvidia-smi"
  echo
  echo "Next step (optional): install nvidia-container-toolkit on gpu01/gpu02/cgpu01"
  echo "so containers can see the GPUs. Without it, --gres=gpu:1 inside a container"
  echo "won't pass through the device."
else
  echo "[FAIL] These nodes had issues: ${FAIL_NODES[*]}"
  echo
  echo "For each failed node, SSH in and check:"
  echo "  - enroot:  enroot version"
  echo "  - plugin:  ls -la /usr/lib/x86_64-linux-gnu/slurm-wlm/spank_pyxis.so"
  echo "  - config:  cat /etc/slurm/plugstack.conf /etc/enroot/enroot.conf"
  echo "  - slurmd:  sudo systemctl status slurmd"
  echo "             sudo journalctl -u slurmd -n 50 | grep -i pyxis"
  exit 1
fi
