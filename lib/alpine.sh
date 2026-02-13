#!/bin/bash
# =============================================================================
# Landscape Mini - Alpine Linux Backend
# =============================================================================
# Provides Alpine-specific implementations of the backend_* interface.
# Sourced by build.sh when BASE_SYSTEM=alpine.
#
# Key differences from Debian:
#   - Uses apk instead of apt, OpenRC instead of systemd
#   - Requires gcompat (glibc compat layer) for landscape-webserver binary
#   - Uses mkinitfs instead of initramfs-tools
#   - Smaller footprint (~150MB vs ~312MB)
# =============================================================================

CHROOT_SHELL="/bin/sh"

# Alpine mirror (use build.env value)
# ALPINE_MIRROR is set by build.env (default: official Alpine CDN)

# ---------------------------------------------------------------------------
# Check host dependencies for Alpine builds
# ---------------------------------------------------------------------------
backend_check_deps() {
    for cmd in parted losetup mkfs.vfat mkfs.ext4 blkid e2fsck resize2fs curl unzip sgdisk; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo "ERROR: Required command '${cmd}' not found. Please install it first."
            exit 1
        fi
    done
    # Note: apk-tools-static is downloaded at runtime, no host dependency needed
}

# =============================================================================
# Phase 3: Bootstrap Alpine
# =============================================================================
backend_bootstrap() {
    echo ""
    echo "==== Phase 3: Bootstrapping Alpine (${ALPINE_RELEASE}) ===="

    local APK_TOOLS_DIR="${DOWNLOAD_DIR}/apk-tools"
    local APK_STATIC="${APK_TOOLS_DIR}/sbin/apk.static"

    # Download apk-tools-static if not cached
    if [[ ! -x "${APK_STATIC}" ]]; then
        echo "  Downloading apk-tools-static ..."
        mkdir -p "${APK_TOOLS_DIR}"
        local APK_TOOLS_URL="${ALPINE_MIRROR}/${ALPINE_RELEASE}/main/x86_64"
        local APK_TOOLS_PKG
        APK_TOOLS_PKG=$(curl -sL "${APK_TOOLS_URL}/" | grep -oP 'apk-tools-static-[0-9][^"]*\.apk' | head -1)
        if [[ -z "${APK_TOOLS_PKG}" ]]; then
            echo "ERROR: Could not find apk-tools-static package at ${APK_TOOLS_URL}/"
            exit 1
        fi
        curl -L -o "${APK_TOOLS_DIR}/apk-tools-static.apk" "${APK_TOOLS_URL}/${APK_TOOLS_PKG}"
        tar -xzf "${APK_TOOLS_DIR}/apk-tools-static.apk" -C "${APK_TOOLS_DIR}" sbin/apk.static 2>/dev/null || \
            tar -xf "${APK_TOOLS_DIR}/apk-tools-static.apk" -C "${APK_TOOLS_DIR}" sbin/apk.static
        chmod +x "${APK_STATIC}"
    else
        echo "  [OK] apk-tools-static already cached."
    fi

    # Bootstrap Alpine minimal root
    echo "  Running apk.static --initdb add alpine-base ..."
    mkdir -p "${ROOTFS_DIR}/etc/apk"
    echo "${ALPINE_MIRROR}/${ALPINE_RELEASE}/main" > "${ROOTFS_DIR}/etc/apk/repositories"
    echo "${ALPINE_MIRROR}/${ALPINE_RELEASE}/community" >> "${ROOTFS_DIR}/etc/apk/repositories"

    "${APK_STATIC}" \
        --root "${ROOTFS_DIR}" \
        --initdb \
        --update-cache \
        --allow-untrusted \
        --repositories-file "${ROOTFS_DIR}/etc/apk/repositories" \
        add alpine-base

    echo "  Phase 3 complete."
}

