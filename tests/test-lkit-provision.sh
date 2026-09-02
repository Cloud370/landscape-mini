#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Validate the lkit rootfs provisioning layout without booting an image.
# =============================================================================
# Builds small fixtures (fake webserver/lkit shell scripts, a static.zip) and
# asserts the layout, unit contents, install state, and init-config auth
# handling produced by scripts/provision-lkit-image.sh match what lkit
# expects (lkit-cli/src/service/systemd.rs + deployment/state.rs).
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/landscape-lkit-provision.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

for tool in zip jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "skip: $tool is required for the lkit provisioning test (see make deps-test)"
        exit 0
    fi
done

make_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/rootfs" "$fixture/static-src/static"
    printf '#!/bin/sh\nexit 0\n' > "$fixture/landscape-webserver"
    printf '#!/bin/sh\nexit 0\n' > "$fixture/lkit"
    chmod 0755 "$fixture/landscape-webserver" "$fixture/lkit"
    printf 'fixture\n' > "$fixture/static-src/static/index.html"
    (cd "$fixture/static-src" && zip -qr "$fixture/static.zip" static)
}

EXPECTED_LANDSCAPE_UNIT='[Unit]
Description=Landscape Router
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/root/.lkit/landscape/current/landscape-webserver --config-dir /root/.lkit/landscape/data --web /root/.lkit/landscape/current/static
User=root
Restart=always
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target'

EXPECTED_LKIT_UNIT='[Unit]
Description=Lkit daemon
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/lkit daemon
User=root
Restart=always
KillMode=process

[Install]
WantedBy=multi-user.target'

assert_common_layout() {
    local rootfs="$1"
    local version="$2"
    local state="$rootfs/root/.lkit/state/install-state.json"

    test -x "$rootfs/usr/local/bin/lkit"
    test -L "$rootfs/root/.lkit/landscape/current"
    test "$(readlink "$rootfs/root/.lkit/landscape/current")" = "releases/$version"
    test -x "$rootfs/root/.lkit/landscape/releases/$version/landscape-webserver"
    test -d "$rootfs/root/.lkit/landscape/releases/$version/static"
    test -f "$rootfs/root/.lkit/landscape/releases/$version/static.zip"

    # Units must stay byte-identical to lkit's own renderers.
    diff -u <(printf '%s\n' "$EXPECTED_LANDSCAPE_UNIT") \
        "$rootfs/root/.lkit/landscape/service/landscape-router.service"
    diff -u <(printf '%s\n' "$EXPECTED_LKIT_UNIT") \
        "$rootfs/usr/local/lib/lkit/lkit.service"

    # systemd registration links
    test -L "$rootfs/etc/systemd/system/landscape-router.service"
    test "$(readlink "$rootfs/etc/systemd/system/landscape-router.service")" = "/root/.lkit/landscape/service/landscape-router.service"
    test -L "$rootfs/etc/systemd/system/lkit.service"
    test "$(readlink "$rootfs/etc/systemd/system/lkit.service")" = "/usr/local/lib/lkit/lkit.service"
    test -L "$rootfs/etc/systemd/system/multi-user.target.wants/landscape-router.service"
    test -L "$rootfs/etc/systemd/system/multi-user.target.wants/lkit.service"

    # Install state contract (schema/layout versions, shas of shipped bytes).
    test "$(jq -r .schema_version "$state")" = "1"
    test "$(jq -r .layout_version "$state")" = "2"
    test "$(jq -r .canonical_install_root "$state")" = "/root/.lkit/landscape"
    test "$(jq -r .active_version "$state")" = "$version"
    test "$(jq -r .initialization.status "$state")" = "complete"
    test "$(jq -r .initialization.lock_present "$state")" = "true"
    test -n "$(jq -r .initialization.initialized_at "$state")"
    test "$(jq -r .service.manager "$state")" = "systemd"
    test "$(jq -r .service.definition_path "$state")" = "service/landscape-router.service"
    test "$(jq -r .service.definition_sha256 "$state")" \
        = "$(sha256sum "$rootfs/root/.lkit/landscape/service/landscape-router.service" | awk '{print $1}')"
    test "$(jq -r .assets.webserver.sha256 "$state")" \
        = "$(sha256sum "$rootfs/root/.lkit/landscape/releases/$version/landscape-webserver" | awk '{print $1}')"
    test "$(jq -r .assets.static_archive.sha256 "$state")" \
        = "$(sha256sum "$rootfs/root/.lkit/landscape/releases/$version/static.zip" | awk '{print $1}')"

    # The image must not pre-create the init lock; Landscape writes it on boot.
    test ! -e "$rootfs/root/.lkit/landscape/data/landscape_init.lock"

    # No legacy layout next to the lkit one.
    test ! -e "$rootfs/root/landscape-webserver"
    test ! -e "$rootfs/root/.landscape-router"
    test ! -e "$rootfs/etc/landscape/runtime.env"
}

