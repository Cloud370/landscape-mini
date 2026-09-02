#!/bin/sh
# Expand root partition to fill the entire disk
# All operations are idempotent — exits in milliseconds if no expansion needed

set -eu

log() {
    echo "expand-rootfs: $*"
}

warn() {
    echo "expand-rootfs: $*" >&2
}

get_block_device_size() {
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --getsize64 "$1" 2>/dev/null
        return
    fi

    lsblk -bnro SIZE "$1" 2>/dev/null | head -1
}

try_reread_partition_table() {
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$ROOT_DISK" 2>/dev/null || true
    fi

    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle 2>/dev/null || true
    fi
}

ROOT_PART=$(lsblk -pnro NAME,MOUNTPOINT | while read -r name mountpoint; do
    if [ "$mountpoint" = "/" ]; then
        printf '%s\n' "$name"
        break
    fi
done)

if [ -z "$ROOT_PART" ]; then
    ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    case "$ROOT_SOURCE" in
        /dev/*)
            ROOT_PART="$ROOT_SOURCE"
            ;;
        *)
            warn "could not resolve block device for / (source: ${ROOT_SOURCE:-unknown})"
            exit 1
            ;;
    esac
fi

ROOT_DISK_NAME=$(lsblk -nro PKNAME "$ROOT_PART" | head -1)
PART_NUM=$(lsblk -nro PARTN "$ROOT_PART" | head -1)

if [ -z "$ROOT_DISK_NAME" ] || [ -z "$PART_NUM" ]; then
    warn "unsupported root device $ROOT_PART; expected a disk partition"
    exit 1
fi

ROOT_DISK="/dev/$ROOT_DISK_NAME"

# 1. Fix GPT backup header (required after dd'ing a small image to a larger disk)
#    No-op if already fixed
SGDISK_OUTPUT=$(sgdisk -e "$ROOT_DISK" 2>&1 || true)
if [ -n "$SGDISK_OUTPUT" ]; then
    printf '%s\n' "$SGDISK_OUTPUT" >&2
fi
try_reread_partition_table

ROOT_PART_SIZE_BEFORE=$(get_block_device_size "$ROOT_PART")
if [ -z "$ROOT_PART_SIZE_BEFORE" ]; then
    warn "could not determine current size of $ROOT_PART"
    exit 1
fi

# 2. Expand partition (growpart auto-detects available space)
#    Distinguish true no-op from real failures
set +e
GROWPART_OUTPUT=$(growpart "$ROOT_DISK" "$PART_NUM" 2>&1)
GROWPART_STATUS=$?
set -e

if [ -n "$GROWPART_OUTPUT" ]; then
    if [ "$GROWPART_STATUS" -eq 0 ]; then
        printf '%s\n' "$GROWPART_OUTPUT"
    else
        printf '%s\n' "$GROWPART_OUTPUT" >&2
    fi
fi

PARTITION_CHANGED=yes
case "$GROWPART_OUTPUT" in
    *NOCHANGE:*)
        PARTITION_CHANGED=no
        ;;
esac

if [ "$GROWPART_STATUS" -ne 0 ] && [ "$PARTITION_CHANGED" != "no" ]; then
    warn "failed to grow $ROOT_PART on $ROOT_DISK (exit $GROWPART_STATUS)"
    exit "$GROWPART_STATUS"
fi

if [ "$PARTITION_CHANGED" = "yes" ]; then
    try_reread_partition_table

    ROOT_PART_SIZE_AFTER=$(get_block_device_size "$ROOT_PART")
    if [ -z "$ROOT_PART_SIZE_AFTER" ]; then
        warn "could not determine resized size of $ROOT_PART"
        exit 1
    fi

    if [ "$ROOT_PART_SIZE_AFTER" -le "$ROOT_PART_SIZE_BEFORE" ]; then
        warn "kernel has not recognized the new size of $ROOT_PART yet"
        exit 1
    fi
else
    log "partition already fills disk; checking filesystem size"
fi

# 3. Expand filesystem if needed
resize2fs "$ROOT_PART"

if [ "$PARTITION_CHANGED" = "yes" ]; then
    log "root partition expanded"
else
    log "filesystem checked against current partition size"
fi

# 4. Fix home ownership for rootless-built images
#    Rootless builds pack the filesystem as an unprivileged user, so /home/ld
#    lands root-owned in the image; hand it back to the 'ld' account (uid 1000).
#    No-op for root-built images.
LD_UID=$(awk -F: '$1 == "ld" {print $3}' /etc/passwd 2>/dev/null || true)
LD_GID=$(awk -F: '$1 == "ld" {print $4}' /etc/passwd 2>/dev/null || true)
LD_GID="${LD_GID:-$LD_UID}"
if [ -n "$LD_UID" ] && [ -d /home/ld ]; then
    CURRENT_OWNER=$(stat -c '%u:%g' /home/ld 2>/dev/null || true)
    if [ "$CURRENT_OWNER" != "${LD_UID}:${LD_GID}" ]; then
        chown -R "$LD_UID:$LD_GID" /home/ld 2>/dev/null || warn "could not fix /home/ld ownership"
        log "fixed /home/ld ownership (${CURRENT_OWNER} -> ${LD_UID}:${LD_GID})"
    fi
fi

# 5. Restore gid-based setgid ownership for rootless-built images
#    Package extraction without a full gid map leaves group-privileged
#    binaries owned by root:root (setgid bit intact, group lost). Restore
#    their group so e.g. PAM's unix_chkpwd can read /etc/shadow for
#    non-root password logins. No-op for root-built images and Alpine.
restore_group() {
    path="$1"; group="$2"
    [ -e "$path" ] || return 0
    want_gid=$(awk -F: -v g "$group" '$1 == g {print $3}' /etc/group 2>/dev/null)
    [ -n "$want_gid" ] || return 0
    if [ "$(stat -c '%g' "$path" 2>/dev/null)" != "$want_gid" ]; then
        chgrp "$group" "$path" 2>/dev/null || warn "could not restore $group group on $path"
    fi
}
restore_group /usr/sbin/unix_chkpwd shadow
restore_group /usr/bin/expiry shadow
restore_group /usr/bin/chage shadow
restore_group /usr/bin/crontab crontab
restore_group /var/spool/cron/crontabs crontab
restore_group /usr/bin/wall tty
restore_group /usr/bin/write tty
restore_group /var/run/utmp utmp
restore_group /var/log/lastlog utmp
