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
#
# All package operations run host-side via apk-tools-static with --root, so no
# chroot or bind mounts are needed for apk itself (works root and rootless).
# =============================================================================

CHROOT_SHELL="/bin/sh"

# ---------------------------------------------------------------------------
# Check host dependencies for Alpine builds
# ---------------------------------------------------------------------------
backend_check_deps() {
    # Core deps (mkfs/mtools/sgdisk/grub/engine) are checked by check_core_deps.
    true
}

# ---------------------------------------------------------------------------
# Shared apk.static invocation: host-side, persistent cache, no mounts
# ---------------------------------------------------------------------------
ALPINE_APK_STATIC=""

alpine_apk() {
    local output rc

    if [[ -z "${ALPINE_APK_STATIC}" ]]; then
        # Phase 3 may have been skipped on resumed builds; locate the cached
        # apk.static lazily so later phases keep working.
        ALPINE_APK_STATIC="${DOWNLOAD_DIR}/apk-tools/sbin/apk.static"
        if [[ ! -x "${ALPINE_APK_STATIC}" ]]; then
            echo "ERROR: apk.static not found at ${ALPINE_APK_STATIC}; run phase 3 first." >&2
            return 1
        fi
    fi

    set +e
    output=$(run_as_build_root "${ALPINE_APK_STATIC}" \
        --root "${ROOTFS_DIR}" \
        --cache-dir "${CACHE_DIR}/apk" \
        "$@" 2>&1)
    rc=$?
    set -e
    printf '%s\n' "${output}"

    if [[ ${rc} -eq 0 ]]; then
        return 0
    fi

    # Rootless builds run apk inside a user namespace that only maps uid/gid 0,
    # so apk cannot restore ownership of files owned by other accounts (e.g.
    # setgid utilities). apk flags those as fatal even though every package
    # was unpacked and configured — tolerate ownership-only failures there.
    # Note: on re-runs against an already-installed set, apk repeats the same
    # fixup failures but only surfaces them via the "N errors;" summary line.
    if [[ "${BUILD_PRIVILEGE}" == "rootless" ]] \
        && ! printf '%s\n' "${output}" | grep -E '^ERROR:' | grep -Ev 'Failed to set ownership' | grep -q . \
        && printf '%s\n' "${output}" | grep -Eq '(^ERROR: Failed to set ownership|^[0-9]+ errors; )'; then
        echo "  [WARN] apk finished with ownership-only errors (unmapped uid/gid in the build namespace); continuing."
        return 0
    fi

    return "${rc}"
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
        local APK_TOOLS_URL="${RESOLVED_ALPINE_MIRROR}/${ALPINE_RELEASE}/main/x86_64"
        local APK_TOOLS_PKG
        APK_TOOLS_PKG=$(curl -fsSL --retry 3 --retry-delay 2 "${APK_TOOLS_URL}/" | grep -oE 'apk-tools-static-[0-9][^"]*\.apk' | head -1)
        if [[ -z "${APK_TOOLS_PKG}" ]]; then
            echo "ERROR: Could not find apk-tools-static package at ${APK_TOOLS_URL}/"
            exit 1
        fi
        retry_command 3 5 curl -fL --retry 3 --retry-delay 2 -o "${APK_TOOLS_DIR}/apk-tools-static.apk" "${APK_TOOLS_URL}/${APK_TOOLS_PKG}"
        tar -xzf "${APK_TOOLS_DIR}/apk-tools-static.apk" -C "${APK_TOOLS_DIR}" sbin/apk.static 2>/dev/null || \
            tar -xf "${APK_TOOLS_DIR}/apk-tools-static.apk" -C "${APK_TOOLS_DIR}" sbin/apk.static
        chmod +x "${APK_STATIC}"
    else
        echo "  [OK] apk-tools-static already cached."
    fi
    ALPINE_APK_STATIC="${APK_STATIC}"
    mkdir -p "${CACHE_DIR}/apk"

    # Bootstrap Alpine minimal root
    echo "  Running apk.static --initdb add alpine-base ..."
    # Start from a clean tree: apk does not remove files a previous, larger
    # build left behind, so stale packages would leak into the new image.
    umount_chroot_fs
    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}/etc/apk"
    echo "${RESOLVED_ALPINE_MIRROR}/${ALPINE_RELEASE}/main" > "${ROOTFS_DIR}/etc/apk/repositories"
    echo "${RESOLVED_ALPINE_MIRROR}/${ALPINE_RELEASE}/community" >> "${ROOTFS_DIR}/etc/apk/repositories"

    retry_command 3 5 alpine_apk \
        --initdb \
        --allow-untrusted \
        add alpine-base

    echo "  Phase 3 complete."
}

