# Embedding landscape-kit (lkit)

The default image uses the legacy layout: `/root/landscape-webserver` started directly by a fixed systemd unit. With `INCLUDE_LKIT` enabled, the build embeds [landscape-kit](https://github.com/landscape-router/landscape-kit) (`lkit`) together with the Landscape layout it manages — no manual install / migrate step after provisioning; lkit owns the deployment from the first boot.

```bash
# Local build (Debian only)
INCLUDE_LKIT=true make build

# Pin the landscape-kit version
INCLUDE_LKIT=true LKIT_VERSION=v0.5.0 make build

# GitHub Actions: tick include_lkit in the Custom Build workflow
```

## Variables

| Variable | Default | Notes |
|---|---|---|
| `INCLUDE_LKIT` | `false` | Embed landscape-kit at build time: `true` / `false`; requires `BASE_SYSTEM=debian` |
| `LKIT_REPO` | `https://github.com/landscape-router/landscape-kit` | landscape-kit release repository |
| `LKIT_VERSION` | `latest` | landscape-kit version; `latest` is resolved to a concrete tag before caching |

Image artifacts get a `-lkit` suffix (e.g. `landscape-mini-x86-debian-lkit.img`); `build-metadata.txt` records `include_lkit` and `lkit_version_resolved`.

## Embedded layout

The produced rootfs matches the on-disk state of a committed `lkit install`:

- `/usr/local/bin/lkit` and `/usr/local/lib/lkit/lkit.service` (daemon unit origin)
- `/root/.lkit/landscape/releases/<version>/` (webserver + static assets), the `current` symlink, `data/`, `service/`
- `/root/.lkit/state/install-state.json` (committed install state recording sha256 of the stripped binary)
- `/etc/systemd/system/{landscape-router,lkit}.service` symlinks to the origins above, enabled in `multi-user.target.wants`

Unit contents are byte-identical to what lkit itself renders (lkit validates `ExecStart` and `definition_sha256`), so `lkit check` / `lkit update` work right after boot.

## Topology and credentials

- Topology follows the existing mechanisms: `configs/landscape_init.toml`, the Custom Build LAN inputs, or `EFFECTIVE_CONFIG_PATH`. The config is installed to `/root/.lkit/landscape/data/landscape_init.toml`.
- Web admin credentials (`LANDSCAPE_ADMIN_USER` / `LANDSCAPE_ADMIN_PASS`) are injected into the init config's `[config.auth]` — the lkit unit carries no `EnvironmentFile`, matching what `lkit install` does. An init config that already ships its own `[config.auth]` is left untouched.

## First boot

The build never starts Landscape and never pre-creates `landscape_init.lock`. On the first boot Landscape initializes from the init config and writes the lock itself (matching the `status: complete` / `lock_present: true` recorded in the state). Upgrades, rollbacks, and backups are then handled by `lkit update` / `lkit switch` and friends.

## Layout validation test

`make test-lkit-provision` (`tests/test-lkit-provision.sh`) uses small fixtures to verify the layout, unit byte-content, state checksums, and credential injection produced by the provisioning script — no full image build required; CI runs it before building too.
