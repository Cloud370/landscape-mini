#!/bin/bash
# =============================================================================
# Landscape Mini - Debian Backend
# =============================================================================
# Provides Debian-specific implementations of the backend_* interface.
# Sourced by build.sh when BASE_SYSTEM=debian.
# =============================================================================

CHROOT_SHELL="/bin/bash"

# ---------------------------------------------------------------------------
# Check host dependencies for Debian builds
# ---------------------------------------------------------------------------
backend_check_deps() {
    for cmd in debootstrap parted losetup mkfs.vfat mkfs.ext4 blkid e2fsck resize2fs curl unzip xz sgdisk; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo "ERROR: Required command '${cmd}' not found. Please install it first."
            exit 1
        fi
    done
}

# =============================================================================
# Phase 3: Bootstrap Debian
# =============================================================================
backend_bootstrap() {
    echo ""
    echo "==== Phase 3: Bootstrapping Debian (${DEBIAN_RELEASE}) ===="

    echo "  Running debootstrap --variant=minbase ..."
    retry_command 3 5 \
        debootstrap \
        --variant=minbase \
        --include=systemd,systemd-sysv,dbus \
        "${DEBIAN_RELEASE}" \
        "${ROOTFS_DIR}" \
        "${MIRROR}"

    echo "  Phase 3 complete."
}

# ---------------------------------------------------------------------------
# Persistent apt archive cache (host-side, survives `make clean`)
# ---------------------------------------------------------------------------
setup_apt_cache_mount() {
    mkdir -p "${CACHE_DIR}/apt/partial" "${ROOTFS_DIR}/var/cache/apt/archives"
    mount --bind "${CACHE_DIR}/apt" "${ROOTFS_DIR}/var/cache/apt/archives"
    echo "  Apt archive cache mounted: ${CACHE_DIR}/apt"
}

umount_apt_cache() {
    umount "${ROOTFS_DIR}/var/cache/apt/archives" 2>/dev/null || true
}

