#!/bin/bash
# =============================================================================
# Landscape Mini - Shared Build Functions
# =============================================================================
# Sourced by build.sh. Provides common phases shared across all backends.
# Backend-specific functions (backend_*) are provided by lib/debian.sh or
# lib/alpine.sh.
# =============================================================================

# ---------------------------------------------------------------------------
# Cleanup trap - unmount everything and detach loop devices on exit/error
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "==== Cleanup: Unmounting and detaching ===="

    # Unmount in reverse order, ignoring errors
    for mp in \
        "${ROOTFS_DIR}/proc" \
        "${ROOTFS_DIR}/sys" \
        "${ROOTFS_DIR}/dev/pts" \
        "${ROOTFS_DIR}/dev" \
        "${ROOTFS_DIR}/boot/efi" \
        "${ROOTFS_DIR}"; do
        if mountpoint -q "${mp}" 2>/dev/null; then
            echo "  Unmounting ${mp}"
            umount -lf "${mp}" 2>/dev/null || true
        fi
    done

    # Detach loop device
    if [[ -n "${LOOP_DEV}" && -b "${LOOP_DEV}" ]]; then
        echo "  Detaching loop device ${LOOP_DEV}"
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi

    echo "  Cleanup complete."
}

# ---------------------------------------------------------------------------
# Helper: run a command inside the chroot
# ---------------------------------------------------------------------------
run_in_chroot() {
    LANG=C.UTF-8 LC_ALL=C.UTF-8 chroot "${ROOTFS_DIR}" ${CHROOT_SHELL} -c "$1"
}

# ---------------------------------------------------------------------------
# Helper: mount special filesystems for chroot
# ---------------------------------------------------------------------------
mount_chroot_fs() {
    echo "  Mounting special filesystems for chroot ..."
    mount --bind /dev "${ROOTFS_DIR}/dev"
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
}

# ---------------------------------------------------------------------------
# Helper: unmount special filesystems
# ---------------------------------------------------------------------------
umount_chroot_fs() {
    echo "  Unmounting special filesystems ..."
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
}

# =============================================================================
# Phase 1: Download Landscape
# =============================================================================
phase_download() {
    echo ""
    echo "==== Phase 1: Downloading Landscape ===="

    mkdir -p "${DOWNLOAD_DIR}"

    # Use musl binary for Alpine, glibc binary for Debian
    local bin_suffix=""
    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        bin_suffix="-musl"
    fi
    local bin_name="landscape-webserver-x86_64${bin_suffix}"
    local bin_url="${DOWNLOAD_BASE}/${bin_name}"
    local bin_file="${DOWNLOAD_DIR}/${bin_name}"
    local static_url="${DOWNLOAD_BASE}/static.zip"
    local static_file="${DOWNLOAD_DIR}/static.zip"

    if [[ -f "${bin_file}" ]]; then
        echo "  [OK] ${bin_name} already downloaded."
    else
        echo "  [DOWNLOADING] ${bin_name} ..."
        curl -L -o "${bin_file}" "${bin_url}"
    fi
    chmod +x "${bin_file}"

    if [[ -f "${static_file}" ]]; then
        echo "  [OK] static.zip already downloaded."
    else
        echo "  [DOWNLOADING] static.zip ..."
        curl -L -o "${static_file}" "${static_url}"
    fi

    echo "  Phase 1 complete."
}