# =============================================================================
# Phase 4: Configure System (Alpine)
# =============================================================================
backend_configure() {
    echo ""
    echo "==== Phase 4: Configuring System (Alpine) ===="

    # Mount bind filesystems for the classic chroot engine (no-op otherwise)
    mount_chroot_fs

    # ---- APK repositories ----
    echo "  Writing /etc/apk/repositories ..."
    cat > "${ROOTFS_DIR}/etc/apk/repositories" <<EOF
${RESOLVED_ALPINE_MIRROR}/${ALPINE_RELEASE}/main
${RESOLVED_ALPINE_MIRROR}/${ALPINE_RELEASE}/community
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
    cat > "${ROOTFS_DIR}/etc/fstab" <<EOF
# <filesystem>                          <mount>     <type>  <options>           <dump>  <pass>
UUID=${ROOT_UUID}   /           ext4    errors=remount-ro   0       1
UUID=$(esp_uuid_pretty)    /boot/efi   vfat    umask=0077          0       2
EOF

    # ---- Install packages ----
    echo "  Installing packages (this may take a while) ..."
    # Keep targeted wired-NIC firmware only. Avoid the full linux-firmware meta-package,
    # which pulls in large GPU/Wi-Fi/SoC firmware sets unrelated to this x86 router image.
    # Downloaded packages persist in the host-side cache dir for faster rebuilds.
    retry_command 3 5 alpine_apk add \
        linux-lts \
        linux-firmware-rtl_nic \
        linux-firmware-bnx2 \
        linux-firmware-bnx2x \
        linux-firmware-e100 \
        mkinitfs \
        e2fsprogs e2fsprogs-extra \
        zstd \
        iproute2 \
        iptables ip6tables \
        bpftool \
        ppp \
        tcpdump \
        ethtool \
        pciutils \
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

    # ---- Configure mkinitfs features and rebuild initramfs ----
    echo "  Configuring mkinitfs ..."

    cat > "${ROOTFS_DIR}/etc/mkinitfs/mkinitfs.conf" <<'EOF'
features="ata base ext4 nvme scsi virtio xen"
EOF

    echo "  Building initramfs ..."
    run_rootfs_cmd "
        KVER=\$(ls /lib/modules/ 2>/dev/null | grep lts | head -1)
        if [ -z \"\$KVER\" ]; then
            KVER=\$(ls /lib/modules/ | head -1)
        fi
        echo \"  Kernel version: \$KVER\"
        mkinitfs -c /etc/mkinitfs/mkinitfs.conf \"\$KVER\"
    "

    # ---- GRUB configuration ----
    # The bootloader itself is installed host-side in Phase 7 (offline image
    # assembly); only the defaults file is written into the rootfs.
    echo "  Writing /etc/default/grub ..."
    mkdir -p "${ROOTFS_DIR}/etc/default"
    cat > "${ROOTFS_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Landscape"
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX="rootfstype=ext4 modules=ext4,sd_mod,vmw_pvscsi,mptspi,mptbase,mptscsih net.ifnames=0 biosdevname=0 nomodeset"
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

    # ---- Timezone ----
    echo "  Setting timezone to ${TIMEZONE} ..."
    retry_command 3 5 alpine_apk add tzdata
    cp "${ROOTFS_DIR}/usr/share/zoneinfo/${TIMEZONE}" "${ROOTFS_DIR}/etc/localtime" 2>/dev/null || true
    echo "${TIMEZONE}" > "${ROOTFS_DIR}/etc/timezone"
    alpine_apk del tzdata 2>/dev/null || true

    # ---- Locale ----
    echo "  Configuring locale (${LOCALE}) ..."
    mkdir -p "${ROOTFS_DIR}/etc/profile.d"
    cat > "${ROOTFS_DIR}/etc/profile.d/locale.sh" <<EOF
export LANG=${LOCALE}
export LC_ALL=${LOCALE}
EOF

    # ---- Root password ----
    echo "  Setting root password ..."
    run_rootfs_cmd "echo 'root:${ROOT_PASSWORD}' | chpasswd"

    # ---- Create user 'ld' (fixed uid 1000) ----
    # Rootless builds cannot chown to unmapped uids, so the home directory is
    # created host-side (owned by the build user) and fixed up on first boot
    # by the expand-rootfs hook.
    echo "  Creating user 'ld' ..."
    if [[ "${BUILD_PRIVILEGE}" == "root" ]]; then
        run_rootfs_cmd "
            adduser -D -u 1000 -s /bin/sh -G wheel ld
            echo 'ld:${ROOT_PASSWORD}' | chpasswd
        "
    else
        run_rootfs_cmd "
            adduser -D -H -u 1000 -s /bin/sh -G wheel ld
            echo 'ld:${ROOT_PASSWORD}' | chpasswd
        "
        mkdir -p "${ROOTFS_DIR}/home/ld"
        if [[ -d "${ROOTFS_DIR}/etc/skel" ]]; then
            cp -a "${ROOTFS_DIR}/etc/skel/." "${ROOTFS_DIR}/home/ld/"
        fi
    fi
    run_rootfs_cmd "echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel"

    # ---- Enable sshd ----
    echo "  Enabling sshd ..."
    run_rootfs_cmd "rc-update add sshd default"

    # ---- Allow root password login via SSH ----
    echo "  Configuring SSH root login ..."
    mkdir -p "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
    cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/root-login.conf" <<'EOF'
PermitRootLogin yes
EOF

    # ---- Enable essential OpenRC services ----
    echo "  Enabling OpenRC services ..."
    run_rootfs_cmd "
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

    # ---- Network interfaces (loopback + eth0 fallback) ----
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

    # ---- Image default DNS resolver ----
    configure_image_resolver

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
# GRUB hooks for the host-side grub.cfg renderer
# ---------------------------------------------------------------------------
backend_grub_kernel_path() {
    local kernel
    kernel=$(ls "${ROOTFS_DIR}/boot/vmlinuz-"* 2>/dev/null | head -1)
    [[ -n "${kernel}" ]] || return 1
    echo "/boot/$(basename "${kernel}")"
}

backend_grub_initrd_path() {
    local initrd
    initrd=$(ls "${ROOTFS_DIR}/boot/initramfs-"* 2>/dev/null | head -1)
    [[ -n "${initrd}" ]] || return 1
    echo "/boot/$(basename "${initrd}")"
}

backend_grub_cmdline_extra() {
    echo "rootfstype=ext4 modules=ext4,sd_mod,vmw_pvscsi,mptspi,mptbase,mptscsih net.ifnames=0 biosdevname=0 nomodeset console=ttyS0,115200n8"
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

    # Install local.d hook for expand-rootfs
    echo "  Installing expand-rootfs local.d hook ..."
    mkdir -p "${ROOTFS_DIR}/etc/local.d"
    cp "${SCRIPT_DIR}/rootfs/etc/local.d/expand-rootfs.start" \
        "${ROOTFS_DIR}/etc/local.d/expand-rootfs.start"
    chmod +x "${ROOTFS_DIR}/etc/local.d/expand-rootfs.start"

    # Enable services
    echo "  Enabling landscape-router service ..."
    run_rootfs_cmd "rc-update add landscape-router default"
    echo "  Enabling local service ..."
    run_rootfs_cmd "rc-update add local default"
}

# =============================================================================
# Phase 6: Optional Docker Installation (Alpine)
# =============================================================================
backend_install_docker() {
    if [[ "${INCLUDE_DOCKER}" != "true" ]]; then
        echo ""
        echo "==== Phase 6: Docker Installation (skipped) ===="
        return 0
    fi

    echo ""
    echo "==== Phase 6: Installing Docker (Alpine) ===="
    echo "  Docker packages follow ALPINE_MIRROR=${RESOLVED_ALPINE_MIRROR}"

    retry_command 3 5 alpine_apk add docker docker-cli-compose docker-cli-buildx

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
    run_rootfs_cmd "rc-update add docker default"

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
    run_rootfs_cmd "
        # perf / trace / cpupower / linux-tools (18MB+)
        rm -f /usr/bin/perf /usr/bin/trace /usr/bin/cpupower
        rm -rf /usr/share/perf-core /usr/libexec/perf-core

        # binutils — only bpftool needs libbfd/libopcodes at runtime
        rm -f /usr/bin/dwp /usr/bin/ld /usr/bin/ld.bfd /usr/bin/as
        rm -f /usr/bin/readelf /usr/bin/objdump /usr/bin/objcopy
        rm -f /usr/bin/strip /usr/bin/nm /usr/bin/addr2line
        rm -f /usr/bin/size /usr/bin/ranlib /usr/bin/ar /usr/bin/elfedit
        rm -f /usr/bin/gprof /usr/bin/c++filt
        rm -rf /usr/x86_64-alpine-linux-musl

        # python3 — only needed by perf (now removed)
        rm -rf /usr/lib/python3* /usr/lib/libpython3* /usr/bin/python3*

        # libslang — only needed by perf TUI
        rm -f /usr/lib/libslang.so*
        rm -rf /usr/lib/slang
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
    run_rootfs_cmd "
        KVER=\$(ls /lib/modules/ 2>/dev/null | grep lts | head -1)
        if [ -z \"\$KVER\" ]; then
            KVER=\$(ls /lib/modules/ | head -1)
        fi
        if [ -n \"\$KVER\" ]; then
            mkinitfs -c /etc/mkinitfs/mkinitfs.conf \"\$KVER\"
        fi
        rm -f /usr/bin/strings
    "

    # The persistent apk cache lives host-side in CACHE_DIR (no rootfs cleanup
    # needed; downloaded packages are intentionally kept for faster rebuilds).
}
