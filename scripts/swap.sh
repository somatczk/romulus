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

# --- Persist in /etc/fstab ---
if ! grep -q "$SWAPFILE" /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    echo "[INFO] Added swap entry to /etc/fstab."
fi

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
