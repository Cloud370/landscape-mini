#!/bin/sh
# Expand root partition to fill the entire disk
# All operations are idempotent — exits in milliseconds if no expansion needed

set -e

ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_DISK="/dev/$(lsblk -n -o PKNAME "${ROOT_PART}" | head -1)"
PART_NUM="${ROOT_PART##*[!0-9]}"

# 1. Fix GPT backup header (required after dd'ing a small image to a larger disk)
#    No-op if already fixed
sgdisk -e "${ROOT_DISK}" 2>/dev/null || true

# 2. Expand partition (growpart auto-detects available space)
#    Prints "NOCHANGE" and exits if no space available
if growpart "${ROOT_DISK}" "${PART_NUM}"; then
    # 3. Expand filesystem only if partition was actually expanded
    resize2fs "${ROOT_PART}"
    echo "expand-rootfs: root partition expanded"
else
    echo "expand-rootfs: no expansion needed"
fi
