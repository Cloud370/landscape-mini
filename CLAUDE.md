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
make test              # Run readiness checks on Debian image
make test-docker       # Run readiness checks on Debian Docker image
make test-alpine       # Run readiness checks on Alpine image
make test-alpine-docker # Run readiness checks on Alpine Docker image
make test-dataplane    # Dataplane tests: DHCP + LAN connectivity (Debian)
make test-dataplane-alpine # Dataplane tests: DHCP + LAN connectivity (Alpine)
make test-serial       # Boot in QEMU (interactive serial console)
make test-gui          # Boot in QEMU with VGA display
make ssh               # SSH into running QEMU instance (port 2222)
make clean             # Remove work/ directory
make distclean         # Remove work/ and output/
make status            # Show disk usage of work/ and output/
```

**build.sh flags:**
- `--base debian|alpine` — select base system (default: debian)
- `--with-docker` — include Docker in image (adds ~200-400MB)
- `--version VERSION` — specify Landscape release version (default: value from `build.env`, currently `v0.13.0`)
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

- `build.env` — Build configuration (version, image size, mirrors, format, passwords)
- `rootfs/` — Files copied into the image (systemd units, OpenRC scripts, sysctl tuning, `expand-rootfs.sh`, `setup-mirror.sh`)
- `configs/landscape_init.toml` — Optional router init config (WAN/LAN interfaces, DHCP, NAT rules)
- `tests/test-readiness.sh` — Router readiness test runner (shared boot/SSH/API contract, supports systemd and OpenRC)
- `tests/test-dataplane.sh` — Dataplane test: two-VM topology (Router + CirrOS client), validates DHCP + LAN connectivity after readiness
- `CHANGELOG.md` — Bilingual (EN/CN) changelog following Keep a Changelog format

### Image Size Reduction

Phase 7 aggressively strips the image: removes unused kernel modules (keeps only net/virtio/block/pci/tty/hv essentials), strips binaries, cleans caches, resizes ext4 to minimum. Details in cleanup functions of `lib/common.sh`, `lib/debian.sh`, `lib/alpine.sh`.

### CI/CD

All workflows run 4 variants in parallel: `default`, `docker`, `alpine`, `alpine-docker`.

| Workflow | Trigger | Jobs |
|----------|---------|------|
| `ci.yml` | push to main (build files) / manual | build → health checks → E2E per variant |
| `release.yml` | version tags (`v*`) | build+test → compress → GitHub Release |
| `test.yml` | manual dispatch | download artifacts → health checks + E2E |
