#!/usr/bin/env bash
# ============================================================
# 07 — Local NVMe → /scratch
# ============================================================
# Formats a block device (single NVMe partition, software RAID
# /dev/md0, hardware RAID logical volume, etc.) and mounts it
# at /scratch with sticky-bit perms for SLURM scratch use.
#
# Required env:
#   SCRATCH_DEV         block device for scratch
#                       e.g. /dev/nvme0n1p1   (single NVMe partition)
#                            /dev/md0          (mdadm software RAID)
#                            /dev/sda          (hardware RAID volume)
#
# Optional env:
#   SCRATCH_DIR=/scratch
#   FILESYSTEM=xfs      # xfs default — better for HPC scratch
#                       # ext4 also supported via FILESYSTEM=ext4
# ============================================================
set -euo pipefail

# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 1 — Inputs & defaults                            │
# │ CHANGE HERE if you want to set different defaults for    │
# │ the mount point or filesystem type.                      │
# └──────────────────────────────────────────────────────────┘
: "${SCRATCH_DEV:?set SCRATCH_DEV (e.g. /dev/nvme0n1p1 or /dev/md0)}"

SCRATCH_DIR="${SCRATCH_DIR:-/scratch}"     # where to mount it
FILESYSTEM="${FILESYSTEM:-xfs}"            # xfs (default) or ext4
SENTINEL_DIR="/etc/hpc"                    # where the "already-formatted" marker lives
SENTINEL="$SENTINEL_DIR/scratch_formatted" # marker file — prevents accidental re-format on re-runs


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 2 — Safety checks                                │
# │ Refuses to proceed if the target isn't valid, is already │
# │ mounted, or looks like the OS root disk. These guards    │
# │ prevent you from destroying live data or breaking boot.  │
# │ CHANGE HERE if you have an unusual disk layout that      │
# │ triggers false positives (rare).                         │
# └──────────────────────────────────────────────────────────┘
# (a) Is the path actually a block device?
[[ -b "$SCRATCH_DEV" ]] || { echo "[!] $SCRATCH_DEV is not a block device."; exit 1; }

# (b) Is it currently mounted somewhere? If so, refuse — formatting a
#     mounted device corrupts the running filesystem.
if mount | grep -q "^$SCRATCH_DEV "; then
  echo "[!] $SCRATCH_DEV is currently mounted — unmount first."
  exit 1
fi

# (c) Does it look like the OS root device? If so, refuse — formatting
#     it would destroy the running OS.
ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ -n "$ROOT_DEV" && "$SCRATCH_DEV" == *"${ROOT_DEV##*/}"* ]]; then
  echo "[!] $SCRATCH_DEV looks like the OS root device — refusing."
  exit 1
fi

echo "[*] Scratch device: $SCRATCH_DEV"
echo "[*] Mount point:    $SCRATCH_DIR"
echo "[*] Filesystem:     $FILESYSTEM"


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 3 — Format (one-time, sentinel-protected)        │
# │ First run: prompts "yes" and runs mkfs. Marks sentinel.  │
# │ Re-runs:  sentinel exists → skips the destructive step.  │
# │                                                          │
# │ CHANGE HERE if you want to add mkfs flags (e.g. specific │
# │ XFS stripe unit/width for non-mdadm RAID layouts, or     │
# │ different block size). mkfs.xfs auto-detects RAID params │
# │ for /dev/mdX devices but NOT for hardware RAID.          │
# │                                                          │
# │ TO FORCE REFORMAT (DESTROYS DATA):                       │
# │   sudo rm /etc/hpc/scratch_formatted                     │
# │   sudo umount /scratch                                   │
# │   sudo ./07_scratch.sh                                   │
# └──────────────────────────────────────────────────────────┘
sudo mkdir -p "$SENTINEL_DIR"

if [[ ! -f "$SENTINEL" ]]; then
  echo
  echo "[!] About to format $SCRATCH_DEV as $FILESYSTEM."
  echo "    THIS DESTROYS ALL DATA on $SCRATCH_DEV."
  echo -n "    Type 'yes' to continue: "
  read -r CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

  case "$FILESYSTEM" in
    ext4) sudo mkfs.ext4 -F -L scratch "$SCRATCH_DEV" ;;
    xfs)  sudo mkfs.xfs -f -L scratch "$SCRATCH_DEV" ;;
    *) echo "[!] Unsupported FILESYSTEM"; exit 1 ;;
  esac

  sudo touch "$SENTINEL"   # record that we did the destructive step
