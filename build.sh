#!/bin/bash
set -euo pipefail

# =============================================================================
# Landscape Mini - Minimal x86 UEFI Image Builder
# Uses debootstrap instead of the Armbian build system for a much smaller image
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration
if [ -f "${SCRIPT_DIR}/build.env" ]; then
    source "${SCRIPT_DIR}/build.env"
else
    echo "ERROR: build.env not found in ${SCRIPT_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse command line arguments
# ---------------------------------------------------------------------------
SKIP_TO_PHASE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-docker)
            INCLUDE_DOCKER="yes"
            shift
            ;;
        --version)
            if [[ -n "${2:-}" ]]; then
                LANDSCAPE_VERSION="$2"
                shift 2
            else
                echo "ERROR: --version requires a value (e.g. --version v0.12.4)"
                exit 1
            fi
            ;;
        --skip-to)
            if [[ -n "${2:-}" && "${2:-}" =~ ^[1-8]$ ]]; then
                SKIP_TO_PHASE="$2"
                shift 2
            else
                echo "ERROR: --skip-to requires a phase number (1-8)"
                exit 1
            fi
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--with-docker] [--version VERSION] [--skip-to PHASE]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
WORK_DIR="$(pwd)/work"
OUTPUT_DIR="$(pwd)/output"
ROOTFS_DIR="${WORK_DIR}/rootfs"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
LOOP_DEV=""

# Docker suffix and image size adjustment
IMAGE_SUFFIX=""
if [[ "${INCLUDE_DOCKER}" == "yes" ]]; then
    IMAGE_SUFFIX="-docker"
    [[ "${IMAGE_SIZE_MB}" -lt 2048 ]] && IMAGE_SIZE_MB=2048
fi

IMAGE_FILE="${OUTPUT_DIR}/landscape-mini-x86${IMAGE_SUFFIX}.img"

# Determine download base URL
if [ "${LANDSCAPE_VERSION}" == "latest" ]; then
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/latest/download"
else
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/download/${LANDSCAPE_VERSION}"
fi

# Default Debian mirror
DEFAULT_MIRROR="http://deb.debian.org/debian"
MIRROR="${APT_MIRROR:-${DEFAULT_MIRROR}}"

echo "============================================================"
echo "  Landscape Mini - x86 UEFI Image Builder"
echo "============================================================"
echo "  Landscape Version : ${LANDSCAPE_VERSION}"
echo "  Download Source    : ${DOWNLOAD_BASE}"
echo "  Debian Release    : ${DEBIAN_RELEASE}"
echo "  Image Size        : ${IMAGE_SIZE_MB} MB"
echo "  Include Docker    : ${INCLUDE_DOCKER}"
echo "  APT Mirror        : ${MIRROR}"
echo "  Output Format     : ${OUTPUT_FORMAT}"
echo "  Compress Output   : ${COMPRESS_OUTPUT}"
echo "============================================================"

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

trap cleanup EXIT ERR

# ---------------------------------------------------------------------------
# Helper: run a command inside the chroot
# ---------------------------------------------------------------------------
run_in_chroot() {
    LANG=C.UTF-8 LC_ALL=C.UTF-8 chroot "${ROOTFS_DIR}" /bin/bash -c "$1"
}

