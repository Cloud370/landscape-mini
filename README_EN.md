# Landscape Mini

[![Latest Release](https://img.shields.io/github/v/release/Cloud370/landscape-mini)](https://github.com/Cloud370/landscape-mini/releases/latest)

[中文](README.md) | English | [**Download Latest**](https://github.com/Cloud370/landscape-mini/releases/latest)

Minimal x86 image builder for Landscape Router. Supports both **Debian Trixie** and **Alpine Linux** as base systems, producing small, optimized disk images (~150–500MB) with dual BIOS+UEFI boot. Alpine images are ~50% smaller than Debian.

Upstream: [Landscape Router](https://github.com/ThisSeanZhang/landscape)

## Features

- Dual base systems: Debian Trixie / Alpine Linux (kernel 6.12+ with native BTF/BPF)
- GPT partitioned, dual BIOS+UEFI boot (Proxmox/SeaBIOS compatible)
- Aggressive trimming: removes unused kernel modules, docs, locales
- Optional Docker CE (with compose plugin)
- CI/CD: GitHub Actions with 4-variant parallel build+test + Release
- Automated testing: headless QEMU health checks + E2E network tests (DHCP/DNS/NAT)

## Quick Start

### Build

```bash
# Install build dependencies (once)
make deps

# Build Debian image
make build

# Build Alpine image (smaller)
make build-alpine

# Build with Docker included
make build-docker
make build-alpine-docker
```

### Test

```bash
# Automated health checks (non-interactive)
make deps-test          # Install test dependencies (once)
make test               # Debian health checks
make test-alpine        # Alpine health checks

# E2E network tests (dual VM: router + client)
make test-e2e           # Debian E2E
make test-e2e-alpine    # Alpine E2E

# Interactive boot (serial console)
make test-serial
```

### Deploy

#### Physical Disk / USB

```bash
dd if=output/landscape-mini-x86.img of=/dev/sdX bs=4M status=progress
```

#### Proxmox VE (PVE)

1. Upload image to PVE server
2. Create a VM (without adding a disk)
3. Import disk: `qm importdisk <vmid> landscape-mini-x86.img local-lvm`
4. Attach the imported disk in VM hardware settings
5. Set boot order and start the VM

#### Cloud Server (dd script)

Use the [reinstall](https://github.com/bin456789/reinstall) script to write custom images to cloud servers:

```bash
bash <(curl -sL https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh) \
    dd --img='https://github.com/Cloud370/landscape-mini/releases/latest/download/landscape-mini-x86.img.gz'
```

> The root partition automatically expands to fill the entire disk on first boot — no manual action needed.

## Default Credentials

| User | Password |
|------|----------|
| `root` | `landscape` |
| `ld` | `landscape` |

## Build Configuration

Edit `build.env` or override via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `APT_MIRROR` | Tsinghua mirror | Debian mirror URL |
| `LANDSCAPE_VERSION` | `latest` | Landscape release version |
| `OUTPUT_FORMAT` | `img` | Output format: `img`, `vmdk`, `both` |
| `COMPRESS_OUTPUT` | `yes` | Compress output image |
| `IMAGE_SIZE_MB` | `1024` | Initial image size (auto-shrunk) |
| `ROOT_PASSWORD` | `landscape` | Root password |
| `TIMEZONE` | `Asia/Shanghai` | System timezone |

### build.sh Flags

```bash
sudo ./build.sh                          # Default build (Debian)
sudo ./build.sh --base alpine            # Build Alpine image
sudo ./build.sh --with-docker            # Include Docker
sudo ./build.sh --version v0.12.4        # Specific version
sudo ./build.sh --skip-to 5              # Resume from phase 5
```

## Build Pipeline (8 Phases)

`build.sh` uses an **orchestrator + backend** architecture:

- `build.sh` — Orchestrator: parses args, sources config and backend, runs phases
- `lib/common.sh` — Shared functions (phases 1, 2, 5, 7, 8 and helpers)
- `lib/debian.sh` — Debian backend (debootstrap, apt, systemd)
- `lib/alpine.sh` — Alpine backend (apk, OpenRC, mkinitfs, gcompat)

```
1. Download     Fetch Landscape binary and web assets from GitHub
2. Disk Image   Create GPT image (BIOS boot + EFI + root partitions)
3. Bootstrap    Debian: debootstrap / Alpine: apk.static
4. Configure    Install kernel, dual GRUB, networking tools, SSH
5. Landscape    Install binary, create init services (systemd/OpenRC), apply sysctl
6. Docker       (optional) Install Docker CE / apk docker
7. Cleanup      Strip kernel modules, caches, docs; shrink image
8. Report       List outputs and sizes
```

## Disk Partition Layout

```
┌──────────────┬────────────┬────────────┬──────────────────────────┐
│ BIOS boot    │ EFI System │ Root (/)   │                          │
│ 1 MiB        │ 200 MiB    │ Remaining  │  ← Auto-shrunk after    │
│ (no fs)      │ FAT32      │ ext4       │    build                 │
├──────────────┼────────────┼────────────┤                          │
│ GPT: EF02    │ GPT: EF00  │ GPT: 8300  │                          │
└──────────────┴────────────┴────────────┴──────────────────────────┘
```

## Automated Testing

### Health Checks

`make test` / `make test-alpine` runs a fully unattended test cycle:

1. Copy image to temp file (protect build artifacts)
2. Start QEMU daemonized (auto-detects KVM)
3. Wait for SSH (120s timeout)
4. Run health checks via SSH (kernel, services, networking, Web UI, etc.)
5. Report results and clean up

Auto-detects systemd (Debian) and OpenRC (Alpine) init systems.

### E2E Network Tests

`make test-e2e` / `make test-e2e-alpine` runs a two-VM topology to test real routing:

```
Router VM (eth0=WAN/SLIRP, eth1=LAN/mcast) ←→ Client VM (CirrOS, eth0=mcast)
```

Tests: DHCP assignment, gateway connectivity, DNS resolution, NAT (client→internet via router).

Logs saved to `output/test-logs/`.

## QEMU Test Ports

| Service | Host Port | Access |
|---------|-----------|--------|
| SSH | 2222 | `ssh -p 2222 root@localhost` |
| Web UI | 9800 | `http://localhost:9800` |

## Project Structure

```
├── build.sh              # Build orchestrator (arg parsing, backend loading, phases)
├── build.env             # Build configuration
├── Makefile              # Dev convenience targets
├── lib/
│   ├── common.sh         # Shared build functions (download, disk, install, shrink)
│   ├── debian.sh         # Debian backend (debootstrap, apt, systemd)
│   └── alpine.sh         # Alpine backend (apk, OpenRC, mkinitfs)
├── configs/
│   └── landscape_init.toml  # Router init config (WAN/LAN/DHCP/NAT)
├── rootfs/               # Files copied into image
│   └── etc/
│       ├── network/interfaces
│       ├── sysctl.d/99-landscape.conf
│       ├── systemd/system/          # systemd services (Debian)
│       │   ├── landscape-router.service
│       │   └── expand-rootfs.service
│       └── init.d/                  # OpenRC scripts (Alpine)
│           ├── landscape-router
│           └── expand-rootfs
├── tests/
│   ├── test-auto.sh      # Health check tests (supports systemd/OpenRC)
│   └── test-e2e.sh       # E2E network tests (dual VM: DHCP/DNS/NAT)
└── .github/workflows/
    ├── ci.yml            # CI: 4-variant parallel build+test
    ├── release.yml       # Release: build+test+publish
    └── test.yml          # Standalone test (manual trigger)
```

## CI/CD

- **Triggers**: push to main (build files changed) or manual dispatch
- **Matrix**: 4 variants fully parallel (`default`, `docker`, `alpine`, `alpine-docker`)
- **Per variant**: build → health checks → E2E network tests (merged into single job, no cross-waiting)
- **Release**: `v*` tags trigger compression and GitHub Release creation

## License

This project is a community image builder for [Landscape Router](https://github.com/ThisSeanZhang/landscape).
