#!/bin/bash
# =============================================================================
# Landscape Mini - End-to-End Dataplane Test
# =============================================================================
#
# Validates stable client-visible dataplane behavior after the router has already
# satisfied the shared readiness contract.
#
# E2E scope:
#   1. Router satisfies the readiness contract
#   2. Client VM boots on the LAN segment
#   3. Client receives DHCP on the expected LAN subnet
#   4. DHCP lease is visible in the router API
#   5. Router and client can communicate on the LAN
#
# Deliberately not used as hard gating here:
#   - public DNS lookups
#   - router-self curl to internet
#   - ARP as a substitute for ping success
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

IMAGE_PATH="${1:-${PROJECT_DIR}/output/landscape-mini-x86.img}"
SSH_PORT="${SSH_PORT:-2222}"
WEB_PORT="${WEB_PORT:-9800}"
LANDSCAPE_CONTROL_PORT="${LANDSCAPE_CONTROL_PORT:-6443}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="landscape"
API_USERNAME="root"
API_PASSWORD="root"
SSH_TIMEOUT="${SSH_TIMEOUT:-120}"
SHUTDOWN_TIMEOUT=15
DHCP_TIMEOUT="${DHCP_TIMEOUT:-120}"
LANDSCAPE_TEST_NAME="e2e"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"

CIRROS_VERSION="0.6.2"
CIRROS_URL="https://github.com/cirros-dev/cirros/releases/download/${CIRROS_VERSION}/cirros-${CIRROS_VERSION}-x86_64-disk.img"
CIRROS_CHECKSUM_MD5="c8fc807773e5354afe61636071771906"
CIRROS_USER="cirros"
CIRROS_PASSWORD="gocubsgo"

MCAST_ADDR="230.0.0.1"
MCAST_PORT="1234"
ROUTER_WAN_MAC="52:54:00:12:34:01"
ROUTER_LAN_MAC="52:54:00:12:34:02"
CLIENT_MAC="52:54:00:12:34:10"

CLIENT_SERIAL_LOG=""
CLIENT_PID=""
CLIENT_PIDFILE=""
CLIENT_MONITOR=""
TEMP_CIRROS=""
CLIENT_DIAGNOSTICS_FILE=""
CLIENT_RESULTS_FILE=""

resolve_default_landscape_version() {
    awk -F'"' '/^LANDSCAPE_VERSION=/{print $2; exit}' "${PROJECT_DIR}/build.env"
}

cleanup() {
    local exit_code=$?
    set +e

    if [[ -n "${CLIENT_PID}" ]] && kill -0 "${CLIENT_PID}" 2>/dev/null; then
        info "Stopping client VM (PID ${CLIENT_PID})..."
        if [[ -n "${CLIENT_MONITOR}" ]] && [[ -S "${CLIENT_MONITOR}" ]]; then
            echo "quit" | socat -T2 STDIN UNIX-CONNECT:"${CLIENT_MONITOR}" &>/dev/null || true
            sleep 2
        fi
        if kill -0 "${CLIENT_PID}" 2>/dev/null; then
            kill -9 "${CLIENT_PID}" 2>/dev/null || true
            wait "${CLIENT_PID}" 2>/dev/null || true
        fi
    fi

    [[ -n "${TEMP_CIRROS}" ]] && rm -f "${TEMP_CIRROS}"
    [[ -n "${CLIENT_PIDFILE}" ]] && rm -f "${CLIENT_PIDFILE}"
    [[ -n "${CLIENT_MONITOR}" ]] && rm -f "${CLIENT_MONITOR}"

    landscape_router_cleanup
    exit $exit_code
}

trap cleanup EXIT

preflight() {
    info "Preflight checks..."

    ensure_image_exists "${IMAGE_PATH}" || {
        error "Run 'make build' first."
        exit 2
    }

    if ! require_commands qemu-system-x86_64 qemu-img sshpass curl socat jq awk md5sum; then
        error "Run 'make deps-test' to install test dependencies."
        exit 2
    fi

    if ! ensure_local_ports_free "${SSH_PORT}" "${WEB_PORT}"; then
        exit 2
    fi

    load_landscape_topology || exit 2
    landscape_router_init_paths "e2e"

    CLIENT_SERIAL_LOG="${LANDSCAPE_TEST_LOG_DIR}/e2e-serial-client.log"
    CLIENT_DIAGNOSTICS_FILE="${LANDSCAPE_TEST_LOG_DIR}/e2e-client-diagnostics.txt"
    CLIENT_RESULTS_FILE="${LANDSCAPE_RESULTS_FILE}"
    rm -f "${CLIENT_SERIAL_LOG}" "${CLIENT_DIAGNOSTICS_FILE}"

    LANDSCAPE_TEST_VARIANT="${LANDSCAPE_TEST_VARIANT:-$(landscape_guess_variant_from_image_path "${IMAGE_PATH}")}"
    LANDSCAPE_TEST_LANDSCAPE_VERSION="${LANDSCAPE_TEST_LANDSCAPE_VERSION:-$(resolve_default_landscape_version)}"
    landscape_write_test_metadata "${IMAGE_PATH}"

    ROUTER_WAN_DEVICE_OPTS=",mac=${ROUTER_WAN_MAC}"
    ROUTER_LAN_DEVICE_OPTS=",mac=${ROUTER_LAN_MAC}"
    ROUTER_WAN_NETDEV="user,id=wan,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:${LANDSCAPE_CONTROL_PORT}"
    ROUTER_LAN_NETDEV="socket,id=lan,mcast=${MCAST_ADDR}:${MCAST_PORT}"

    ok "Preflight passed"
}