# =============================================================================
# Phase 4: Configure System (Alpine)
# =============================================================================
backend_configure() {
    echo ""
    echo "==== Phase 4: Configuring System (Alpine) ===="

    # Mount bind filesystems for chroot
    mount_chroot_fs

    # ---- DNS resolver (needed for apk to fetch packages) ----
    echo "  Copying host resolv.conf for package installation ..."
    cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf" 2>/dev/null || \
        echo "nameserver 8.8.8.8" > "${ROOTFS_DIR}/etc/resolv.conf"

    # ---- APK repositories ----
    echo "  Writing /etc/apk/repositories ..."
    cat > "${ROOTFS_DIR}/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/${ALPINE_RELEASE}/main
${ALPINE_MIRROR}/${ALPINE_RELEASE}/community
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

    # ---- Install packages ----
    echo "  Installing packages (this may take a while) ..."
    run_in_chroot "
        apk update
        apk add --no-cache \
            linux-lts linux-firmware-none \
            grub-efi grub-bios \
            mkinitfs \
            e2fsprogs e2fsprogs-extra \
            zstd \
            iproute2 \
            iptables ip6tables \
            bpftool \
            ppp \
            tcpdump \
            curl \
            ca-certificates \
            unzip \
            sudo \
            openssh \
            sgdisk \
            cloud-utils-growpart \
            iputils bind-tools mtr \
            libgcc zlib zstd-libs \
            openrc busybox-openrc busybox-mdev-openrc \
            losetup \
            findutils \
            dosfstools \
            util-linux \
            nano \
            iperf3
    "

    # ---- Configure mkinitfs features and rebuild initramfs ----
    echo "  Configuring mkinitfs ..."

    cat > "${ROOTFS_DIR}/etc/mkinitfs/mkinitfs.conf" <<'EOF'
features="ata base ext4 nvme scsi virtio xen"
EOF

    echo "  Building initramfs ..."
    run_in_chroot "
        KVER=\$(ls /lib/modules/ 2>/dev/null | grep lts | head -1)
        if [ -z \"\$KVER\" ]; then
            KVER=\$(ls /lib/modules/ | head -1)
        fi
        echo \"  Kernel version: \$KVER\"
        mkinitfs -c /etc/mkinitfs/mkinitfs.conf \"\$KVER\"
    "

    # ---- GRUB configuration ----
    echo "  Configuring GRUB ..."
    cat > "${ROOTFS_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Landscape"
GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0,115200n8 console=tty0"
GRUB_CMDLINE_LINUX="rootfstype=ext4 modules=ext4,sd_mod,vmw_pvscsi,mptspi,mptbase,mptscsih net.ifnames=0 biosdevname=0 nomodeset"
GRUB_TERMINAL=console
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
        grub-mkconfig -o /boot/grub/grub.cfg
    "

    # ---- Timezone ----
    echo "  Setting timezone to ${TIMEZONE} ..."
    run_in_chroot "
        apk add tzdata 2>/dev/null || true
        cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime 2>/dev/null || true
        echo '${TIMEZONE}' > /etc/timezone
        apk del tzdata 2>/dev/null || true
    "

    # ---- Locale ----
    echo "  Configuring locale (${LOCALE}) ..."
    mkdir -p "${ROOTFS_DIR}/etc/profile.d"
    cat > "${ROOTFS_DIR}/etc/profile.d/locale.sh" <<EOF
export LANG=${LOCALE}
export LC_ALL=${LOCALE}
EOF

    # ---- Root password ----
    echo "  Setting root password ..."
    run_in_chroot "echo 'root:${ROOT_PASSWORD}' | chpasswd"

    # ---- Create user 'ld' ----
    echo "  Creating user 'ld' ..."
    run_in_chroot "
        adduser -D -s /bin/sh -G wheel ld
        echo 'ld:${ROOT_PASSWORD}' | chpasswd
        echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel
    "

    # ---- Enable sshd ----
    echo "  Enabling sshd ..."
    run_in_chroot "rc-update add sshd default"

    # ---- Allow root password login via SSH ----
    echo "  Configuring SSH root login ..."
    mkdir -p "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
    cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/root-login.conf" <<'EOF'
PermitRootLogin yes
EOF

    # ---- Enable essential OpenRC services ----
    echo "  Enabling OpenRC services ..."
    run_in_chroot "
        rc-update add devfs sysinit
        rc-update add dmesg sysinit
        rc-update add mdev sysinit
        rc-update add hwdrivers sysinit

        rc-update add hwclock boot
        rc-update add modules boot
        rc-update add sysctl boot
        rc-update add hostname boot
        rc-update add bootmisc boot
        rc-update add syslog boot 2>/dev/null || true
        rc-update add networking boot

        rc-update add mount-ro shutdown
        rc-update add killprocs shutdown
        rc-update add savecache shutdown
    "

    # ---- Ensure nf_conntrack loads at boot (required for sysctl tuning) ----
    echo "  Configuring kernel modules to load at boot ..."
    echo "nf_conntrack" >> "${ROOTFS_DIR}/etc/modules"

    # ---- Network interfaces (loopback only) ----
    echo "  Writing /etc/network/interfaces ..."
    mkdir -p "${ROOTFS_DIR}/etc/network"
    cat > "${ROOTFS_DIR}/etc/network/interfaces" <<EOF
# All network functions are managed by Landscape Router
auto lo
iface lo inet loopback

# Fallback DHCP on eth0 — ensures SSH access even if landscape-router
# has not yet configured the interfaces (e.g. first boot with --auto).
auto eth0
iface eth0 inet dhcp
EOF

    # ---- DNS resolver ----
    echo "  Writing /etc/resolv.conf ..."
    rm -f "${ROOTFS_DIR}/etc/resolv.conf"
    echo "nameserver 114.114.114.114" > "${ROOTFS_DIR}/etc/resolv.conf"

    # ---- Enable serial console (for QEMU testing) ----
    echo "  Enabling serial console ..."
    if [ -f "${ROOTFS_DIR}/etc/inittab" ]; then
        # Uncomment existing serial console line if present
        sed -i 's|^#\(ttyS0::respawn.*\)|\1|' "${ROOTFS_DIR}/etc/inittab"
        # Add serial console if not present at all
        if ! grep -q "^ttyS0::" "${ROOTFS_DIR}/etc/inittab"; then
            echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" >> "${ROOTFS_DIR}/etc/inittab"
        fi
    else
        cat > "${ROOTFS_DIR}/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
tty1::respawn:/sbin/getty 38400 tty1
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF
    fi

    echo "  Phase 4 complete."
}

# ---------------------------------------------------------------------------
# Phase 5 backend: install OpenRC service files
# ---------------------------------------------------------------------------
backend_install_landscape_services() {
    # Install landscape-router OpenRC init script
    echo "  Installing landscape-router OpenRC service ..."
    mkdir -p "${ROOTFS_DIR}/etc/init.d"
    cp "${SCRIPT_DIR}/rootfs/etc/init.d/landscape-router" \
        "${ROOTFS_DIR}/etc/init.d/landscape-router"
    chmod +x "${ROOTFS_DIR}/etc/init.d/landscape-router"

    # Install expand-rootfs OpenRC init script
    echo "  Installing expand-rootfs OpenRC service ..."
    cp "${SCRIPT_DIR}/rootfs/etc/init.d/expand-rootfs" \
        "${ROOTFS_DIR}/etc/init.d/expand-rootfs"
    chmod +x "${ROOTFS_DIR}/etc/init.d/expand-rootfs"

    # Enable services
    echo "  Enabling landscape-router service ..."
    run_in_chroot "rc-update add landscape-router default"
    echo "  Enabling expand-rootfs service ..."
    run_in_chroot "rc-update add expand-rootfs boot"
}

# =============================================================================
# Phase 6: Optional Docker Installation (Alpine)
# =============================================================================
backend_install_docker() {
    if [[ "${INCLUDE_DOCKER}" != "yes" ]]; then
        echo ""
        echo "==== Phase 6: Docker Installation (skipped) ===="
        return 0
    fi

    echo ""
    echo "==== Phase 6: Installing Docker (Alpine) ===="

    run_in_chroot "
        apk add docker docker-cli-compose docker-cli-buildx
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
    run_in_chroot "rc-update add docker default"

    echo "  Phase 6 complete."
}

# ---------------------------------------------------------------------------
# Phase 7 backend: Alpine-specific cleanup
# ---------------------------------------------------------------------------
backend_cleanup() {
    # ---- Remove bloated bpftool dependencies ----
    # Alpine's bpftool package pulls in perf → python3 (~31MB), binutils (~10MB),
    # libstdc++, libslang, etc.  apk refuses to remove them (bpftool depends on
    # perf), so we force-delete the files after saving what we need.
    echo "  Removing bloated bpftool dependencies ..."
    run_in_chroot "
        # perf / trace / cpupower / linux-tools (18MB+)
        rm -f /usr/bin/perf /usr/bin/trace /usr/bin/cpupower
        rm -rf /usr/share/perf-core /usr/libexec/perf-core

        # binutils — only bpftool needs libbfd/libopcodes at runtime
        rm -f /usr/bin/dwp /usr/bin/ld /usr/bin/ld.bfd /usr/bin/as
        rm -f /usr/bin/readelf /usr/bin/objdump /usr/bin/objcopy
        rm -f /usr/bin/strip /usr/bin/strings /usr/bin/nm /usr/bin/addr2line
        rm -f /usr/bin/size /usr/bin/ranlib /usr/bin/ar /usr/bin/elfedit
        rm -f /usr/bin/gprof /usr/bin/c++filt
        rm -rf /usr/x86_64-alpine-linux-musl

        # python3 — only needed by perf (now removed)
        rm -rf /usr/lib/python3* /usr/lib/libpython3* /usr/bin/python3*

        # libslang — only needed by perf TUI
        rm -f /usr/lib/libslang.so* /usr/lib/slang/
        rm -rf /usr/share/slsh

        # libstdc++ — needed by bpftool? check later, keep for safety
    "

    # ---- Remove unnecessary boot/grub files ----
    echo "  Removing unnecessary boot files ..."
    rm -f "${ROOTFS_DIR}"/boot/System.map-* "${ROOTFS_DIR}"/boot/config-*
    # GRUB unicode font (2.4MB) — not needed for serial/headless console
    rm -rf "${ROOTFS_DIR}"/boot/grub/fonts
    # GRUB utilities not needed at runtime (only used during install)
    rm -f "${ROOTFS_DIR}"/usr/bin/grub-*
    rm -f "${ROOTFS_DIR}"/usr/sbin/grub-{mkrescue,fstest,render-label,file,syslinux2cfg,sparc64-setup,macbless,ofpathname,mkstandalone}
    rm -rf "${ROOTFS_DIR}"/usr/share/grub

    # ---- Rebuild initramfs ----
    echo "  Rebuilding mkinitfs ..."
    run_in_chroot "
        KVER=\$(ls /lib/modules/ 2>/dev/null | grep lts | head -1)
        if [ -z \"\$KVER\" ]; then
            KVER=\$(ls /lib/modules/ | head -1)
        fi
        if [ -n \"\$KVER\" ]; then
            mkinitfs -c /etc/mkinitfs/mkinitfs.conf \"\$KVER\"
        fi
    "

    # ---- Clean apk cache ----
    echo "  Cleaning apk cache ..."
    run_in_chroot "
        apk cache clean 2>/dev/null || true
        rm -rf /var/cache/apk/*
    "
}
