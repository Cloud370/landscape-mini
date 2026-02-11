# Landscape Mini

[中文](README.md) | English

Minimal x86 image builder for Landscape Router. Produces small, optimized Debian Trixie disk images (~150–500MB) with dual BIOS+UEFI boot using `debootstrap`.

Upstream: [Landscape Router](https://github.com/ThisSeanZhang/landscape)

## Features

- Debian Trixie base (kernel 6.12+ with native BTF/BPF)
- GPT partitioned, dual BIOS+UEFI boot (Proxmox/SeaBIOS compatible)
- Aggressive trimming: removes unused kernel modules, docs, locales
- Optional Docker CE (with compose plugin)
- CI/CD: GitHub Actions auto-build + Release
- Automated testing: headless QEMU boot + 14 health checks

## Quick Start

### Build

```bash
# Install build dependencies (once)
make deps

# Build standard image
make build

# Build with Docker included
make build-docker
```

### Test

```bash
# Automated health checks (non-interactive)
make deps-test      # Install test dependencies (once)
make test

# Interactive boot (serial console)
make test-serial
```

### Deploy

Write `output/landscape-mini-x86.img` to disk or import into a virtualization platform:

```bash
# Write to physical disk
dd if=output/landscape-mini-x86.img of=/dev/sdX bs=4M status=progress

# Convert to VMDK (VMware/Proxmox)
qemu-img convert -f raw -O vmdk output/landscape-mini-x86.img landscape-mini.vmdk
```

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
sudo ./build.sh                          # Default build
sudo ./build.sh --with-docker            # Include Docker
sudo ./build.sh --version v0.12.4        # Specific version
sudo ./build.sh --skip-to 5              # Resume from phase 5
```

## Build Pipeline (8 Phases)

```
1. Download     Fetch Landscape binary and web assets from GitHub
2. Disk Image   Create GPT image (BIOS boot + EFI + root partitions)
3. Bootstrap    debootstrap --variant=minbase for Debian Trixie
4. Configure    Install kernel, dual GRUB, networking tools, SSH
5. Landscape    Install binary, create systemd service, apply sysctl
6. Docker       (optional) Install Docker CE + compose
7. Cleanup      Strip kernel modules, caches, docs; shrink image
8. Report       List outputs and sizes
```

## Disk Partition Layout

```
┌──────────────┬────────────┬────────────┬──────────────────────────┐
│ BIOS boot    │ EFI System │ Root (/)   │                          │
│ 1 MiB        │ 64 MiB     │ Remaining  │  ← Auto-shrunk after    │
│ (no fs)      │ FAT32      │ ext4       │    build                 │
├──────────────┼────────────┼────────────┤                          │
│ GPT: EF02    │ GPT: EF00  │ GPT: 8300  │                          │
└──────────────┴────────────┴────────────┴──────────────────────────┘
```

## Automated Testing

`make test` runs a fully unattended test cycle:

1. Copy image to temp file (protect build artifacts)
2. Start QEMU daemonized (auto-detects KVM)
3. Wait for SSH (120s timeout)
4. Run 14 health checks via SSH
5. Report results and clean up

Checks: kernel version, hostname, disk layout, users, Landscape service, Web UI, IP forwarding, sshd, systemd status, bpftool, Docker (auto-detected).

Logs saved to `output/test-logs/`.

## QEMU Test Ports

| Service | Host Port | Access |
|---------|-----------|--------|
| SSH | 2222 | `ssh -p 2222 root@localhost` |
| Web UI | 9800 | `http://localhost:9800` |

## Project Structure

```
├── build.sh              # Main build script (8 phases)
├── build.env             # Build configuration
├── Makefile              # Dev convenience targets
├── configs/
│   └── landscape_init.toml  # Router init config (WAN/LAN/DHCP/NAT)
├── rootfs/               # Files copied into image
│   └── etc/
│       ├── network/interfaces
│       ├── sysctl.d/99-landscape.conf
│       └── systemd/system/landscape-router.service
├── tests/
│   └── test-auto.sh      # Automated test runner
└── .github/workflows/
    └── build.yml         # CI/CD pipeline
```

## CI/CD

- **Triggers**: push to main (build files changed) or manual dispatch
- **Matrix**: parallel build of `default` and `docker` variants
- **Release**: `v*` tags trigger compression, checksums, and GitHub Release

## License

This project is a community image builder for [Landscape Router](https://github.com/ThisSeanZhang/landscape).
