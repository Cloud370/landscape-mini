#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Provision a Debian rootfs with the lkit-managed Landscape layout.
# =============================================================================
# The image ships the same directory tree, unit files, and install state that
# `lkit install` would produce, so landscape-kit owns the deployment from the
# first boot without any user-side install/migrate step:
#
#   /usr/local/bin/lkit                       lkit binary
#   /usr/local/lib/lkit/lkit.service          daemon unit origin
#   /root/.lkit/landscape/releases/<ver>/     webserver + static web assets
#   /root/.lkit/landscape/current -> releases/<ver>
#   /root/.lkit/landscape/data/               landscape_init.toml (0600)
#   /root/.lkit/landscape/service/            landscape-router.service origin
#   /root/.lkit/state/install-state.json      committed install state
#
# Unit contents must stay byte-identical to lkit's own renderers
# (lkit-cli/src/service/systemd.rs): lkit validates ExecStart and re-checks
# definition_sha256 against this state file. The image is intentionally left
# stopped — Landscape creates its runtime database and the init lock on the
# first boot.
# =============================================================================

usage() {
    cat >&2 <<'EOF'
Usage: provision-lkit-image.sh --rootfs DIR --version vX.Y.Z
  --landscape-webserver FILE --static-zip FILE --lkit FILE
  [--init FILE] [--admin-user USER] [--admin-pass PASS]
  [--created-at RFC3339]
EOF
}

ROOTFS=
VERSION=
LANDSCAPE_BINARY=
STATIC_ZIP=
LKIT_BINARY=
INIT_FILE=
ADMIN_USER=root
ADMIN_PASS=root
CREATED_AT=

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS=${2:?missing value for --rootfs}; shift 2 ;;
        --version) VERSION=${2:?missing value for --version}; shift 2 ;;
        --landscape-webserver) LANDSCAPE_BINARY=${2:?missing value for --landscape-webserver}; shift 2 ;;
        --static-zip) STATIC_ZIP=${2:?missing value for --static-zip}; shift 2 ;;
        --lkit) LKIT_BINARY=${2:?missing value for --lkit}; shift 2 ;;
        --init) INIT_FILE=${2:?missing value for --init}; shift 2 ;;
        --admin-user) ADMIN_USER=${2:?missing value for --admin-user}; shift 2 ;;
        --admin-pass) ADMIN_PASS=${2:?missing value for --admin-pass}; shift 2 ;;
        --created-at) CREATED_AT=${2:?missing value for --created-at}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "$ROOTFS" && -n "$VERSION" && -n "$LANDSCAPE_BINARY" && -n "$STATIC_ZIP" && -n "$LKIT_BINARY" ]] || {
    usage
    exit 2
}
[[ -d "$ROOTFS" ]] || { echo "ERROR: rootfs does not exist: $ROOTFS" >&2; exit 1; }
[[ -f "$LANDSCAPE_BINARY" && -x "$LANDSCAPE_BINARY" ]] || { echo "ERROR: invalid Landscape binary: $LANDSCAPE_BINARY" >&2; exit 1; }
[[ -f "$STATIC_ZIP" ]] || { echo "ERROR: static.zip does not exist: $STATIC_ZIP" >&2; exit 1; }
[[ -f "$LKIT_BINARY" && -x "$LKIT_BINARY" ]] || { echo "ERROR: invalid lkit binary: $LKIT_BINARY" >&2; exit 1; }
if [[ -n "$INIT_FILE" && ! -f "$INIT_FILE" ]]; then
    echo "ERROR: init file does not exist: $INIT_FILE" >&2
    exit 1
fi

