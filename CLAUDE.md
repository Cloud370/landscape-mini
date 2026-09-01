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
make build
make build BASE_SYSTEM=alpine
make build INCLUDE_DOCKER=true OUTPUT_FORMATS=img,ova
make test
make test-dataplane
make test-serial
make ssh
```

## Defaults and important inputs

- Default upstream version comes from `build.env` (`LANDSCAPE_VERSION`, currently `v0.24.2`)
- `configs/landscape_init.toml` is version-coupled to `LANDSCAPE_VERSION`: upstream (>= v0.19)
  enforces an exact `version` field and the static NAT table layout changed in v0.24.
  `build.sh` pins the `version` field automatically from the resolved landscape version
  (`latest` is resolved to a concrete tag first); pinning older upstream versions requires
  matching the init config by hand.
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
