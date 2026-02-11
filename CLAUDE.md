# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Landscape Mini is a minimal x86 image builder for the Landscape Router. It supports both **Debian Trixie** and **Alpine Linux** as base systems, producing small, optimized disk images (as small as ~76MB compressed) with dual BIOS+UEFI boot support.

Upstream router project: https://github.com/ThisSeanZhang/landscape

## Common Commands

```bash
make deps              # Install host build dependencies (one-time)
make deps-test         # Install test dependencies (sshpass, socat, curl)
make build             # Build Debian image (requires sudo)
make build-docker      # Build Debian image with Docker (requires sudo)
make build-alpine      # Build Alpine image (requires sudo)
make build-alpine-docker # Build Alpine image with Docker (requires sudo)
make test              # Run health checks on Debian image
make test-docker       # Run health checks on Debian Docker image
make test-alpine       # Run health checks on Alpine image
make test-alpine-docker # Run health checks on Alpine Docker image
make test-e2e          # E2E network tests: DHCP, DNS, NAT (Debian)
make test-e2e-alpine   # E2E network tests: DHCP, DNS, NAT (Alpine)
make test-serial       # Boot in QEMU (interactive serial console)
make test-gui          # Boot in QEMU with VGA display
make ssh               # SSH into running QEMU instance (port 2222)
make clean             # Remove work/ directory
make distclean         # Remove work/ and output/
```

**build.sh flags:**
- `--base debian|alpine` — select base system (default: debian)
- `--with-docker` — include Docker in image (adds ~200-400MB)
- `--version VERSION` — specify Landscape release version (default: latest)
- `--skip-to PHASE` — resume build from phase 1-8 (useful during development)

**Environment overrides** (respected by both build.sh and CI):
- `APT_MIRROR` — Debian mirror URL
- `ALPINE_MIRROR` — Alpine mirror URL
- `OUTPUT_FORMAT` — `img`, `vmdk`, or `both`
- `COMPRESS_OUTPUT` — `yes` or `no`

**Default credentials:** `root` / `landscape` and `ld` / `landscape`

**QEMU port forwards:** SSH on 2222, Web UI on 9800

## Architecture

### Build Pipeline (build.sh — 8 phases)

The build uses an **orchestrator + backend** architecture:

- `build.sh` — Orchestrator: parses args, sources config and backend, runs phases
- `lib/common.sh` — Shared functions (phases 1, 2, 5, 7, 8 and helpers)
- `lib/debian.sh` — Debian backend (phases 3, 4, 6, 7 distro-specific parts)
- `lib/alpine.sh` — Alpine backend (phases 3, 4, 6, 7 distro-specific parts)

Each backend implements a unified interface:
- `backend_check_deps()` — Check host build dependencies
- `backend_bootstrap()` — Phase 3: Bootstrap base system
- `backend_configure()` — Phase 4: System configuration
- `backend_install_landscape_services()` — Phase 5: Install init services (called by common)
- `backend_install_docker()` — Phase 6: Install Docker
- `backend_cleanup()` — Phase 7: Distro-specific cleanup (called by common)

The 8 sequential phases:

1. **Download** — Fetches `landscape-webserver-x86_64` binary and `static.zip` web assets from GitHub releases. Caches to `work/downloads/`.
2. **Disk Image** — Creates a raw GPT disk image with 3 partitions: BIOS boot (1-2MiB), EFI System/FAT32 (2-202MiB), root/ext4 (202MiB+). Sets up loop device.
3. **Bootstrap** — Debian: `debootstrap --variant=minbase`. Alpine: `apk.static --initdb add alpine-base`.
4. **Configure** — Installs kernel, GRUB (both EFI and i386-pc), networking tools (iproute2, iptables, bpftool, ppp), SSH. Configures GRUB dual-boot, users, locale, timezone. Alpine adds `gcompat` for glibc binary compatibility.
5. **Install Landscape** — Copies binary/assets to `/root/`, installs init services (systemd for Debian, OpenRC for Alpine), applies sysctl tuning.
6. **Docker** (optional) — Debian: Docker CE via apt. Alpine: Docker via apk. Configures custom bridge (172.18.1.1/24).
7. **Cleanup & Shrink** — Strips binaries, removes unused kernel modules (sound, media, GPU, wireless, bluetooth), cleans caches. Resizes ext4 to minimum, truncates image.
8. **Report** — Lists output files and sizes, prints boot instructions.

### Key Files

- `build.sh` — Build orchestrator (arg parsing, sourcing backend, running phases)
- `build.env` — Build configuration (version, image size, mirrors, format, passwords)
- `lib/common.sh` — Shared build functions (download, disk image, landscape install, shrink, report)
- `lib/debian.sh` — Debian backend (debootstrap, apt, systemd, initramfs-tools)
- `lib/alpine.sh` — Alpine backend (apk, OpenRC, mkinitfs, gcompat)
- `Makefile` — Development convenience targets (build, test with QEMU, SSH, cleanup)
- `rootfs/` — Files copied into the image:
  - `rootfs/etc/systemd/system/` — systemd service files (Debian)
  - `rootfs/etc/init.d/` — OpenRC init scripts (Alpine)
  - `rootfs/etc/sysctl.d/` — sysctl tuning
  - `rootfs/usr/local/bin/expand-rootfs.sh` — Auto-expand root partition