run_provision() {
    local fixture="$1"
    shift
    "$PROJECT_DIR/scripts/provision-lkit-image.sh" \
        --rootfs "$fixture/rootfs" \
        --version v1.2.3 \
        --landscape-webserver "$fixture/landscape-webserver" \
        --static-zip "$fixture/static.zip" \
        --lkit "$fixture/lkit" \
        --created-at "2026-01-02T03:04:05Z" \
        "$@" >/dev/null
}

echo "== case: with explicit init config =="
with_init="$WORK_DIR/with-init"
make_fixture "$with_init"
printf 'version = "1.2.3"\n\n[[ifaces]]\nname = "eth9"\n' > "$with_init/init.toml"
run_provision "$with_init" --init "$with_init/init.toml" --admin-user admin --admin-pass 'sec"ret\'
assert_common_layout "$with_init/rootfs" 1.2.3
init="$with_init/rootfs/root/.lkit/landscape/data/landscape_init.toml"
grep -q 'name = "eth9"' "$init"
grep -q '^\[config\.auth\]$' "$init"
grep -q 'admin_user = "admin"' "$init"
grep -q 'admin_pass = "sec\\"ret\\\\"' "$init"
test "$(stat -c '%a' "$init")" = "600"
test "$(stat -c '%a' "$with_init/rootfs/root/.lkit/state/install-state.json")" = "600"
test "$(jq -r .committed_at "$with_init/rootfs/root/.lkit/state/install-state.json")" = "2026-01-02T03:04:05Z"

echo "== case: init config keeps an existing [config.auth] untouched =="
pre_auth="$WORK_DIR/pre-auth"
make_fixture "$pre_auth"
printf 'version = "1.2.3"\n\n[config.auth]\nadmin_user = "keep"\nadmin_pass = "also"\n' > "$pre_auth/init.toml"
run_provision "$pre_auth" --init "$pre_auth/init.toml" --admin-user admin --admin-pass other
assert_common_layout "$pre_auth/rootfs" 1.2.3
init="$pre_auth/rootfs/root/.lkit/landscape/data/landscape_init.toml"
grep -q 'admin_user = "keep"' "$init"
if grep -q 'admin_user = "admin"' "$init"; then
    echo "FAIL: provision overwrote an existing [config.auth]" >&2
    exit 1
fi

echo "== case: no init config (auth-only default) =="
no_init="$WORK_DIR/no-init"
make_fixture "$no_init"
run_provision "$no_init" --admin-user root --admin-pass root
assert_common_layout "$no_init/rootfs" 1.2.3
init="$no_init/rootfs/root/.lkit/landscape/data/landscape_init.toml"
grep -q '^version = "1.2.3"$' "$init"
grep -q '^\[config\.auth\]$' "$init"
grep -q 'admin_user = "root"' "$init"

echo "== case: re-running provisioning stays idempotent =="
run_provision "$no_init" --admin-user root --admin-pass root
assert_common_layout "$no_init/rootfs" 1.2.3

echo "== case: rejects pre-release and malformed versions =="
bad_version="$WORK_DIR/bad-version"
make_fixture "$bad_version"
for version in v1.2.3-rc.1 1.2 latest v0.24; do
    if "$PROJECT_DIR/scripts/provision-lkit-image.sh" \
        --rootfs "$bad_version/rootfs" \
        --version "$version" \
        --landscape-webserver "$bad_version/landscape-webserver" \
        --static-zip "$bad_version/static.zip" \
        --lkit "$bad_version/lkit" >/dev/null 2>&1; then
        echo "FAIL: version '$version' must be rejected" >&2
        exit 1
    fi
done

echo "lkit image provisioning checks passed"