# =============================================================================
# Phase 2: Create Disk Image
# =============================================================================
phase_create_image() {
    echo ""
    echo "==== Phase 2: Creating Disk Image ===="

    mkdir -p "${OUTPUT_DIR}" "${ROOTFS_DIR}"

    # Create raw image
    echo "  Creating ${IMAGE_SIZE_MB}MB raw image ..."
    dd if=/dev/zero of="${IMAGE_FILE}" bs=1M count="${IMAGE_SIZE_MB}" status=progress

    # Partition with GPT: BIOS boot (1-2MiB) + ESP (2-202MiB) + root (202MiB - 100%)
    echo "  Partitioning (GPT: BIOS + UEFI hybrid) ..."
    parted -s "${IMAGE_FILE}" \
        mklabel gpt \
        mkpart bios 1MiB 2MiB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 202MiB \
        set 2 esp on \
        mkpart root ext4 202MiB 100%

    # Setup loop device
    echo "  Setting up loop device ..."
    LOOP_DEV=$(losetup --show -fP "${IMAGE_FILE}")
    echo "  Loop device: ${LOOP_DEV}"

    # Wait for partition devices to appear
    sleep 1
    partprobe "${LOOP_DEV}" 2>/dev/null || true
    sleep 1

    # Format partitions (partition 1 = BIOS boot, no filesystem needed)
    echo "  Formatting EFI partition (FAT32) ..."
    mkfs.vfat -F32 "${LOOP_DEV}p2"

    echo "  Formatting root partition (ext4, no journal, 1% reserved) ..."
    mkfs.ext4 -F -O ^has_journal -m 1 "${LOOP_DEV}p3"

    # Mount root
    echo "  Mounting root filesystem ..."
    mount "${LOOP_DEV}p3" "${ROOTFS_DIR}"

    # Mount EFI
    mkdir -p "${ROOTFS_DIR}/boot/efi"
    echo "  Mounting EFI partition ..."
    mount "${LOOP_DEV}p2" "${ROOTFS_DIR}/boot/efi"

    echo "  Phase 2 complete."
}

# =============================================================================
# Phase 5: Install Landscape Router (shared parts)
# =============================================================================
phase_install_landscape() {
    echo ""
    echo "==== Phase 5: Installing Landscape Router ===="

    # Copy the landscape binary (musl for Alpine, glibc for Debian)
    local bin_suffix=""
    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        bin_suffix="-musl"
    fi
    echo "  Installing landscape-webserver binary ..."
    cp "${DOWNLOAD_DIR}/landscape-webserver-x86_64${bin_suffix}" "${ROOTFS_DIR}/root/landscape-webserver"
    chmod +x "${ROOTFS_DIR}/root/landscape-webserver"

    # Copy and extract static web assets
    echo "  Installing static web assets ..."
    mkdir -p "${ROOTFS_DIR}/root/.landscape-router"
    cp "${DOWNLOAD_DIR}/static.zip" "${ROOTFS_DIR}/root/.landscape-router/static.zip"
    unzip -o "${ROOTFS_DIR}/root/.landscape-router/static.zip" -d "${ROOTFS_DIR}/root/.landscape-router/"
    rm -f "${ROOTFS_DIR}/root/.landscape-router/static.zip"

    # Copy landscape_init.toml if it exists in configs/
    if [[ -f "${SCRIPT_DIR}/configs/landscape_init.toml" ]]; then
        echo "  Installing landscape_init.toml ..."
        cp "${SCRIPT_DIR}/configs/landscape_init.toml" "${ROOTFS_DIR}/root/.landscape-router/landscape_init.toml"
    else
        echo "  [SKIP] No configs/landscape_init.toml found (will use --auto mode)."
    fi

    # Copy sysctl config
    if [[ -f "${SCRIPT_DIR}/rootfs/etc/sysctl.d/99-landscape.conf" ]]; then
        echo "  Installing sysctl config ..."
        mkdir -p "${ROOTFS_DIR}/etc/sysctl.d"
        cp "${SCRIPT_DIR}/rootfs/etc/sysctl.d/99-landscape.conf" \
            "${ROOTFS_DIR}/etc/sysctl.d/99-landscape.conf"
    else
        echo "  [SKIP] No rootfs/etc/sysctl.d/99-landscape.conf found."
    fi

    # Install expand-rootfs script
    echo "  Installing expand-rootfs script ..."
    mkdir -p "${ROOTFS_DIR}/usr/local/bin"
    cp "${SCRIPT_DIR}/rootfs/usr/local/bin/expand-rootfs.sh" \
        "${ROOTFS_DIR}/usr/local/bin/expand-rootfs.sh"
    chmod +x "${ROOTFS_DIR}/usr/local/bin/expand-rootfs.sh"

    # Install mirror setup script
    echo "  Installing setup-mirror script ..."
    cp "${SCRIPT_DIR}/rootfs/usr/local/bin/setup-mirror.sh" \
        "${ROOTFS_DIR}/usr/local/bin/setup-mirror.sh"
    chmod +x "${ROOTFS_DIR}/usr/local/bin/setup-mirror.sh"

    # Backend-specific: install init services (systemd or OpenRC)
    backend_install_landscape_services

    echo "  Phase 5 complete."
}

