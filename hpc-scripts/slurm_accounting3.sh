#!/usr/bin/env bash
# ============================================================
# 06 — slurmdbd + MariaDB accounting (controller only)
# ============================================================
# Runs ONLY on cpu01 (the SLURM controller).
# The 3 compute nodes don't need slurmdbd or MariaDB — they
# talk to slurmdbd over the wire via cpu01.
#
# Sets up:
#   - MariaDB tuned for slurmdbd
#   - slurmdbd connected to MariaDB
#   - Starts slurmctld (which needed slurmdbd up first)
#   - Bootstraps cluster + research accounts + default QoS
#   - Nightly mysqldump cron to NetApp
#
# Required env:
#   SLURMDB_PASSWORD     password for the slurm DB user
#
# Optional env:
#   NODE_HOSTNAME        auto-detected from `hostname -s`
#   BACKUP_PATH=/projects/admin/slurm-backups
#   CLUSTER_NAME=research-cluster
# ============================================================
set -euo pipefail

: "${SLURMDB_PASSWORD:?set SLURMDB_PASSWORD}"

NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname -s)}"
echo "[*] Hostname: $NODE_HOSTNAME"

# Refuse to run on anything but the controller (cpu01-suffix)
# Suffix-match handles customer prefixes (e.g., insiiukcpu01).
case "$NODE_HOSTNAME" in
  *cpu01) ;;  # OK — this is the controller
  *)
    echo "[!] 06_accounting.sh only runs on the controller (*cpu01)."
    echo "    Current host: $NODE_HOSTNAME"
    echo "    Compute nodes (*gpu01/*gpu02/*gpu03) don't need slurmdbd or MariaDB —"
    echo "    they reach slurmdbd over the wire via AccountingStorageHost in slurm.conf."
    exit 1
    ;;
esac

# This node IS the controller — its actual hostname is what slurm.conf and
# slurmdbd.conf must agree on. Use it directly so DbdHost matches
# AccountingStorageHost (set by 05_slurm.sh to the same value).
CPU01_HOST="$NODE_HOSTNAME"
echo "[*] Controller hostname: $CPU01_HOST (will be used as DbdHost)"

CLUSTER_NAME="${CLUSTER_NAME:-research-cluster}"
BACKUP_PATH="${BACKUP_PATH:-/projects/admin/slurm-backups}"
DB_NAME="slurm_acct_db"
DB_USER="slurm"

# ── Install MariaDB + slurmdbd ──────────────────────────────
echo "[*] Installing MariaDB + slurmdbd"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mariadb-server slurmdbd

# ── Tune MariaDB for slurmdbd ───────────────────────────────
echo "[*] Tuning MariaDB for slurmdbd"
sudo tee /etc/mysql/mariadb.conf.d/99-slurm.cnf >/dev/null <<'EOF'
[mysqld]
innodb_buffer_pool_size = 1024M
innodb_log_file_size = 64M
innodb_lock_wait_timeout = 900
max_allowed_packet = 64M
EOF

sudo systemctl enable --now mariadb
sleep 2

# ── Create DB + user ────────────────────────────────────────
echo "[*] Creating database and user"
sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$SLURMDB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ── slurmdbd.conf ───────────────────────────────────────────
# DbdHost must match AccountingStorageHost in slurm.conf (set by 05_slurm.sh).
# Both use the actual hostname (e.g., insiiukcpu01), not the bare "cpu01".
echo "[*] Writing /etc/slurm/slurmdbd.conf"
sudo tee /etc/slurm/slurmdbd.conf >/dev/null <<EOF
AuthType=auth/munge
DbdHost=$CPU01_HOST
DbdPort=6819
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePort=3306
StoragePass=$SLURMDB_PASSWORD
StorageUser=$DB_USER
StorageLoc=$DB_NAME
EOF

sudo chown slurm:slurm /etc/slurm/slurmdbd.conf
sudo chmod 600 /etc/slurm/slurmdbd.conf

# ── Start slurmdbd ──────────────────────────────────────────
echo "[*] Starting slurmdbd"
sudo systemctl enable --now slurmdbd
sleep 3

if ! systemctl is-active --quiet slurmdbd; then
  echo "[!] slurmdbd failed to start"
  sudo journalctl -u slurmdbd -n 30
  exit 1
fi

# ── Now slurmctld can start ─────────────────────────────────
echo "[*] Starting slurmctld (depends on slurmdbd)"
sudo systemctl restart slurmctld
sleep 3

if ! systemctl is-active --quiet slurmctld; then
  echo "[!] slurmctld failed to start"
  sudo journalctl -u slurmctld -n 30
  exit 1
fi

# ── Bootstrap cluster + accounts via sacctmgr ───────────────
echo "[*] Bootstrapping accounting cluster + accounts"
sudo sacctmgr -i add cluster "$CLUSTER_NAME" 2>/dev/null || true
sudo sacctmgr -i add account research \
  Description="Research organisation root" \
  Organization=research 2>/dev/null || true

for grp in bioinformatics cheminformatics statistical_genetics; do
  sudo sacctmgr -i add account "$grp" \
    Parent=research \
    Description="$grp research group" \
    Organization=research 2>/dev/null || true
done

# Default QoS
sudo sacctmgr -i add qos normal \
  Description="Standard priority" \
  Priority=100 2>/dev/null || true

# ── Nightly backup cron ─────────────────────────────────────
echo "[*] Configuring nightly mysqldump → $BACKUP_PATH/$NODE_HOSTNAME"
sudo tee /etc/cron.daily/slurm-acct-backup >/dev/null <<EOF
#!/bin/bash
# Nightly slurm_acct_db dump → NetApp
BACKUP_DIR="$BACKUP_PATH/$NODE_HOSTNAME"
mkdir -p "\$BACKUP_DIR"
DATESTAMP=\$(date +%Y%m%d)
mysqldump --single-transaction --quick --triggers --routines \\
  $DB_NAME | gzip > "\$BACKUP_DIR/\${DATESTAMP}.sql.gz"
# Keep 30 days of dumps
find "\$BACKUP_DIR" -name '*.sql.gz' -mtime +30 -delete
EOF
sudo chmod +x /etc/cron.daily/slurm-acct-backup

echo
echo "── service status (controller) ─────────────────────────"
for svc in mariadb slurmdbd slurmctld slurmd; do
  if systemctl is-active --quiet "$svc"; then
    echo "  [OK]   $svc"
  else
    echo "  [FAIL] $svc"
  fi
done

echo
echo "── sinfo (should show all 4 nodes registering) ─────────"
sinfo || true

echo
echo "── sacctmgr cluster ────────────────────────────────────"
sacctmgr -n list cluster | head -5 || true

echo
echo "[OK] Accounting configured. Cluster controller is live."
echo
echo "Compute nodes should appear in 'sinfo' as they register with cpu01."
echo "If any show as 'down*' or 'unknown', check on that node:"
echo "  sudo systemctl status slurmd"
echo "  sudo journalctl -u slurmd -n 30"
echo
echo "Backups run nightly via /etc/cron.daily/slurm-acct-backup."
echo "(They'll only succeed once $BACKUP_PATH is mounted via 08_nfs.sh.)"
echo
echo "Next: 07_scratch.sh on each node (local NVMe → /scratch)."