# =============================================================================
# Phase 4: Configure System (Debian)
# =============================================================================
backend_configure() {
    echo ""
    echo "==== Phase 4: Configuring System (Debian) ===="

    # Mount bind filesystems for chroot
    mount_chroot_fs

    # Persistent package cache for faster rebuilds
    setup_apt_cache_mount

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
# VMware / ESXi storage drivers
vmw_pvscsi
mptspi
mpt3sas
# NVMe storage
nvme
# Hyper-V (Azure)
hv_vmbus
hv_storvsc
# Xen (AWS, Oracle Cloud)
xen_blkfront
EOF

    # ---- Install packages ----
    echo "  Installing packages (this may take a while) ..."
    run_in_chroot_retry 3 5 "
        export DEBIAN_FRONTEND=noninteractive
        apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=60 \
            -o Acquire::https::Timeout=60 \
            update -y
        apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=60 \
            -o Acquire::https::Timeout=60 \
            install -y --no-install-recommends \
            linux-image-amd64 \
            firmware-linux-free \
            firmware-intel-misc \
            firmware-realtek \
            firmware-bnx2 \
            firmware-bnx2x \
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
            ethtool \
            pciutils \
            curl \
            ca-certificates \
            unzip \
            sudo \
            openssh-server \
            gdisk \
            cloud-guest-utils \
            iputils-ping \
            traceroute \
            dnsutils \
            mtr-tiny \
            nano \
            vim-tiny \
            wget \
            iperf3
    "

    # ---- GRUB configuration ----
    echo "  Configuring GRUB ..."
    cat > "${ROOTFS_DIR}/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Landscape"
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8"
GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 nomodeset"
GRUB_TERMINAL_INPUT="console serial"
GRUB_TERMINAL_OUTPUT="serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
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

    # ---- Locale ----
    echo "  Configuring locale (${LOCALE}) ..."
    if [[ "${LOCALE}" != "C.UTF-8" && "${LOCALE}" != *.UTF-8 ]]; then
        echo "ERROR: Debian backend supports only C.UTF-8 or *.UTF-8 as LOCALE; got '${LOCALE}'." >&2
        exit 1
    fi

    local locale_gen_entries=""
    local locale_value
    local extra_locale
    local needs_locales_package=false

    if [[ "${LOCALE}" != "C.UTF-8" ]]; then
        locale_gen_entries+="${LOCALE} UTF-8\n"
        needs_locales_package=true
    fi

    for extra_locale in ${EXTRA_LOCALES}; do
        [[ -n "${extra_locale}" ]] || continue
        if [[ "${extra_locale}" != *.UTF-8 ]]; then
            echo "ERROR: Debian backend supports only *.UTF-8 in EXTRA_LOCALES; got '${extra_locale}'." >&2
            exit 1
        fi
        if [[ "${extra_locale}" == "${LOCALE}" ]]; then
            continue
        fi
        locale_gen_entries+="${extra_locale} UTF-8\n"
        needs_locales_package=true
    done

    if [[ "${needs_locales_package}" == "true" ]]; then
        echo "  Installing locale support ..."
        run_in_chroot_retry 3 5 "
            export DEBIAN_FRONTEND=noninteractive
            apt-get \
                -o Acquire::Retries=3 \
                -o Acquire::http::Timeout=60 \
                -o Acquire::https::Timeout=60 \
                install -y --no-install-recommends locales
        "
        printf '%b' "${locale_gen_entries}" > "${ROOTFS_DIR}/etc/locale.gen"
        run_in_chroot "locale-gen"
    fi

    cat > "${ROOTFS_DIR}/etc/default/locale" <<EOF
LANG=${LOCALE}
LC_ALL=${LOCALE}
EOF

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

    # ---- Clear default login banners ----
    echo "  Clearing default login banners ..."
    : > "${ROOTFS_DIR}/etc/motd"
    : > "${ROOTFS_DIR}/etc/issue"
    : > "${ROOTFS_DIR}/etc/issue.net"

    # ---- Configure SSH login output ----
    echo "  Configuring SSH login output ..."
    mkdir -p "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
    cat > "${ROOTFS_DIR}/etc/ssh/sshd_config.d/root-login.conf" <<EOF
PermitRootLogin yes
PrintMotd no
PrintLastLog no
AcceptEnv LANG
SetEnv LANG=${LOCALE} LC_ALL=${LOCALE}
EOF

    echo "  Disabling PAM MOTD banner for SSH and console logins ..."
    if [[ -f "${ROOTFS_DIR}/etc/pam.d/sshd" ]]; then
        sed -i '/pam_motd\.so/s/^/# /' "${ROOTFS_DIR}/etc/pam.d/sshd"
    fi
    if [[ -f "${ROOTFS_DIR}/etc/pam.d/login" ]]; then
        sed -i '/pam_motd\.so/s/^/# /' "${ROOTFS_DIR}/etc/pam.d/login"
    fi

    if [[ -f "${ROOTFS_DIR}/etc/pam.d/login" ]]; then
        sed -i '/pam_lastlog\.so/s/^/# /' "${ROOTFS_DIR}/etc/pam.d/login"
    fi

    if [[ -f "${ROOTFS_DIR}/etc/pam.d/sshd" ]]; then
        sed -i '/pam_lastlog\.so/s/^/# /' "${ROOTFS_DIR}/etc/pam.d/sshd"
    fi

    if [[ -f "${ROOTFS_DIR}/etc/login.defs" ]]; then
        sed -i 's/^MOTD_FILE.*/MOTD_FILE	/' "${ROOTFS_DIR}/etc/login.defs"
    fi

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

    # ---- Build-time DNS resolver ----
    configure_build_resolver

    # ---- Image default DNS resolver ----
    configure_image_resolver

    echo "  Phase 4 complete."
}

# ---------------------------------------------------------------------------
# Phase 5 backend: install systemd service files
# ---------------------------------------------------------------------------
backend_install_landscape_services() {
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

    # Copy expand-rootfs systemd service
    cp "${SCRIPT_DIR}/rootfs/etc/systemd/system/expand-rootfs.service" \
        "${ROOTFS_DIR}/etc/systemd/system/expand-rootfs.service"

    # Enable services
    echo "  Enabling landscape-router.service ..."
    run_in_chroot "systemctl enable landscape-router.service"
    echo "  Enabling expand-rootfs.service ..."
    run_in_chroot "systemctl enable expand-rootfs.service"
}