# =============================================================================
# Phase 7: Cleanup & Shrink Image (shared parts)
# =============================================================================
phase_cleanup_and_shrink() {
    echo ""
    echo "==== Phase 7: Cleanup & Shrink ===="

    # ---- Strip landscape binary ----
    echo "  Stripping landscape-webserver binary ..."
    if [[ -f "${ROOTFS_DIR}/root/landscape-webserver" ]]; then
        local BEFORE_SIZE AFTER_SIZE
        BEFORE_SIZE=$(stat -c%s "${ROOTFS_DIR}/root/landscape-webserver")
        strip --strip-unneeded "${ROOTFS_DIR}/root/landscape-webserver" 2>/dev/null || true
        AFTER_SIZE=$(stat -c%s "${ROOTFS_DIR}/root/landscape-webserver")
        echo "    Binary: $((BEFORE_SIZE/1024/1024))M -> $((AFTER_SIZE/1024/1024))M"
    fi

    # ---- Remove unneeded kernel modules ----
    echo "  Removing unneeded kernel modules ..."
    run_in_chroot "
        KDIR=\$(ls -d /usr/lib/modules/*/kernel 2>/dev/null | head -1)
        if [ -z \"\$KDIR\" ]; then
            KDIR=\$(ls -d /lib/modules/*/kernel 2>/dev/null | head -1)
        fi
        if [ -n \"\$KDIR\" ]; then
            # === Top-level subsystems ===
            rm -rf \"\$KDIR/sound\"

            # === drivers/ — bulk removal (keep: net, virtio, block, tty, pci, hv, char) ===
            # NOTE: char = hw_random/virtio-rng/TPM (~2-3MB, critical VM entropy source)
            for d in media gpu infiniband iio comedi staging hid input video \
                     bluetooth usb platform md mtd misc target \
                     accel mmc isdn edac crypto \
                     nfc firewire thunderbolt ufs atm vfio \
                     leds vdpa ntb dma accessibility gpio pinctrl pcmcia \
                     spi memstick power soundwire ssb parport uio \
                     nvdimm rpmsg bcma auxdisplay cdrom mfd gnss dca mux \
                     pwm powercap soc regulator extcon dax devfreq; do
                rm -rf \"\$KDIR/drivers/\$d\"
            done

            # === drivers/net/ — keep virtio, phy, bonding, ppp, vxlan, wireguard, hyperv, ethernet ===
            for d in can wwan arcnet fddi hamradio ieee802154 wan wireless \
                     dsa fjes hippi plip slip thunderbolt xen-netback \
                     mdio pcs ipvlan; do
                rm -rf \"\$KDIR/drivers/net/\$d\"
            done

            # === drivers/net/ethernet/ — keep intel, realtek, virtio (broadcom optional) ===
            if [ -d \"\$KDIR/drivers/net/ethernet\" ]; then
                for d in \"\$KDIR/drivers/net/ethernet\"/*/; do
                    case \"\$(basename \"\$d\")\" in
                        intel|realtek|broadcom|amazon|google|mellanox|microsoft|aquantia|amd|huawei|marvell|atheros|cavium|chelsio) ;;  # keep common physical/cloud NIC drivers
                        *) rm -rf \"\$d\" ;;
                    esac
                done
            fi

            # === net/ — keep core, ipv4, ipv6, netfilter, bridge, sched, 8021q, tls, xfrm, vmw_vsock ===
            # NOTE: vmw_vsock kept for VMware/ESXi VM-host communication (~50KB)
            for d in bluetooth mac80211 wireless sunrpc ceph tipc nfc rxrpc smc sctp \
                     atm dccp ieee802154 mac802154 6lowpan 9p openvswitch \
                     rds l2tp phonet can x25 appletalk rfkill lapb nsh; do
                rm -rf \"\$KDIR/net/\$d\"
            done

            # === fs/ — keep ext4, jbd2, fat, nls (needed by vfat), fuse, overlay ===
            for d in bcachefs btrfs xfs ocfs2 f2fs jfs reiserfs gfs2 nilfs2 orangefs coda \
                     smb nfs nfsd ceph ubifs afs ntfs3 dlm jffs2 udf netfs \
                     hfsplus hfs hpfs exfat ufs ext2 ecryptfs squashfs sysv minix \
                     isofs vboxsf omfs efs romfs nfs_common lockd cachefiles 9p; do
                rm -rf \"\$KDIR/fs/\$d\"
            done

            # Rebuild module dependencies
            MODDIR=\$(ls -d /usr/lib/modules/*/ 2>/dev/null | head -1)
            if [ -z \"\$MODDIR\" ]; then
                MODDIR=\$(ls -d /lib/modules/*/ 2>/dev/null | head -1)
            fi
            if [ -n \"\$MODDIR\" ]; then
                KVER=\$(basename \"\$MODDIR\")
                depmod \"\$KVER\" 2>/dev/null || true
            fi
        fi
    "

    # ---- Clean GRUB leftovers ----
    echo "  Cleaning GRUB locale and modules ..."
    rm -rf "${ROOTFS_DIR}/boot/grub/locale"
    rm -rf "${ROOTFS_DIR}/usr/lib/grub"

    # ---- Generate SSH host keys ----
    echo "  Generating SSH host keys ..."
    run_in_chroot "ssh-keygen -A"

    # ---- Strip all binaries and shared libraries ----
    echo "  Stripping binaries and shared libraries ..."
    run_in_chroot "
        find /usr/bin /usr/sbin /usr/lib -type f \
            \( -name '*.so*' -o -executable \) \
            -exec strip --strip-unneeded {} + 2>/dev/null || true
    "

    # ---- Backend-specific cleanup (apt/apk, initramfs, locale) ----
    backend_cleanup

    # ---- Truncate udev hwdb ----
    echo "  Truncating udev hardware database ..."
    rm -rf "${ROOTFS_DIR}/usr/lib/udev/hwdb.d" 2>/dev/null || true
    if [ -f "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin" ]; then
        : > "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin"
    fi

    # ---- General cleanup ----
    echo "  Cleaning caches and unnecessary files ..."
    run_in_chroot "
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/lintian/*
        rm -rf /usr/share/bash-completion/*
        rm -rf /usr/share/common-licenses/*
        rm -f /var/log/*.log
        rm -rf /tmp/*
        rm -rf /var/tmp/*
    "

    # Unmount special filesystems
    umount_chroot_fs

    # Unmount EFI partition
    echo "  Unmounting EFI partition ..."
    umount "${ROOTFS_DIR}/boot/efi" 2>/dev/null || true

    # ---- Clean journal AFTER special fs unmounted ----
    echo "  Cleaning journal logs ..."
    rm -rf "${ROOTFS_DIR}/var/log/journal"

    # Unmount root BEFORE e2fsck/resize2fs
    echo "  Unmounting root filesystem ..."
    umount "${ROOTFS_DIR}" 2>/dev/null || true

    # Shrink the ext4 filesystem
    echo "  Running filesystem check ..."
    e2fsck -f -y "${LOOP_DEV}p3" || true

    echo "  Shrinking ext4 filesystem to minimum size ..."
    resize2fs -M "${LOOP_DEV}p3"

    # Get the actual filesystem size after shrink
    echo "  Calculating final image size ..."
    local ROOT_BLOCKS ROOT_BLOCKSIZE ROOT_BYTES
    ROOT_BLOCKS=$(dumpe2fs -h "${LOOP_DEV}p3" 2>/dev/null | grep "Block count:" | awk '{print $3}')
    ROOT_BLOCKSIZE=$(dumpe2fs -h "${LOOP_DEV}p3" 2>/dev/null | grep "Block size:" | awk '{print $3}')
    ROOT_BYTES=$(( ROOT_BLOCKS * ROOT_BLOCKSIZE ))

    # Detach loop device first (before modifying partition table)
    echo "  Detaching loop device ..."
    losetup -d "${LOOP_DEV}"
    LOOP_DEV=""

    # Partition 3 starts at sector 413696 (202MiB = 211812352 bytes / 512)
    local PART3_START_SECTOR=413696
    local ROOT_SECTORS=$(( ROOT_BYTES / 512 ))
    local PART3_END_SECTOR=$(( PART3_START_SECTOR + ROOT_SECTORS ))
    PART3_END_SECTOR=$(( ((PART3_END_SECTOR + 2047) / 2048) * 2048 - 1 ))
    local TOTAL_SECTORS=$(( PART3_END_SECTOR + 1 + 2048 ))
    local TOTAL_BYTES=$(( TOTAL_SECTORS * 512 ))

    # Save GRUB i386-pc boot code from MBR
    echo "  Saving GRUB MBR boot code ..."
    dd if="${IMAGE_FILE}" of="${IMAGE_FILE}.mbr" bs=440 count=1 2>/dev/null

    # Truncate the image to the new size
    echo "  Truncating image to $(( TOTAL_BYTES / 1048576 )) MB ..."
    truncate -s "${TOTAL_BYTES}" "${IMAGE_FILE}"

    # Wipe all GPT/MBR structures, then recreate clean GPT
    echo "  Rebuilding GPT partition table ..."
    sgdisk --zap-all "${IMAGE_FILE}" >/dev/null 2>&1
    sgdisk \
        -n 1:2048:4095 -t 1:EF02 -c 1:bios \
        -n 2:4096:413695 -t 2:EF00 -c 2:ESP \
        -n 3:${PART3_START_SECTOR}:${PART3_END_SECTOR} -t 3:8300 \
        "${IMAGE_FILE}"

    # Restore GRUB i386-pc boot code to MBR
    echo "  Restoring GRUB MBR boot code ..."
    dd if="${IMAGE_FILE}.mbr" of="${IMAGE_FILE}" bs=440 count=1 conv=notrunc 2>/dev/null
    rm -f "${IMAGE_FILE}.mbr"

    # Optional: convert to VMDK
    if [[ "${OUTPUT_FORMAT}" == "vmdk" || "${OUTPUT_FORMAT}" == "both" ]]; then
        echo "  Converting to VMDK ..."
        local VMDK_FILE="${OUTPUT_DIR}/landscape-mini-x86${IMAGE_SUFFIX}.vmdk"
        qemu-img convert -f raw -O vmdk "${IMAGE_FILE}" "${VMDK_FILE}"
        echo "  VMDK created: ${VMDK_FILE}"
    fi

    # Optional: compress with gzip
    if [[ "${COMPRESS_OUTPUT}" == "yes" ]]; then
        echo "  Compressing image with gzip ..."
        gzip -k -f "${IMAGE_FILE}"
        echo "  Compressed: ${IMAGE_FILE}.gz"

        if [[ "${OUTPUT_FORMAT}" == "vmdk" || "${OUTPUT_FORMAT}" == "both" ]]; then
            local VMDK_FILE="${OUTPUT_DIR}/landscape-mini-x86${IMAGE_SUFFIX}.vmdk"
            if [[ -f "${VMDK_FILE}" ]]; then
                gzip -k -f "${VMDK_FILE}"
                echo "  Compressed: ${VMDK_FILE}.gz"
            fi
        fi
    fi

    # If format is vmdk only, remove the raw image
    if [[ "${OUTPUT_FORMAT}" == "vmdk" ]]; then
        echo "  Removing raw image (vmdk-only output) ..."
        rm -f "${IMAGE_FILE}"
    fi

    echo "  Phase 7 complete."
}

# =============================================================================
# Phase 8: Report
# =============================================================================
phase_report() {
    echo ""
    echo "==== Phase 8: Build Complete ===="
    echo ""
    echo "Output files:"
    echo "------------------------------------------------------------"

    if [[ -f "${IMAGE_FILE}" ]]; then
        local IMG_SIZE
        IMG_SIZE=$(du -h "${IMAGE_FILE}" | awk '{print $1}')
        echo "  RAW image : ${IMAGE_FILE} (${IMG_SIZE})"
    fi

    if [[ -f "${IMAGE_FILE}.gz" ]]; then
        local GZ_SIZE
        GZ_SIZE=$(du -h "${IMAGE_FILE}.gz" | awk '{print $1}')
        echo "  Compressed: ${IMAGE_FILE}.gz (${GZ_SIZE})"
    fi

    local VMDK_FILE="${OUTPUT_DIR}/landscape-mini-x86${IMAGE_SUFFIX}.vmdk"
    if [[ -f "${VMDK_FILE}" ]]; then
        local VMDK_SIZE
        VMDK_SIZE=$(du -h "${VMDK_FILE}" | awk '{print $1}')
        echo "  VMDK image: ${VMDK_FILE} (${VMDK_SIZE})"
    fi

    if [[ -f "${VMDK_FILE}.gz" ]]; then
        local VMDK_GZ_SIZE
        VMDK_GZ_SIZE=$(du -h "${VMDK_FILE}.gz" | awk '{print $1}')
        echo "  Compressed: ${VMDK_FILE}.gz (${VMDK_GZ_SIZE})"
    fi

    echo ""
    echo "To write the raw image to a disk:"
    echo "  dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "To boot in QEMU:"
    echo "  qemu-system-x86_64 -enable-kvm -m 512 -bios /usr/share/ovmf/OVMF.fd \\"
    echo "    -drive file=${IMAGE_FILE},format=raw -nic user,hostfwd=tcp::2222-:22"
    echo ""
    echo "Default credentials:  root / ${ROOT_PASSWORD}  |  ld / ${ROOT_PASSWORD}"
    echo "============================================================"
}

# =============================================================================
# Helper: Re-attach existing image for resumed builds
# =============================================================================
resume_from_image() {
    if [[ ! -f "${IMAGE_FILE}" ]]; then
        echo "ERROR: Cannot skip to phase ${SKIP_TO_PHASE} - image file not found: ${IMAGE_FILE}"
        echo "Run a full build first, or skip to an earlier phase."
        exit 1
    fi
    echo "  Re-attaching existing image for phase ${SKIP_TO_PHASE} ..."
    LOOP_DEV=$(losetup --show -fP "${IMAGE_FILE}")
    sleep 1
    partprobe "${LOOP_DEV}" 2>/dev/null || true
    sleep 1
    mkdir -p "${ROOTFS_DIR}"
    mount "${LOOP_DEV}p3" "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}/boot/efi"
    mount "${LOOP_DEV}p2" "${ROOTFS_DIR}/boot/efi"
    mount_chroot_fs
}