# =============================================================================
# Phase 1: Download Landscape
# =============================================================================
phase_download() {
    echo ""
    echo "==== Phase 1: Downloading Landscape ===="

    mkdir -p "${DOWNLOAD_DIR}"

    local bin_url="${DOWNLOAD_BASE}/landscape-webserver-x86_64"
    local bin_file="${DOWNLOAD_DIR}/landscape-webserver-x86_64"
    local static_url="${DOWNLOAD_BASE}/static.zip"
    local static_file="${DOWNLOAD_DIR}/static.zip"

    if [[ -f "${bin_file}" ]]; then
        echo "  [OK] landscape-webserver-x86_64 already downloaded."
    else
        echo "  [DOWNLOADING] landscape-webserver-x86_64 ..."
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

    # Partition with GPT: BIOS boot (1-2MiB) + ESP (2-66MiB) + root (66MiB - 100%)
    echo "  Partitioning (GPT: BIOS + UEFI hybrid) ..."
    parted -s "${IMAGE_FILE}" \
        mklabel gpt \
        mkpart bios 1MiB 2MiB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 66MiB \
        set 2 esp on \
        mkpart root ext4 66MiB 100%

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
# Phase 3: Bootstrap Debian
# =============================================================================
phase_bootstrap() {
    echo ""
    echo "==== Phase 3: Bootstrapping Debian (${DEBIAN_RELEASE}) ===="

    echo "  Running debootstrap --variant=minbase ..."
    debootstrap \
        --variant=minbase \
        --include=systemd,systemd-sysv,dbus \
        "${DEBIAN_RELEASE}" \
        "${ROOTFS_DIR}" \
        "${MIRROR}"

    echo "  Phase 3 complete."
}

# =============================================================================
# Phase 4: Configure System
# =============================================================================
phase_configure() {
    echo ""
    echo "==== Phase 4: Configuring System ===="

    # Mount bind filesystems for chroot
    echo "  Mounting special filesystems for chroot ..."
    mount --bind /dev "${ROOTFS_DIR}/dev"
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys"

    # ---- APT sources.list ----
    echo "  Writing /etc/apt/sources.list ..."
    cat > "${ROOTFS_DIR}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${MIRROR} ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb ${MIRROR} ${DEBIAN_RELEASE}-backports main contrib non-free non-free-firmware
EOF

    # ---- Hostname ----
    echo "  Setting hostname ..."
    echo "landscape" > "${ROOTFS_DIR}/etc/hostname"
    cat > "${ROOTFS_DIR}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   landscape
::1         localhost ip6-localhost ip6-loopback
EOF

    # ---- fstab ----
    echo "  Writing /etc/fstab ..."
    local ROOT_UUID
    local EFI_UUID
    ROOT_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p3")
    EFI_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p2")

    cat > "${ROOTFS_DIR}/etc/fstab" <<EOF
# <filesystem>                          <mount>     <type>  <options>           <dump>  <pass>
UUID=${ROOT_UUID}   /           ext4    errors=remount-ro   0       1
UUID=${EFI_UUID}    /boot/efi   vfat    umask=0077          0       2
EOF

    # ---- Prevent docs/locale from ever being installed ----
    echo "  Configuring dpkg path exclusions ..."
    mkdir -p "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d"
    cat > "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d/01-nodoc" <<'EOF'
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
EOF

    # ---- Set initramfs to dep mode with explicit boot modules ----
    echo "  Configuring initramfs MODULES=dep ..."
    mkdir -p "${ROOTFS_DIR}/etc/initramfs-tools/conf.d"
    echo "MODULES=dep" > "${ROOTFS_DIR}/etc/initramfs-tools/conf.d/modules-dep"
    # Force-include essential boot modules (chroot can't detect target hardware)
    cat > "${ROOTFS_DIR}/etc/initramfs-tools/modules" <<'EOF'
# Storage drivers (virtio for QEMU/KVM, ahci/ata for bare metal)
ext4
virtio_pci
virtio_blk
virtio_scsi
sd_mod
ahci
ata_piix
ata_generic
# EFI partition
vfat
nls_cp437
nls_ascii
EOF

    # ---- Install packages ----
    echo "  Installing packages (this may take a while) ..."
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends \
            linux-image-amd64 \
            grub-efi-amd64 \
            grub-pc-bin \
            initramfs-tools \
            e2fsprogs \
            zstd \
            iproute2 \
            iptables \
            bpftool \
            ppp \
            tcpdump \
            curl \
            ca-certificates \
            unzip \
            sudo \
            openssh-server
    "

    # ---- GRUB configuration ----
    echo "  Configuring GRUB ..."
    cat > "${ROOTFS_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Landscape"
GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0 console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"
EOF

    run_in_chroot "
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=landscape \
            --removable \
            --no-nvram
        grub-install \
            --target=i386-pc \
            ${LOOP_DEV}
        update-grub
    "

    # ---- Timezone ----
    echo "  Setting timezone to ${TIMEZONE} ..."
    run_in_chroot "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"

    # ---- Locale (without locales package) ----
    echo "  Configuring locale (${LOCALE}) ..."
    echo "LANG=${LOCALE}" > "${ROOTFS_DIR}/etc/default/locale"

    # ---- Root password ----
    echo "  Setting root password ..."
    run_in_chroot "echo 'root:${ROOT_PASSWORD}' | chpasswd"

    # ---- Create user 'ld' ----
    echo "  Creating user 'ld' ..."
    run_in_chroot "
        useradd -m -s /bin/bash -G sudo ld
        echo 'ld:${ROOT_PASSWORD}' | chpasswd
    "

    # ---- Enable sshd ----
    echo "  Enabling sshd ..."
    run_in_chroot "systemctl enable ssh.service"

    # ---- Allow root password login via SSH ----
    echo "  Configuring SSH root login ..."
    mkdir -p "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
    cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/root-login.conf" <<'EOF'
PermitRootLogin yes
EOF

    # ---- Disable unnecessary network services ----
    echo "  Disabling conflicting network services ..."
    run_in_chroot "
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true
        systemctl mask NetworkManager 2>/dev/null || true
        systemctl mask wpa_supplicant 2>/dev/null || true
    "

    # ---- Network interfaces (loopback only) ----
    echo "  Writing /etc/network/interfaces ..."
    mkdir -p "${ROOTFS_DIR}/etc/network"
    cat > "${ROOTFS_DIR}/etc/network/interfaces" <<EOF
# All network functions are managed by Landscape Router
auto lo
iface lo inet loopback
EOF

    # ---- DNS resolver ----
    echo "  Writing /etc/resolv.conf ..."
    rm -f "${ROOTFS_DIR}/etc/resolv.conf"
    echo "nameserver 114.114.114.114" > "${ROOTFS_DIR}/etc/resolv.conf"

    echo "  Phase 4 complete."
}

# =============================================================================
# Phase 5: Install Landscape Router
# =============================================================================
phase_install_landscape() {
    echo ""
    echo "==== Phase 5: Installing Landscape Router ===="

    # Copy the landscape binary
    echo "  Installing landscape-webserver binary ..."
    cp "${DOWNLOAD_DIR}/landscape-webserver-x86_64" "${ROOTFS_DIR}/root/landscape-webserver"
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

    # Copy systemd service file
    if [[ -f "${SCRIPT_DIR}/rootfs/etc/systemd/system/landscape-router.service" ]]; then
        echo "  Installing landscape-router.service from rootfs/ ..."
        cp "${SCRIPT_DIR}/rootfs/etc/systemd/system/landscape-router.service" \
            "${ROOTFS_DIR}/etc/systemd/system/landscape-router.service"
    else
        echo "  [GENERATE] Creating landscape-router.service ..."
        cat > "${ROOTFS_DIR}/etc/systemd/system/landscape-router.service" <<'EOF'
[Unit]
Description=Landscape Router
After=local-fs.target

[Service]
ExecStart=/bin/bash -c 'if [ ! -f /root/.landscape-router/landscape_init.toml ]; then exec /root/landscape-webserver --auto; else exec /root/landscape-webserver; fi'
Restart=always
User=root
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
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

    # Enable the service
    echo "  Enabling landscape-router.service ..."
    run_in_chroot "systemctl enable landscape-router.service"

    echo "  Phase 5 complete."
}

# =============================================================================
# Phase 6: Optional Docker Installation
# =============================================================================
phase_install_docker() {
    if [[ "${INCLUDE_DOCKER}" != "yes" ]]; then
        echo ""
        echo "==== Phase 6: Docker Installation (skipped) ===="
        return 0
    fi

    echo ""
    echo "==== Phase 6: Installing Docker ===="

    # Install prerequisites
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
    "

    # Add Docker GPG key
    echo "  Adding Docker GPG key ..."
    run_in_chroot "
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    "

    # Add Docker repository
    echo "  Adding Docker repository ..."
    local ARCH
    ARCH=$(run_in_chroot "dpkg --print-architecture")
    run_in_chroot "
        echo 'deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DEBIAN_RELEASE} stable' \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -y
    "

    # Install Docker packages
    echo "  Installing Docker packages ..."
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    "

    # Configure Docker daemon
    echo "  Configuring Docker daemon ..."
    mkdir -p "${ROOTFS_DIR}/etc/docker"
    cat > "${ROOTFS_DIR}/etc/docker/daemon.json" <<'EOF'
{
    "bip": "172.18.1.1/24",
    "dns": ["172.18.1.1"]
}
EOF

    # Enable Docker service
    echo "  Enabling Docker service ..."
    run_in_chroot "systemctl enable docker.service"

    echo "  Phase 6 complete."
}

# =============================================================================
# Phase 7: Cleanup & Shrink Image
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
        if [ -n \"\$KDIR\" ]; then
            # === Top-level subsystems ===
            rm -rf \"\$KDIR/sound\"

            # === drivers/ — bulk removal ===
            for d in media gpu infiniband iio comedi staging hid input video \
                     bluetooth scsi usb platform md hwmon mtd misc target \
                     accel mmc watchdog isdn edac char i2c crypto nvme; do
                rm -rf \"\$KDIR/drivers/\$d\"
            done

            # === drivers/net/ — keep ethernet, phy, bonding, ppp, vxlan, wireguard, hyperv ===
            for d in usb can wwan arcnet fddi hamradio ieee802154 wan wireless; do
                rm -rf \"\$KDIR/drivers/net/\$d\"
            done

            # === net/ — remove unused network stacks ===
            for d in bluetooth mac80211 wireless sunrpc ceph tipc nfc rxrpc smc sctp; do
                rm -rf \"\$KDIR/net/\$d\"
            done

            # === fs/ — keep ext4, fat, fuse, overlay, nls (needed by vfat) ===
            for d in bcachefs btrfs xfs ocfs2 f2fs jfs reiserfs gfs2 nilfs2 orangefs coda \
                     smb nfs nfsd ceph ubifs afs ntfs3 dlm jffs2 udf netfs; do
                rm -rf \"\$KDIR/fs/\$d\"
            done

            # Rebuild module dependencies
            KVER=\$(ls /usr/lib/modules/ | head -1)
            depmod \"\$KVER\" 2>/dev/null || true
        fi
    "

    # ---- Rebuild initramfs with fewer modules ----
    echo "  Rebuilding smaller initramfs ..."
    run_in_chroot "
        KVER=\$(ls /usr/lib/modules/ | head -1)
        update-initramfs -u -k \"\$KVER\" 2>/dev/null || true
    "

    # ---- Clean up GRUB leftovers ----
    echo "  Cleaning GRUB locale and modules ..."
    rm -rf "${ROOTFS_DIR}/boot/grub/locale"
    # Remove GRUB modules source (not needed at runtime, EFI already installed)
    rm -rf "${ROOTFS_DIR}/usr/lib/grub"

    # ---- Aggressive locale/i18n cleanup ----
    echo "  Cleaning locale and i18n data ..."
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        # Remove libc-l10n translations (4.7M)
        apt-get purge -y --auto-remove libc-l10n 2>/dev/null || true

        # Remove all locales except en_US
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
            ! -name 'en_US' ! -name 'en' ! -name 'locale-archive' \
            -exec rm -rf {} + 2>/dev/null || true

        # Keep only UTF-8 charmap, remove others (save ~3M)
        find /usr/share/i18n/charmaps -type f ! -name 'UTF-8.gz' -delete 2>/dev/null || true

        # Keep only en_US and en_GB locale definitions
        find /usr/share/i18n/locales -type f \
            ! -name 'en_US' ! -name 'en_GB' ! -name 'i18n*' ! -name 'iso*' \
            ! -name 'translit_*' ! -name 'POSIX' \
            -delete 2>/dev/null || true

        # Trim gconv - keep only essential charset converters (save ~7M)
        GCONV_DIR=/usr/lib/x86_64-linux-gnu/gconv
        if [ -d \"\$GCONV_DIR\" ]; then
            find \"\$GCONV_DIR\" -name '*.so' \
                ! -name 'UTF*' ! -name 'UNICODE*' ! -name 'ASCII*' \
                ! -name 'ISO8859*' ! -name 'LATIN*' \
                -delete 2>/dev/null || true
            # Rebuild gconv cache
            iconvconfig 2>/dev/null || true
        fi
    "

    # ---- Truncate udev hwdb (saves ~13M) ----
    echo "  Truncating udev hardware database ..."
    rm -rf "${ROOTFS_DIR}/usr/lib/udev/hwdb.d"
    : > "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin"

    # ---- Generate SSH host keys ----
    # Note: sshd-keygen.service (ConditionFirstBoot=yes) won't trigger because
    # machine-id is already set during debootstrap, so generate keys at build time.
    echo "  Generating SSH host keys ..."
    run_in_chroot "ssh-keygen -A"

    # ---- Purge build-only packages (saves ~10-15M) ----
    echo "  Purging build-only packages ..."
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        dpkg --purge --force-depends \
            grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-unsigned \
            grub-pc-bin grub-common grub2-common \
            initramfs-tools initramfs-tools-core initramfs-tools-bin \
            klibc-utils libklibc dracut-install cpio \
            unzip e2fsprogs 2>/dev/null || true
        apt-get -y --purge autoremove 2>/dev/null || true
    "

    # ---- Strip all binaries and shared libraries (saves ~3-5M) ----
    echo "  Stripping binaries and shared libraries ..."
    run_in_chroot "
        find /usr/bin /usr/sbin /usr/lib -type f \
            \( -name '*.so*' -o -executable \) \
            -exec strip --strip-unneeded {} + 2>/dev/null || true
    "

    # ---- General cleanup ----
    echo "  Cleaning caches and unnecessary files ..."
    run_in_chroot "
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/lintian/*
        rm -rf /usr/share/bash-completion/*
        rm -rf /usr/share/common-licenses/*
        rm -rf /usr/share/perl5/*
        rm -f /var/log/*.log
        rm -rf /tmp/*
        rm -rf /var/tmp/*
    "

    # Unmount special filesystems
    echo "  Unmounting special filesystems ..."
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true

    # Unmount EFI partition
    echo "  Unmounting EFI partition ..."
    umount "${ROOTFS_DIR}/boot/efi" 2>/dev/null || true

    # ---- Clean journal AFTER special fs unmounted (prevents recreation) ----
    echo "  Cleaning journal logs ..."
    rm -rf "${ROOTFS_DIR}/var/log/journal"

    # Unmount root BEFORE e2fsck/resize2fs (cannot operate on mounted fs)
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

    # Partition 3 starts at sector 135168 (66MiB = 69206016 bytes / 512)
    local PART3_START_SECTOR=135168
    # Calculate new partition end sector (aligned to 2048-sector / 1MiB boundary)
    local ROOT_SECTORS=$(( ROOT_BYTES / 512 ))
    # Align up to next 2048-sector boundary, then subtract 1 (sgdisk end is inclusive)
    local PART3_END_SECTOR=$(( PART3_START_SECTOR + ROOT_SECTORS ))
    PART3_END_SECTOR=$(( ((PART3_END_SECTOR + 2047) / 2048) * 2048 - 1 ))
    # Total image: sector after partition end + 2048 sectors (1MiB) for GPT backup header
    local TOTAL_SECTORS=$(( PART3_END_SECTOR + 1 + 2048 ))
    local TOTAL_BYTES=$(( TOTAL_SECTORS * 512 ))

    # Save GRUB i386-pc boot code from MBR (first 440 bytes)
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
        -n 2:4096:135167 -t 2:EF00 -c 2:ESP \
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
# If skipping to a phase that needs the image mounted, re-attach it
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
    # Mount special filesystems for chroot
    mount --bind /dev "${ROOTFS_DIR}/dev"
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
}

# =============================================================================
# Main Execution
# =============================================================================
main() {
    # Check required tools
    for cmd in debootstrap parted losetup mkfs.vfat mkfs.ext4 blkid e2fsck resize2fs curl unzip; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo "ERROR: Required command '${cmd}' not found. Please install it first."
            exit 1
        fi
    done

    if [[ ${SKIP_TO_PHASE} -gt 0 ]]; then
        echo ""
        echo "==== Resuming from Phase ${SKIP_TO_PHASE} ===="
        echo "  Phase 1: Download      | Phase 5: Install Landscape"
        echo "  Phase 2: Create Image  | Phase 6: Install Docker"
        echo "  Phase 3: Bootstrap     | Phase 7: Cleanup & Shrink"
        echo "  Phase 4: Configure     | Phase 8: Report"
    fi

    # Phase 1: Download (always run unless skipping past it)
    [[ ${SKIP_TO_PHASE} -le 1 ]] && phase_download

    # Phase 2: Create image
    if [[ ${SKIP_TO_PHASE} -le 2 ]]; then
        phase_create_image
    elif [[ ${SKIP_TO_PHASE} -le 7 ]]; then
        # Need to re-attach image for phases 3-7
        resume_from_image
    fi

    [[ ${SKIP_TO_PHASE} -le 3 ]] && phase_bootstrap
    [[ ${SKIP_TO_PHASE} -le 4 ]] && phase_configure
    [[ ${SKIP_TO_PHASE} -le 5 ]] && phase_install_landscape
    [[ ${SKIP_TO_PHASE} -le 6 ]] && phase_install_docker
    [[ ${SKIP_TO_PHASE} -le 7 ]] && phase_cleanup_and_shrink
    phase_report
}

main