# =============================================================================
# Phase 6: Optional Docker Installation (Debian)
# =============================================================================
backend_install_docker() {
    if [[ "${INCLUDE_DOCKER}" != "true" ]]; then
        echo ""
        echo "==== Phase 6: Docker Installation (skipped) ===="
        return 0
    fi

    echo ""
    echo "==== Phase 6: Installing Docker (Debian) ===="

    # ---- Build-time DNS resolver ----
    configure_build_resolver

    # Install prerequisites
    run_in_chroot_retry 3 5 "
        export DEBIAN_FRONTEND=noninteractive
        apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=60 \
            -o Acquire::https::Timeout=60 \
            install -y --no-install-recommends ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
    "

    # Add Docker GPG key
    echo "  Adding Docker GPG key from ${RESOLVED_DOCKER_APT_GPG_URL} ..."
    run_in_chroot_retry 3 5 "
        curl -fsSL --retry 3 --retry-delay 2 '${RESOLVED_DOCKER_APT_GPG_URL}' -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    "

    # Add Docker repository
    echo "  Adding Docker repository ${RESOLVED_DOCKER_APT_MIRROR} ..."
    local ARCH
    ARCH=$(run_in_chroot "dpkg --print-architecture")
    run_in_chroot_retry 3 5 "
        echo 'deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] ${RESOLVED_DOCKER_APT_MIRROR} ${DEBIAN_RELEASE} stable' \
            > /etc/apt/sources.list.d/docker.list
        apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=60 \
            -o Acquire::https::Timeout=60 \
            update -y
    "

    # Install Docker packages
    echo "  Installing Docker packages ..."
    run_in_chroot_retry 3 5 "
        export DEBIAN_FRONTEND=noninteractive
        apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::Timeout=60 \
            -o Acquire::https::Timeout=60 \
            install -y --no-install-recommends \
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

    # ---- Image default DNS resolver ----
    configure_image_resolver

    echo "  Phase 6 complete."
}

# ---------------------------------------------------------------------------
# Phase 7 backend: Debian-specific cleanup
# ---------------------------------------------------------------------------
backend_cleanup() {
    # Detach the persistent apt cache before cleaning, so `apt-get clean`
    # cannot wipe the host-side cache used by later rebuilds.
    umount_apt_cache

    # ---- Rebuild initramfs with fewer modules ----
    echo "  Rebuilding smaller initramfs ..."
    run_in_chroot "
        KVER=\$(ls /usr/lib/modules/ | head -1)
        update-initramfs -u -k \"\$KVER\" 2>/dev/null || true
    "

    # ---- Aggressive locale/i18n cleanup ----
    echo "  Cleaning locale and i18n data ..."
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        if [ \"${LOCALE}\" = \"C.UTF-8\" ] && [ -z \"${EXTRA_LOCALES}\" ]; then
            # Remove locale generation packages when the image stays on glibc's built-in C.UTF-8 only
            apt-get purge -y --auto-remove libc-l10n locales 2>/dev/null || true
        fi

        # Remove translated message catalogs except English
        find /usr/share/locale -mindepth 1 -maxdepth 1 \
            ! -name 'en_US' ! -name 'en' ! -name 'locale-archive' \
            -exec rm -rf {} + 2>/dev/null || true

        # Keep only UTF-8 charmap, remove others (save ~3M)
        find /usr/share/i18n/charmaps -type f ! -name 'UTF-8.gz' -delete 2>/dev/null || true

        # Trim locale source definitions after generation
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


    # ---- Purge build-only packages ----
    # Note: do NOT purge initramfs-tools — it breaks linux-image dependency
    # chain and makes apt unusable on the running system.
    echo "  Purging build-only packages ..."
    run_in_chroot "
        export DEBIAN_FRONTEND=noninteractive
        dpkg --purge --force-depends \
            grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-unsigned \
            grub-pc-bin grub-common grub2-common \
            unzip 2>/dev/null || true
        apt-get -y --purge autoremove 2>/dev/null || true
    "

    # ---- General apt cleanup ----
    echo "  Cleaning apt caches ..."
    run_in_chroot "
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        # Keep Dpkg/ and Debconf/ modules (~500KB) so apt/dpkg-reconfigure still work
        find /usr/share/perl5 -mindepth 1 -maxdepth 1 \
            ! -name 'Dpkg' ! -name 'Dpkg.pm' ! -name 'Debconf' \
            -exec rm -rf {} + 2>/dev/null || true
    "
}
