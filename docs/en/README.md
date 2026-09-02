# Landscape Mini

[![Latest Release](https://img.shields.io/github/v/release/Cloud370/landscape-mini)](https://github.com/Cloud370/landscape-mini/releases/latest)

English | [中文](../zh/README.md) | [Contributing](../../CONTRIBUTING.md) | [Download Latest Image](https://github.com/Cloud370/landscape-mini/releases/latest)

Landscape Mini is a minimal x86 image builder for Landscape Router. It supports **Debian Trixie** and **Alpine Linux**, can produce `img` / `vmdk` / `ova`, and supports both BIOS and UEFI boot.

Upstream project: [Landscape Router](https://github.com/ThisSeanZhang/landscape)

## Read by Goal

| Your goal | Go to |
|---|---|
| Download a ready-made image | [Release page](https://github.com/Cloud370/landscape-mini/releases/latest) |
| Customize network / passwords / version / output formats | [Custom Build Guide](./custom-build.md) |
| Import / install on PVE | [PVE Installation Guide](./pve-install.md) |
| Build / test / debug locally | Continue reading this page |
| 中文文档 | [docs/zh/README.md](../zh/README.md) |

## Recommended Paths

- Just want to get it running: Release → [PVE Installation Guide](./pve-install.md)
- Need to change network, passwords, or version: [Custom Build Guide](./custom-build.md) → [PVE Installation Guide](./pve-install.md)
- Want to modify this repository: continue with "Local Development" below, then read [CONTRIBUTING.md](../../CONTRIBUTING.md)

## Features

- Supports both Debian and Alpine as base systems
- Build identity is explicitly defined as `base_system + include_docker + output_formats`
- Output formats include `img`, `vmdk`, and `ova`
- Supports both BIOS and UEFI boot
- Fork users can run custom builds directly on GitHub
- GitHub Actions is already set up for build, test, and release

## Local Development

If you already know you want to build locally, debug, or validate unpushed changes, start here.

### Local Build

Builds run **rootless by default**: chroot-style steps go through Linux user
namespaces, so no `sudo`, loop devices, or mounts are needed (running as root
still works). Requirements: Linux with unprivileged user namespaces enabled
plus `make deps` (which installs `uidmap` and `proot`). Together with the
`/etc/subuid` + `/etc/subgid` ranges that Debian/Ubuntu grant human users by
default, the build maps those delegated ids into its namespace so dpkg's
group ownerships (shadow, crontab, ...) land natively — Debian chroot keeps
native speed; `proot` is the fallback for hosts without user namespaces or
subid delegation, where package phases run noticeably slower. Ubuntu 24.04+
confines unprivileged user namespaces behind AppArmor — run
`sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0` (or boot with
that sysctl) for the native-speed engine. macOS users should build inside a
Linux VM or container.

Not sure whether your machine qualifies — or whether you are inside a
confined sandbox/CI container? Run `make doctor`: a read-only self-check
that prints which engine each base system would pick on this machine and
why. Without a clone, the three probes behind it are:

```bash
grep NoNewPrivs /proc/self/status   # 0 = not confined (1 blocks setuid helpers)
unshare --user --map-root-user -- true && echo "userns OK"
unshare --user --map-root-user --map-auto -- true && echo "subid mapping OK (native-speed Debian)"
```

The build itself picks the engine automatically at startup and explains any
fallback in its log.

Local configuration is layered with this precedence:

`build.env < build.env.<profile> < build.env.local < explicit environment variables`

Recommended usage:

- `build.env`: repository defaults, kept tracked
- `build.env.local`: private machine-specific overrides, suitable for passwords, LAN/DHCP, or local test toggles
- `build.env.<profile>`: scenario-specific profiles such as `lab` or `pve`
- explicit environment variables: one-off overrides, for example `LANDSCAPE_ADMIN_USER=bar make build`

```bash
# Install build dependencies (first time only)
make deps

# Default combination: debian + no-docker + img
make build

# Use a profile: build.env.lab
BUILD_ENV_PROFILE=lab make build

# Local private overrides: build.env.local
make build

# Explicit overrides still have the highest precedence
LANDSCAPE_ADMIN_USER=admin RUN_TEST=readiness make build

# Alpine raw image
make build BASE_SYSTEM=alpine

# Debian + Docker + img,ova
make build INCLUDE_DOCKER=true OUTPUT_FORMATS=img,ova
```

Common local customization inputs include:

- `LANDSCAPE_ADMIN_USER` / `LANDSCAPE_ADMIN_PASS`
- `LANDSCAPE_LAN_SERVER_IP` / `LANDSCAPE_LAN_RANGE_START` / `LANDSCAPE_LAN_RANGE_END` / `LANDSCAPE_LAN_NETMASK`
- `RUN_TEST`

#### Build cache

Local builds keep a persistent cache directory (`.cache/`, override with `CACHE_DIR`) that survives `make clean` / `make distclean`:

- Landscape release assets (webserver binary, static.zip) are cached per version and verified against the upstream `SHASUM256sum.txt`
- Debian apt archives and Alpine apk packages are cached, skipping most package downloads on rebuilds

```bash
make status       # show work/output/cache disk usage
make cache-clean  # purge the build cache entirely (forces re-download)
```

`LANDSCAPE_VERSION=latest` is resolved to a concrete release tag before entering the cache; CI reuses the download cache via `actions/cache`.

### Local Test

```bash
# Automated readiness checks (non-interactive)
make deps-test
make test

# Dataplane tests only apply to include_docker=false raw images
make test-dataplane

# You can also run validation automatically after a build
RUN_TEST=readiness make build
RUN_TEST=readiness,dataplane make build

# When INCLUDE_DOCKER=true, requested dataplane is skipped explicitly and recorded as a skip marker
INCLUDE_DOCKER=true RUN_TEST=readiness,dataplane make build

# You can also point tests at any raw image directly
./tests/test-readiness.sh output/landscape-mini-x86-alpine.img
./tests/test-dataplane.sh output/landscape-mini-x86-debian.img

# Interactive boot (serial console)
make test-serial
```

By default, `make test` and `make test-dataplane` now auto-handle the local runtime resources needed for parallel runs:

- if `SSH_PORT` / `WEB_PORT` are not provided, the test auto-picks free ports
- `make test-dataplane` also auto-picks a free `MCAST_PORT` when not provided
- if the default `output/test-logs` or dataplane cache path is not writable (for example because local build artifacts were created by root), the test automatically falls back to writable temporary directories under `/tmp`
- if you want fixed resources, you can still pass `SSH_PORT`, `WEB_PORT`, `MCAST_PORT`, and MAC values explicitly

Examples:

```bash
# Default local entrypoints; safe to start multiple in parallel
make test
make test-dataplane

# Parallel checks against separate build trees
make test OUTPUT_DIR=output/p1 WORK_DIR=work/p1 &
make test OUTPUT_DIR=output/p2 WORK_DIR=work/p2 &
wait

# Still possible to pin ports / multicast explicitly
make test SSH_PORT=2229 WEB_PORT=9809
make test-dataplane SSH_PORT=2230 WEB_PORT=9810 MCAST_PORT=1240
```

Treat `make test` / `make test-dataplane` as the default local entrypoints. Only call the scripts directly when you deliberately want to target a specific raw image or reuse a fixed port set.

```bash
ssh -o StrictHostKeyChecking=no -p 2222 root@localhost
```
This only applies when you intentionally keep fixed ports, or when using `make test-serial` / `make test-gui`. Auto-allocated tests print the actual assigned ports in their logs.

> `make test-serial` and `make test-gui` still use fixed ports and fixed network settings for interactive debugging. Auto-allocation only applies to `make test`, `make test-dataplane`, and the corresponding scripts.

> Dataplane scheduling still follows `include_docker=false`, not the legacy variant naming.

> The auto-allocation implementation lives in `tests/local-runtime.sh`.

> If you explicitly pass ports / multicast / MAC values, the tests respect them and do not rewrite them.

> To disable auto-allocation completely, pass `LANDSCAPE_TEST_AUTO_ALLOCATE=0`.

Examples:

```bash
LANDSCAPE_TEST_AUTO_ALLOCATE=0 make test SSH_PORT=2222 WEB_PORT=9800
LANDSCAPE_TEST_AUTO_ALLOCATE=0 make test-dataplane SSH_PORT=2224 WEB_PORT=9802 MCAST_PORT=1234
```

If auto-allocation is disabled, you are responsible for avoiding conflicts in ports, log directories, and dataplane network resources.

> Typical local usage: just run `make test` / `make test-dataplane`; only pin resources explicitly when you need stable ports for packet capture or external integration.

```bash
# Show the current local defaults/help
make help
```

When help shows `test SSH port=auto`, `test Web port=auto`, or `dataplane mcast=auto:auto`, it means those resources will be auto-assigned during local test runs. `serial SSH` / `serial Web` are the fixed ports used by `make test-serial` / `make test-gui`.

If you pass explicit values, help reflects them:

```bash
make help SSH_PORT=2229 WEB_PORT=9809 MCAST_PORT=1240
```

That is useful when you need stable ports for debugging.

```bash
# Dataplane also accepts fixed MAC addresses
make test-dataplane ROUTER_WAN_MAC=52:54:00:12:34:44 ROUTER_LAN_MAC=52:54:00:12:35:44 CLIENT_MAC=52:54:00:12:36:44
```

In normal use you do not need to set MACs manually; only do so when reproducing a specific network setup or integrating with external tooling.
## Deployment

### Physical Machine / USB Drive

```bash
dd if=output/landscape-mini-x86-debian.img of=/dev/sdX bs=4M status=progress
```

### Proxmox VE (PVE)

Start with:

- [PVE Installation Guide](./pve-install.md)

### Cloud Server (dd Script)

Use the [reinstall](https://github.com/bin456789/reinstall) script to write the custom image to a cloud server:

```bash
bash <(curl -sL https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh) \
    dd --img='https://github.com/Cloud370/landscape-mini/releases/latest/download/landscape-mini-x86-debian.img.gz'
```

> The root partition automatically expands on first boot to fill the whole disk.

## Default Credentials

| Scenario | Username | Password |
|------|------|------|
| SSH / system login | `root` | `landscape` |
| SSH / system login | `ld` | `landscape` |
| Web UI | `root` | `root` |

> `custom-build.yml` can override Linux / Web UI credentials through workflow inputs or GitHub Secrets. Plaintext inputs are fine for temporary personal use; if security matters, prefer `CUSTOM_ROOT_PASSWORD`, `CUSTOM_API_USERNAME`, and `CUSTOM_API_PASSWORD`.

## Build Configuration

Avoid using tracked `build.env` as the day-to-day customization entry point. Prefer:

- `build.env.local`
- `build.env.<profile>`
- explicit environment variables
- GitHub Actions `Custom Build`

| Variable | Default | Description |
|------|--------|------|
| `BASE_SYSTEM` | `debian` | Base system: `debian` / `alpine` |
| `INCLUDE_DOCKER` | `false` | Include Docker: `true` / `false` |
| `OUTPUT_FORMATS` | `img` | Output formats: `img`, `vmdk`, `ova` (comma-separated) |
| `RUN_TEST` | _(empty)_ | Local test selection: empty / `none`, `readiness`, `readiness,dataplane` |
| `LANDSCAPE_ADMIN_USER` | `root` | Web admin username |
| `LANDSCAPE_ADMIN_PASS` | `root` | Web admin password |
| `LANDSCAPE_LAN_SERVER_IP` | _(empty)_ | LAN gateway / DHCP service IP |
| `LANDSCAPE_LAN_RANGE_START` | _(empty)_ | LAN DHCP range start |
| `LANDSCAPE_LAN_RANGE_END` | _(empty)_ | LAN DHCP range end |
| `LANDSCAPE_LAN_NETMASK` | _(empty)_ | LAN subnet prefix length, for example `24` |
| `APT_MIRROR` | _(auto probe)_ | Explicit Debian package mirror override; if empty, candidates are auto-detected |
| `ALPINE_MIRROR` | _(auto probe)_ | Explicit Alpine package mirror override; if empty, candidates are auto-detected |
| `DOCKER_APT_MIRROR` | _(auto probe)_ | Explicit Debian Docker APT repository override; if empty, candidates are auto-detected |
| `DOCKER_APT_GPG_URL` | _(auto probe)_ | Explicit Debian Docker APT GPG key URL override; if empty, candidates are auto-detected |
| `LANDSCAPE_VERSION` | `v0.24.2` | Upstream Landscape version |
| `LANDSCAPE_REPO` | `https://github.com/ThisSeanZhang/landscape` | Upstream Landscape release repository |
| `IMAGE_SIZE_MB` | `2048` | Initial image size (shrunk automatically later) |
| `ROOT_PASSWORD` | `landscape` | Login password for `root` / `ld` |
| `TIMEZONE` | `Asia/Shanghai` | Time zone |
| `LOCALE` | `C.UTF-8` | Default system locale |
| `EXTRA_LOCALES` | `en_US.UTF-8` | Additional Debian UTF-8 locales to generate |

### Custom Build (GitHub Actions)

The repository provides `custom-build.yml` as an explicit-tuple build entry point for fork users. It supports:

- `base_system`: `debian` / `alpine`
- `include_docker`: `true` / `false`
- `output_formats` (use `ova` as the canonical OVA output format name)
- `landscape_version`
- `lan_server_ip` / `lan_range_start` / `lan_range_end` / `lan_netmask`
- `root_password`
- `api_username` / `api_password`
- `run_test`

Current precedence: **direct inputs > secrets > defaults**.

The workflow validates inputs first, catching invalid `output_formats`, `run_test`, and basic network input errors before the build starts.

The unified test contract is:

- empty / `none`: build only
- `readiness`
- `readiness,dataplane`

When `include_docker=true`, requested dataplane is explicitly skipped with a reason in the logs.

The workflow writes the following identity fields into `build-metadata.txt`:

- `base_system`
- `include_docker`
- `output_formats`
- `run_test`
- `produced_files`
- `artifact_id`
- `release_channel`

The effective network topology is shipped inside the artifact as `effective-landscape_init.toml` for `test.yml`, fixed-release publishing, and tag release rebuild validation.

Successful Custom Build runs now publish two entry points in the fork:

- stable entry: `custom-build-latest`
- immutable history entry: `custom-build-<artifact_id>`

This means:

- `custom-build-latest` always points to the newest successful Custom Build
- `custom-build-<artifact_id>` permanently preserves that exact build and is not replaced by later runs

Common link formats:

- Latest release page: `https://github.com/<owner>/landscape-mini/releases/tag/custom-build-latest`
- Latest direct download: `https://github.com/<owner>/landscape-mini/releases/download/custom-build-latest/<asset>`
- History release page: `https://github.com/<owner>/landscape-mini/releases/tag/custom-build-<artifact_id>`
- History direct download: `https://github.com/<owner>/landscape-mini/releases/download/custom-build-<artifact_id>/<asset>`

The workflow summary renders the latest page, history page, and per-asset direct links for easy copy/paste.

Artifacts remain immutable as well; if you want to keep the workflow-side identity, you can still record `run_id` / `artifact_id`.

## Automated Testing

### Readiness Checks

`make test` or `./tests/test-readiness.sh <image.img>` runs the shared router readiness contract:

1. Copy the image to a temporary file to protect the build artifact
2. Start QEMU in the background and auto-detect KVM
3. Wait for SSH, API listener, API login, and layout detection
4. Verify `eth0` / `eth1` and core services reach the running state
5. When `include_docker=true`, additionally verify Docker is available
6. Emit readiness / service / diagnostics snapshots and clean up QEMU

### Dataplane Tests

`make test-dataplane` or `./tests/test-dataplane.sh <image.img>` validates real client-visible dataplane behavior with a two-VM topology:

```text
Router VM (eth0=WAN/SLIRP, eth1=LAN/mcast) ←→ Client VM (CirrOS, eth0=mcast)
```

Coverage includes DHCP lease assignment, lease visibility in the Router API, and LAN connectivity between Router and Client.

> Dataplane scheduling is based on `include_docker=false`, not legacy variant names.

## CI/CD

- **CI**: Manual runs are always available. Automatic `push main` / `PR -> main` runs trigger only when shell or CI execution logic changes.
- **Fork protection**: automatic events in forks are skipped by default; manual dispatch remains available.
- **Automatic CI validation surface**: only `debian + include_docker=false`, requesting raw `img` only.
- **Readiness / dataplane coverage**: automatic CI runs `readiness,dataplane` for `include_docker=false`.
- **Artifact contract**: every image artifact includes raw `.img`, `build-metadata.txt`, and `effective-landscape_init.toml`; automatic CI no longer exports `.vmdk` / `.ova`.
- **Custom Build**: `custom-build.yml` lets fork users build explicit tuples, validates inputs early, and provides clearer download / import guidance.
- **Manual Retest**: `test.yml` retests the Debian default public tuple by `run_id` or `artifact_id`, with SSH / API credentials passed in again.
- **Release**: when a `v*` tag is pushed, `release.yml` rebuilds Debian Docker / non-Docker artifacts from that tagged commit instead of promoting CI artifacts, and publishes the default public surface: `.img.gz` + `.ova`.
- **Alpine**: Alpine is no longer part of the default public release surface; use `Custom Build` when you need it.

## License

This project is released under **GPL-3.0**, consistent with upstream [Landscape Router](https://github.com/ThisSeanZhang/landscape).
