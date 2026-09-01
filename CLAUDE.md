# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

Landscape Mini builds minimal x86 images for Landscape Router.

- Base systems: Debian Trixie / Alpine Linux
- Boot: BIOS + UEFI
- Build identity model: `base_system + include_docker + output_formats`
- Upstream project: https://github.com/ThisSeanZhang/landscape

## Start here

Choose the path that matches the user’s goal:

1. **Just wants to use the project**
   - Chinese entry: `README.md`
   - English entry: `docs/en/README.md`
   - Custom Build guide: `docs/zh/custom-build.md`, `docs/en/custom-build.md`

2. **Wants to modify the build system or tests**
   - Main files: `build.sh`, `lib/`, `rootfs/`, `tests/`, `.github/workflows/`

3. **Wants release / CI behavior**
   - Read `.github/workflows/ci.yml`
   - Read `.github/workflows/_build-and-validate.yml`
   - Read `.github/workflows/test.yml`
   - Read `.github/workflows/release.yml`

## Common Commands

```bash
make deps
make deps-test
make build              # rootless by default; works as root too
make build BASE_SYSTEM=alpine
make build INCLUDE_DOCKER=true OUTPUT_FORMATS=img,ova
make test
make test-dataplane
make test-serial
make ssh
```

## Rootless build model

- The build never uses loop devices, partition mounts, or persistent chroot
  mounts: the rootfs lives in `work/rootfs` and is packed into the image
  offline (`mke2fs -d` + mtools + `sgdisk` on image files).
- Chroot steps go through a chroot engine, auto-detected at start:
  root → `chroot`; rootless → `unshare --map-root-user --map-auto` when subid
  delegation is available (`uidmap` + `/etc/subuid` + `/etc/subgid`, the
  Debian/Ubuntu default for human users), which maps every guest id below
  65536 so dpkg's group ownerships (shadow, crontab, ...) land natively at
  full chroot speed; otherwise `proot` (fakes the chowns, slower package
  phases). `mkfs` (`run_uid_mapped`) uses the same mapping so image gids
  match what dpkg set in the tree. Override with
  `BUILD_CHROOT_ENGINE=chroot|unshare|proot`.
- GRUB is installed host-side: EFI via `grub-mkstandalone` (the `linux`
  loader is embedded in the standalone binary — the image ships no GRUB
  module directory), BIOS by embedding boot.img/core.img directly into the
  image (bootloader packages are not installed into the image).
- Filesystem UUIDs are generated in phase 2 and persisted in
  `work/image-layout.env` (used by fstab, initramfs, grub.cfg). The ESP
  serial must appear in fstab as uppercase `XXXX-XXXX` — blkid matches vfat
  UUIDs case-sensitively.
- The `ld` user is pinned to uid 1000; rootless images fix `/home/ld`
  ownership and restore gid-based setgid binaries (unix_chkpwd → shadow) on
  first boot via the expand-rootfs hook.
- Alpine installs packages host-side via `apk.static --root`; Debian runs
  `debootstrap --foreign` + second stage through the engine. Package caches
  live under `CACHE_DIR` (apk directly, apt via rsync sync).
- `--skip-to` resumes operate on the `work/rootfs` tree, not the image.

## Defaults and important inputs

- Default upstream version comes from `build.env` (`LANDSCAPE_VERSION`, currently `v0.24.2`)
- `configs/landscape_init.toml` is version-coupled to `LANDSCAPE_VERSION`: upstream (>= v0.19)
  enforces an exact `version` field and the static NAT table layout changed in v0.24.
  `build.sh` pins the `version` field automatically from the resolved landscape version
  (`latest` is resolved to a concrete tag first). Pinning a pre-v0.24 version fails the
  build if the config still uses `static_nat_mappings_v4/v6` (silently dropped by old
  binaries) and warns otherwise — downgrade the config to the old `[[static_nat_mappings]]`
  format by hand.
- Default Linux login:
  - `root` / `landscape`
  - `ld` / `landscape`
- Default Web UI login:
  - `root` / `root`
- Common build env overrides:
  - `BASE_SYSTEM`
  - `INCLUDE_DOCKER`
  - `OUTPUT_FORMATS`
  - `ROOT_PASSWORD`
  - `LANDSCAPE_ADMIN_USER`
  - `LANDSCAPE_ADMIN_PASS`
  - `EFFECTIVE_CONFIG_PATH`
  - `APT_MIRROR`
  - `ALPINE_MIRROR`
  - `COMPRESS_OUTPUT`
  - `CACHE_DIR` (persistent build cache, default `.cache/`, survives `make clean`)

## Build and test contract

- CI and Custom Build both use `.github/workflows/_build-and-validate.yml`
- Each image artifact must include:
  - raw `.img`
  - `build-metadata.txt`
  - `effective-landscape_init.toml`
- Tests should use effective topology config and build metadata
- Dataplane scheduling rule:
  - `include_docker=false` → run dataplane
  - `include_docker=true` → readiness only

## CI/CD summary

### CI

`ci.yml` now validates only 1 automatic tuple:

- `debian + false`

Automatic CI requests only `img` output and runs `readiness,dataplane`.

### Custom Build

`custom-build.yml` is the fork-friendly manual entry point.

Supports:

- `base_system`
- `include_docker`
- `output_formats`
- `landscape_version`
- LAN / DHCP inputs
- Linux password
- Web admin username / password

Credential precedence:

- `direct inputs > secrets > defaults`

Secrets names:

- `CUSTOM_ROOT_PASSWORD`
- `CUSTOM_API_USERNAME`
- `CUSTOM_API_PASSWORD`

### Retest

`test.yml` retests existing CI artifacts by `run_id` or `artifact_id`.

### Release

`release.yml` rebuilds Debian release artifacts on tag pushes instead of promoting CI artifacts.
It rebuilds both Debian tuples (`include_docker=true/false`) with `img,ova`, validates metadata/config, then publishes `.img.gz` + `.ova`.

## Key files

- `build.sh` — main build orchestrator
- `build.env` — default build values
- `lib/common.sh` / `lib/debian.sh` / `lib/alpine.sh` — build implementation
- `configs/landscape_init.toml` — default topology config
- `.github/scripts/render-effective-topology.sh` — renders effective topology config
- `tests/test-readiness.sh` — shared readiness contract
- `tests/test-dataplane.sh` — dataplane test
- `README.md` — Chinese primary entry
- `docs/en/README.md` — English primary entry
- `CONTRIBUTING.md` — branch / PR / release process

## Contribution expectations

- Prefer branch + PR over direct push to `main`
- If the change is user-visible, update `CHANGELOG.md` `Unreleased`
- For CI / workflow / release changes, prefer PR flow