else
  echo "[*] Already formatted (sentinel: $SENTINEL) — skipping mkfs"
fi


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 4 — mdadm config persistence (RAID only)         │
# │ If SCRATCH_DEV is a software RAID array (/dev/md*), the  │
# │ array config must be saved to /etc/mdadm/mdadm.conf AND  │
# │ the initramfs updated, otherwise the array won't         │
# │ auto-assemble on reboot — and /scratch won't mount.      │
# │                                                          │
# │ This section is idempotent: only writes mdadm.conf and   │
# │ updates initramfs if the array's UUID isn't already in   │
# │ mdadm.conf.                                              │
# │                                                          │
# │ Skipped entirely for non-RAID devices.                   │
# └──────────────────────────────────────────────────────────┘
if [[ "$SCRATCH_DEV" == /dev/md* ]]; then
  echo "[*] Detected mdadm software RAID — checking config persistence"
  sudo mkdir -p /etc/mdadm
  sudo touch /etc/mdadm/mdadm.conf

  # Get the canonical ARRAY line + this array's UUID
  ARRAY_LINE="$(sudo mdadm --detail --scan "$SCRATCH_DEV" 2>/dev/null || true)"
  ARRAY_UUID="$(echo "$ARRAY_LINE" | grep -oP 'UUID=\K[a-f0-9:]+' || true)"

  if [[ -z "$ARRAY_UUID" ]]; then
    echo "[!] Could not read array details from $SCRATCH_DEV."
    echo "    Is the array actually assembled? Check: sudo mdadm --detail $SCRATCH_DEV"
    exit 1
  fi

  if grep -q "$ARRAY_UUID" /etc/mdadm/mdadm.conf; then
    echo "[OK] Array $SCRATCH_DEV already in /etc/mdadm/mdadm.conf"
  else
    echo "[*] Adding array to /etc/mdadm/mdadm.conf"
    echo "$ARRAY_LINE" | sudo tee -a /etc/mdadm/mdadm.conf >/dev/null
    echo "[*] Updating initramfs (so the array assembles early at boot)..."
    sudo update-initramfs -u
    echo "[OK] mdadm config persisted; array will survive reboot."
  fi
fi


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 5 — fstab entry (persists across reboots)        │
# │ Adds the device to /etc/fstab by UUID (not device path)  │
# │ so reboots, RAID reassembly, or path renumbering don't   │
# │ break the mount.                                         │
# │                                                          │
# │ CHANGE HERE if you want different mount options.         │
# │ Defaults: noatime,nodiratime (skip access-time updates   │
# │ for perf). Add `discard` for trim if NVMe supports it.   │
# └──────────────────────────────────────────────────────────┘
sudo mkdir -p "$SCRATCH_DIR"
DEV_UUID="$(sudo blkid -s UUID -o value "$SCRATCH_DEV")"

if ! grep -q "$DEV_UUID" /etc/fstab; then
  echo "UUID=$DEV_UUID $SCRATCH_DIR $FILESYSTEM defaults,noatime,nodiratime 0 2" | \
    sudo tee -a /etc/fstab >/dev/null
fi


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 6 — Mount it now                                 │
# │ Brings the volume online without waiting for a reboot.   │
# │ Idempotent — only mounts if not already mounted.         │
# └──────────────────────────────────────────────────────────┘
mountpoint -q "$SCRATCH_DIR" || sudo mount "$SCRATCH_DIR"


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 7 — Permissions                                  │
# │ 1777 = sticky-bit + world-writable (like /tmp).          │
# │ Any user can write; only the owner of a file can delete  │
# │ their own file. Pre-creates /scratch/jobs/ which the     │
# │ SLURM prolog populates per-job at job start.             │
# │                                                          │
# │ CHANGE HERE if you want a different perm model (e.g.,    │
# │ group-only access via 2770).                             │
# └──────────────────────────────────────────────────────────┘
sudo chmod 1777 "$SCRATCH_DIR"
sudo mkdir -p "$SCRATCH_DIR/jobs"
sudo chmod 1777 "$SCRATCH_DIR/jobs"


# ┌──────────────────────────────────────────────────────────┐
# │ SECTION 8 — Verify + next-step hint                      │
# └──────────────────────────────────────────────────────────┘
echo
df -h "$SCRATCH_DIR"

echo
echo "[OK] $SCRATCH_DIR ready."
echo "    Per-job dirs auto-created at /scratch/jobs/\$SLURM_JOB_ID by prolog."
echo
echo "Next: 08_nfs.sh"