download_cirros() {
    local download_dir="${PROJECT_DIR}/work/downloads/cirros/${CIRROS_VERSION}"
    local cirros_file="${download_dir}/cirros-${CIRROS_VERSION}-x86_64-disk.img"
    local actual_md5=""

    mkdir -p "${download_dir}"

    if [[ ! -f "${cirros_file}" ]]; then
        info "Downloading CirrOS ${CIRROS_VERSION} ..." >&2
        if ! curl -fL --retry 3 --retry-delay 5 -o "${cirros_file}" "${CIRROS_URL}" >&2; then
            error "Failed to download CirrOS from ${CIRROS_URL}" >&2
            return 1
        fi
    else
        info "CirrOS image already cached" >&2
    fi

    actual_md5="$(md5sum "${cirros_file}" | awk '{print $1}')"
    if [[ "${actual_md5}" != "${CIRROS_CHECKSUM_MD5}" ]]; then
        error "CirrOS checksum mismatch: expected ${CIRROS_CHECKSUM_MD5}, got ${actual_md5}" >&2
        return 1
    fi

    ok "CirrOS ready (${cirros_file})" >&2
    echo "${cirros_file}"
}

start_client() {
    local cirros_file="$1"

    info "Preparing client disk image..."

    TEMP_CIRROS=$(mktemp "${LANDSCAPE_TEST_LOG_DIR}/e2e-client-XXXXXX.qcow2")
    rm -f "${TEMP_CIRROS}"
    qemu-img create -f qcow2 -b "${cirros_file}" -F qcow2 "${TEMP_CIRROS}" >/dev/null

    CLIENT_PIDFILE=$(mktemp "${LANDSCAPE_TEST_LOG_DIR}/e2e-client-pid-XXXXXX")
    CLIENT_MONITOR=$(mktemp -u "${LANDSCAPE_TEST_LOG_DIR}/e2e-client-monitor-XXXXXX.sock")

    local kvm_args=()
    read -r -a kvm_args <<< "$(detect_kvm)"

    info "Starting client VM (CirrOS)..."

    qemu-system-x86_64 \
        "${kvm_args[@]}" \
        -m 256 \
        -smp 1 \
        -drive "file=${TEMP_CIRROS},format=qcow2,if=virtio" \
        -device "virtio-net-pci,netdev=net0,mac=${CLIENT_MAC}" \
        -netdev "socket,id=net0,mcast=${MCAST_ADDR}:${MCAST_PORT}" \
        -display none \
        -serial "file:${CLIENT_SERIAL_LOG}" \
        -monitor "unix:${CLIENT_MONITOR},server,nowait" \
        -pidfile "${CLIENT_PIDFILE}" \
        -daemonize

    if CLIENT_PID=$(wait_for_pidfile "${CLIENT_PIDFILE}" "Client VM" 10); then
        if kill -0 "${CLIENT_PID}" 2>/dev/null; then
            ok "Client VM started (PID ${CLIENT_PID})"
            return 0
        fi
    fi

    error "Client VM exited immediately"
    dump_log_tail "${CLIENT_SERIAL_LOG}" "client serial log"
    return 1
}

write_client_diagnostics() {
    local client_ip="${1:-}"
    {
        echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "client_ip=${client_ip}"
        echo "client_mac=${CLIENT_MAC}"
        echo "router_lan_iface=${LANDSCAPE_EXPECTED_LAN_IFACE}"
        echo "router_lan_gateway=${LANDSCAPE_EXPECTED_LAN_GATEWAY}"
        echo ""
        echo "== client serial log tail =="
        tail -n 100 "${CLIENT_SERIAL_LOG}" 2>/dev/null || true
        echo ""
        echo "== router arp/neigh =="
        guest_run "ip neigh show" 2>&1 || true
        echo ""
        echo "== router ping route =="
        guest_run "ip route get ${client_ip}" 2>&1 || true
        echo ""
        echo "== router dhcp assigned_ips =="
        landscape_api_dhcp_assigned "${LANDSCAPE_ROUTER_API_TOKEN}" 2>&1 || true
    } > "${CLIENT_DIAGNOSTICS_FILE}"
}

