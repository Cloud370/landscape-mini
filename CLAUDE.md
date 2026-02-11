# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Landscape Mini is a minimal x86 image builder for the Landscape Router. It uses `debootstrap` (not the Armbian build system) to produce small, optimized disk images (~150-500MB) with dual BIOS+UEFI boot support. The target is Debian Trixie (kernel 6.12+ with BTF/BPF support).

Upstream router project: https://github.com/ThisSeanZhang/landscape

## Common Commands

```bash
make deps              # Install host build dependencies (one-time)
make deps-test         # Install test dependencies (sshpass, socat, curl)
make build             # Build image (requires sudo)
make build-docker      # Build image with Docker included (requires sudo)
make test              # Run automated health checks (non-interactive)
make test-docker       # Run automated health checks on Docker image
make test-serial       # Boot in QEMU (interactive serial console)
make test-gui          # Boot in QEMU with VGA display
make ssh               # SSH into running QEMU instance (port 2222)
make clean             # Remove work/ directory
make distclean         # Remove work/ and output/
```

**build.sh flags:**
- `--with-docker` — include Docker in image (adds ~200-400MB)
- `--version VERSION` — specify Landscape release version (default: latest)
- `--skip-to PHASE` — resume build from phase 1-8 (useful during development)

**Environment overrides** (respected by both build.sh and CI):
- `APT_MIRROR` — Debian mirror URL
- `OUTPUT_FORMAT` — `img`, `vmdk`, or `both`
- `COMPRESS_OUTPUT` — `yes` or `no`

**Default credentials:** `root` / `landscape` and `ld` / `landscape`

**QEMU port forwards:** SSH on 2222, Web UI on 9800

## Architecture

### Build Pipeline (build.sh — 8 phases)

The entire build is orchestrated by `build.sh`, a single bash script requiring root. It runs 8 sequential phases:

1. **Download** — Fetches `landscape-webserver-x86_64` binary and `static.zip` web assets from GitHub releases. Caches to `work/downloads/`.
2. **Disk Image** — Creates a raw GPT disk image with 3 partitions: BIOS boot (1-2MiB), EFI System/FAT32 (2-66MiB), root/ext4 (66MiB+). Sets up loop device.
3. **Bootstrap** — Runs `debootstrap --variant=minbase` for Debian Trixie into the root partition.
4. **Configure** — Installs kernel, GRUB (both EFI and i386-pc), networking tools (iproute2, iptables, bpftool, ppp), SSH. Configures GRUB dual-boot, users, locale, timezone.
5. **Install Landscape** — Copies binary/assets to `/root/`, creates systemd service, applies sysctl tuning from `rootfs/`.
6. **Docker** (optional) — Installs Docker CE with compose plugin, configures custom bridge (172.18.1.1/24). Auto-increases image to 2048MB.
7. **Cleanup & Shrink** — Aggressively strips ~50MB+ of unused kernel modules (sound, media, GPU, wireless, bluetooth), removes locale data, docs, man pages. Resizes ext4 to minimum, truncates image.
8. **Report** — Lists output files and sizes, prints boot instructions.

### Key Files

- `build.sh` — Main build orchestrator (all 8 phases)
- `build.env` — Build configuration (version, image size, mirror, format, passwords)
- `Makefile` — Development convenience targets (build, test with QEMU, SSH, cleanup)
- `rootfs/` — Files copied into the image (sysctl tuning, systemd service, network interfaces)
- `configs/landscape_init.toml` — Optional router init config (WAN/LAN interfaces, DHCP, NAT rules)
- `tests/test-auto.sh` — Automated test runner (QEMU lifecycle, SSH health checks)
- `.github/workflows/build.yml` — CI pipeline: parallel matrix build (default + docker variants), release with checksums on version tags

### Disk Image Layout (GPT, hybrid BIOS+UEFI)

| Partition | Range | Type | Filesystem | Purpose |
|-----------|-------|------|------------|---------|
| 1 | 1-2 MiB | EF02 | none | BIOS boot (GRUB i386-pc) |
| 2 | 2-66 MiB | EF00 | FAT32 | EFI System Partition |
| 3 | 66 MiB+ | 8300 | ext4 (no journal) | Root filesystem |

### CI/CD

- **Triggers:** push to main (when build files change) or manual dispatch
- **Matrix:** builds `default` and `docker` variants in parallel on ubuntu-24.04
- **Release:** version tags (`v*`) trigger compression, SHA256/MD5 checksums, and GitHub Release creation