- `configs/landscape_init.toml` — Optional router init config (WAN/LAN interfaces, DHCP, NAT rules)
- `tests/test-auto.sh` — Automated test runner (QEMU lifecycle, SSH health checks, supports both systemd and OpenRC)
- `tests/test-e2e.sh` — End-to-end network test (2-VM: Router + CirrOS client, tests DHCP/DNS/NAT)
- `.github/workflows/ci.yml` — CI pipeline: 4-variant parallel build+test (health checks + E2E)
- `.github/workflows/release.yml` — Release pipeline: build+test → compress → GitHub Release
- `.github/workflows/test.yml` — Standalone test workflow (manual trigger, downloads artifacts)

### Disk Image Layout (GPT, hybrid BIOS+UEFI)

| Partition | Range | Type | Filesystem | Purpose |
|-----------|-------|------|------------|---------|
| 1 | 1-2 MiB | EF02 | none | BIOS boot (GRUB i386-pc) |
| 2 | 2-202 MiB | EF00 | FAT32 | EFI System Partition |
| 3 | 202 MiB+ | 8300 | ext4 (no journal) | Root filesystem |

### Alpine-specific Notes

- **glibc compatibility**: `landscape-webserver` is dynamically linked against glibc. Alpine uses musl libc, so `gcompat` provides a compatibility layer.
- **Init system**: Alpine uses OpenRC instead of systemd. Service scripts are in `rootfs/etc/init.d/`.
- **Kernel**: Alpine uses `linux-lts` (6.12+ with BTF/eBPF support).
- **initramfs**: Alpine uses `mkinitfs` instead of `initramfs-tools`.

### Image Size Reduction

Both Debian and Alpine images are aggressively stripped in Phase 7 to minimize disk footprint.

**Kernel modules removed** (common to both):
- Top-level: `sound/`
- `drivers/`: media, gpu, infiniband, iio, staging, hid, input, video, bluetooth, scsi, usb, platform, misc, crypto, nvme, and ~40 more subsystems. Only `net/`, `virtio/`, `block/`, `tty/`, `pci/`, and `hv/` are kept.
- `drivers/net/`: wireless, can, wwan, arcnet, fddi, hamradio, ieee802154, wan, and others. Only virtio, phy, bonding, ppp, vxlan, wireguard, hyperv, and intel/realtek ethernet are kept.
- `net/`: bluetooth, mac80211, wireless, sunrpc, ceph, tipc, nfc, and ~20 more. Only core, ipv4, ipv6, netfilter, bridge, sched, 8021q, tls, xfrm are kept.
- `fs/`: bcachefs, btrfs, xfs, nfs, smb, ntfs3, squashfs, and ~30 more. Only ext4, jbd2, fat, nls, fuse, overlay are kept.

**Alpine-specific reductions** (`lib/alpine.sh` `backend_cleanup`):
- **bpftool dependency chain**: Alpine's bpftool pulls in perf → python3 (~31MB), binutils (~10MB). After build, perf/cpupower binaries, python3, binutils tools (ld, as, objdump, etc.), libslang are force-deleted while keeping the bpftool binary and its runtime libs.
- **Boot files**: `System.map-*`, `config-*` removed; GRUB unicode fonts (2.4MB) removed; GRUB runtime utilities (`grub-mkrescue`, `grub-fstest`, etc.) removed; `/usr/share/grub` removed.

**Debian-specific reductions** (`lib/debian.sh` `backend_cleanup`):
- Initramfs rebuilt with `MODULES=dep` (only boot-required modules).
- Locale/i18n: `libc-l10n` purged, non-English locales deleted, gconv charset converters trimmed to UTF-8/ASCII/ISO8859.
- Build-only packages purged: `grub-efi-amd64`, `grub-pc-bin`, `grub-common`, `unzip`.

**Common cleanup** (`lib/common.sh` `phase_cleanup_and_shrink`):
- All binaries and `.so` files stripped with `--strip-unneeded`.
- udev hardware database truncated.
- `/usr/share/{doc,man,info,lintian,bash-completion,common-licenses}` removed.
- GRUB locale and `/usr/lib/grub` removed.
- ext4 filesystem resized to minimum, image truncated.

### E2E Network Testing

`tests/test-e2e.sh` runs a two-VM topology to test real routing functionality:

```
Router VM (eth0=WAN/SLIRP, eth1=LAN/mcast) ←→ Client VM (CirrOS, eth0=mcast)
```

- VMs are connected via QEMU `socket:mcast` backend (same L2 segment)
- Router's DHCP server assigns 192.168.10.x to the client
- Tests: DHCP assignment (via API), gateway ping, DNS resolution, NAT (client→internet via SSH hop)
- Client interaction uses SSH ProxyCommand hop: host → router → CirrOS

### CI/CD

Each variant's build and test are merged into a single `build-and-test` job — 4 jobs run fully in parallel with no cross-waiting.

**ci.yml:**
- **Triggers:** push to main (when build files change) or manual dispatch
- **Jobs:** `build-and-test` × 4 matrix (`default`, `docker`, `alpine`, `alpine-docker`)
- **Per job:** build → upload artifact → health checks (`test-auto.sh`) → E2E network tests (`test-e2e.sh`)

**release.yml:**
- **Triggers:** version tags (`v*`)
- **Jobs:** `build-and-test` × 4 matrix → `release` (compress images, create GitHub Release)

**test.yml:**
- **Triggers:** manual dispatch (workflow_dispatch)
- **Jobs:** `test` × 4 matrix (downloads artifacts from previous build, runs health checks + E2E)
