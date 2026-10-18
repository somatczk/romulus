#!/usr/bin/env bash
set -euo pipefail

SWAPFILE="/DATA/swapfile"
SWAP_SIZE="8G"
SWAPPINESS=10           # Only swap under real pressure
VFS_CACHE_PRESSURE=50   # Balanced inode/dentry cache reclaim

# --- Pre-flight ---
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run as root (sudo)."
    exit 1
fi

# --- Create swapfile (skip if already exists and active) ---
if swapon --show | grep -q "$SWAPFILE"; then
    echo "[INFO] Swap already active at $SWAPFILE, skipping creation."
else
    if [[ -f "$SWAPFILE" ]]; then
        echo "[INFO] Swapfile exists but not active, re-enabling..."
    else
        echo "[INFO] Creating ${SWAP_SIZE} swapfile..."
        fallocate -l "$SWAP_SIZE" "$SWAPFILE"
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
    echo "[INFO] Swap enabled."
fi

# --- Persist via a unit ordered after the /DATA bind mount ---
# An fstab entry here forms an ordering cycle with DATA.mount; systemd then drops the
# /DATA mount at boot (no home dir, no SSH keys, containers start without their data).
sed -i "\#^${SWAPFILE} #d" /etc/fstab
cat > /etc/systemd/system/data-swapfile.service <<UNIT
[Unit]
Description=Swap on ${SWAPFILE} (after the /DATA bind mount)
Requires=DATA.mount
After=DATA.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/swapon ${SWAPFILE}
ExecStop=/sbin/swapoff ${SWAPFILE}

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable data-swapfile.service
echo "[INFO] Swap persisted via data-swapfile.service."

# --- Kernel tuning ---
SYSCTL_FILE="/etc/sysctl.d/99-swap.conf"
cat > "$SYSCTL_FILE" <<EOF
vm.swappiness=${SWAPPINESS}
vm.vfs_cache_pressure=${VFS_CACHE_PRESSURE}
EOF
sysctl -p "$SYSCTL_FILE"
echo "[INFO] Kernel parameters applied (swappiness=${SWAPPINESS}, vfs_cache_pressure=${VFS_CACHE_PRESSURE})."

# --- Summary ---
echo ""
echo "=== Swap Configuration ==="
swapon --show
echo ""
echo "vm.swappiness = $(cat /proc/sys/vm/swappiness)"
echo "vm.vfs_cache_pressure = $(cat /proc/sys/vm/vfs_cache_pressure)"