wait_for_dhcp_assignment() {
    local token="$1"
    local elapsed=0
    local client_ip=""

    info "Waiting for client DHCP assignment (timeout: ${DHCP_TIMEOUT}s)..." >&2

    while [[ $elapsed -lt $DHCP_TIMEOUT ]]; do
        if ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
            error "Client VM died while waiting for DHCP" >&2
            dump_log_tail "${CLIENT_SERIAL_LOG}" "client serial log" >&2
            write_client_diagnostics
            return 1
        fi

        client_ip="$(landscape_api_dhcp_assigned_ip "$token" "$LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX" 2>/dev/null || true)"
        if [[ -n "$client_ip" ]]; then
            ok "Client received DHCP: ${client_ip} (after ${elapsed}s)" >&2
            echo "$client_ip"
            return 0
        fi

        sleep 5
        ((elapsed += 5))
        if ((elapsed % 15 == 0)); then
            info "  ...still waiting for DHCP (${elapsed}s)" >&2
        fi
    done

    error "DHCP assignment timeout after ${DHCP_TIMEOUT}s" >&2
    dump_log_tail "${CLIENT_SERIAL_LOG}" "client serial log" >&2
    write_client_diagnostics
    return 1
}

router_can_ping_client() {
    local client_ip="$1"
    local attempt

    for attempt in 1 2 3 4 5 6; do
        if guest_run "ping -c 2 -W 3 ${client_ip}" &>/dev/null; then
            return 0
        fi
        sleep 3
    done

    return 1
}

run_e2e_checks() {
    local token="$1"
    local client_ip="$2"
    local assigned_ip=""

    reset_test_counters
    set +e

    echo "============================================================"
    echo "Landscape Mini — End-to-End Dataplane Tests"
    echo "============================================================"
    echo ""

    echo "---- DHCP ----"
    run_check "Client received DHCP IP (${client_ip})" test -n "$client_ip"

    assigned_ip="$(landscape_api_dhcp_assigned_ip "$token" "$LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX" 2>/dev/null || true)"
    run_check "DHCP lease visible in router API" test "$assigned_ip" = "$client_ip"

    echo ""
    echo "---- LAN Connectivity ----"
    run_check "Router can ping client (${client_ip})" router_can_ping_client "$client_ip"

    write_client_diagnostics "$client_ip"
    landscape_router_dump_diagnostics "$token"

    echo ""
    echo "============================================================"
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
    echo "============================================================"

    set -e
    return $FAIL_COUNT
}

main() {
    echo ""
    echo "============================================================"
    echo "  Landscape Mini — End-to-End Dataplane Test"
    echo "============================================================"
    echo ""
    info "Image: ${IMAGE_PATH}"
    echo ""

    preflight

    local cirros_file
    cirros_file="$(download_cirros)" || exit 2

    if ! landscape_router_start_vm "${IMAGE_PATH}"; then
        exit 2
    fi

    setup_ssh

    if ! landscape_router_wait_ready "Router" "${SSH_TIMEOUT}"; then
        error "Router failed readiness contract; cannot run E2E"
        info "Router serial log:       ${LANDSCAPE_ROUTER_SERIAL_LOG}"
        info "Readiness snapshot:     ${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
        info "Service snapshot:       ${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
        info "Diagnostics snapshot:   ${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"
        info "Metadata snapshot:      ${LANDSCAPE_TEST_METADATA_FILE}"
        exit 1
    fi

    start_client "${cirros_file}" || exit 2

    local client_ip
    client_ip="$(wait_for_dhcp_assignment "${LANDSCAPE_ROUTER_API_TOKEN}")" || {
        error "Client did not receive DHCP; cannot complete E2E"
        info "Client serial log:      ${CLIENT_SERIAL_LOG}"
        info "Client diagnostics:     ${CLIENT_DIAGNOSTICS_FILE}"
        exit 1
    }

    echo ""
    run_e2e_checks "${LANDSCAPE_ROUTER_API_TOKEN}" "$client_ip" 2>&1 | tee "${CLIENT_RESULTS_FILE}"
    local rc=${PIPESTATUS[0]}

    echo ""
    if [[ $rc -eq 0 ]]; then
        ok "End-to-end dataplane checks passed"
    else
        error "${rc} end-to-end dataplane check(s) failed"
        rc=1
    fi
    info "Router serial log:       ${LANDSCAPE_ROUTER_SERIAL_LOG}"
    info "Client serial log:       ${CLIENT_SERIAL_LOG}"
    info "Results:                 ${CLIENT_RESULTS_FILE}"
    info "Readiness snapshot:      ${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
    info "Service snapshot:        ${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
    info "Router diagnostics:      ${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"
    info "Client diagnostics:      ${CLIENT_DIAGNOSTICS_FILE}"
    info "Metadata snapshot:       ${LANDSCAPE_TEST_METADATA_FILE}"
    echo ""

    exit $rc
}

main