# The install state records a stable SemVer without the release-tag "v"
# prefix; lkit rejects pre-release / build metadata versions.
ACTIVE_VERSION="${VERSION#v}"
[[ "$ACTIVE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "ERROR: version is not a stable SemVer (X.Y.Z): $VERSION" >&2
    exit 1
}

timestamp="${CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Host-side staging tree vs the in-image install root the units must point at.
LANDSCAPE_ROOT="$ROOTFS/root/.lkit/landscape"
IMAGE_LANDSCAPE_ROOT="/root/.lkit/landscape"
RELEASE_DIR="$LANDSCAPE_ROOT/releases/$ACTIVE_VERSION"
STATE_DIR="$ROOTFS/root/.lkit/state"
SERVICE_DIR="$LANDSCAPE_ROOT/service"

# ---- lkit binary + daemon unit origin ---------------------------------------
mkdir -p "$ROOTFS/usr/local/bin" "$ROOTFS/usr/local/lib/lkit"
install -m 0755 "$LKIT_BINARY" "$ROOTFS/usr/local/bin/lkit"

cat > "$ROOTFS/usr/local/lib/lkit/lkit.service" <<'EOF'
[Unit]
Description=Lkit daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/lkit daemon
User=root
Restart=always
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$ROOTFS/usr/local/lib/lkit/lkit.service"

# ---- Landscape release payload ----------------------------------------------
mkdir -p "$RELEASE_DIR" "$LANDSCAPE_ROOT/data" "$SERVICE_DIR" "$STATE_DIR"

install -m 0755 "$LANDSCAPE_BINARY" "$RELEASE_DIR/landscape-webserver"
# Match the image cleanup while keeping the recorded checksum aligned with
# the bytes that actually ship (state below hashes the stripped file).
strip --strip-unneeded "$RELEASE_DIR/landscape-webserver" 2>/dev/null || true

install -m 0644 "$STATIC_ZIP" "$RELEASE_DIR/static.zip"
rm -rf "$RELEASE_DIR/static"
mkdir -p "$RELEASE_DIR/static"
unzip -q "$RELEASE_DIR/static.zip" -d "$RELEASE_DIR"
[[ -d "$RELEASE_DIR/static" ]] || { echo "ERROR: static.zip did not contain static/" >&2; exit 1; }

ln -sfn "releases/$ACTIVE_VERSION" "$LANDSCAPE_ROOT/current"

# ---- init config -------------------------------------------------------------
# The canonical lkit unit carries no EnvironmentFile, so the web admin
# credentials must live inside landscape_init.toml ([config.auth]) — the same
# place `lkit install` puts them.
INIT_DEST="$LANDSCAPE_ROOT/data/landscape_init.toml"
toml_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

if [[ -n "$INIT_FILE" ]]; then
    install -m 0600 "$INIT_FILE" "$INIT_DEST"
    if ! grep -qE '^\[config\.auth\]' "$INIT_DEST"; then
        printf '\n[config.auth]\nadmin_user = "%s"\nadmin_pass = "%s"\n' \
            "$(toml_escape "$ADMIN_USER")" "$(toml_escape "$ADMIN_PASS")" >> "$INIT_DEST"
        chmod 0600 "$INIT_DEST"
    fi
else
    cat > "$INIT_DEST" <<EOF
version = "$ACTIVE_VERSION"

[config.auth]
admin_user = "$(toml_escape "$ADMIN_USER")"
admin_pass = "$(toml_escape "$ADMIN_PASS")"
EOF
    chmod 0600 "$INIT_DEST"
fi

# ---- Landscape service unit origin -------------------------------------------
cat > "$SERVICE_DIR/landscape-router.service" <<EOF
[Unit]
Description=Landscape Router
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$IMAGE_LANDSCAPE_ROOT/current/landscape-webserver --config-dir $IMAGE_LANDSCAPE_ROOT/data --web $IMAGE_LANDSCAPE_ROOT/current/static
User=root
Restart=always
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SERVICE_DIR/landscape-router.service"

# ---- systemd registration ----------------------------------------------------
# The wants links are the same links `systemctl enable` would create in the
# target image; origins stay under lkit-managed paths.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /root/.lkit/landscape/service/landscape-router.service \
    "$ROOTFS/etc/systemd/system/landscape-router.service"
ln -sfn /usr/local/lib/lkit/lkit.service \
    "$ROOTFS/etc/systemd/system/lkit.service"
ln -sfn ../landscape-router.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/landscape-router.service"
ln -sfn ../lkit.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/lkit.service"

# ---- committed install state --------------------------------------------------
webserver_sha=$(sha256sum "$RELEASE_DIR/landscape-webserver" | awk '{print $1}')
webserver_size=$(stat -c '%s' "$RELEASE_DIR/landscape-webserver")
static_sha=$(sha256sum "$RELEASE_DIR/static.zip" | awk '{print $1}')
static_size=$(stat -c '%s' "$RELEASE_DIR/static.zip")
unit_sha=$(sha256sum "$SERVICE_DIR/landscape-router.service" | awk '{print $1}')

# Initialization is recorded as complete with the lock observed: Landscape
# itself creates landscape_init.lock on the first boot, and lkit's validator
# requires the pair (status=complete, lock_present, initialized_at) to agree.
cat > "$STATE_DIR/install-state.json" <<EOF
{
  "schema_version": 1,
  "layout_version": 2,
  "install_root": "/root/.lkit/landscape",
  "canonical_install_root": "/root/.lkit/landscape",
  "active_version": "$ACTIVE_VERSION",
  "assets": {
    "webserver": {"architecture": "x86_64", "sha256": "$webserver_sha", "size": $webserver_size},
    "static_archive": {"sha256": "$static_sha", "size": $static_size}
  },
  "initialization": {
    "status": "complete",
    "lock_present": true,
    "initialized_at": "$timestamp"
  },
  "service": {
    "manager": "systemd",
    "registered": true,
    "enabled": true,
    "verified": true,
    "definition_path": "service/landscape-router.service",
    "definition_sha256": "$unit_sha"
  },
  "last_transaction_id": null,
  "committed_at": "$timestamp"
}
EOF
chmod 0600 "$STATE_DIR/install-state.json"

echo "  lkit image provisioning complete: version=$ACTIVE_VERSION"
