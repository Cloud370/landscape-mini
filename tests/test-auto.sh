#!/bin/bash
# =============================================================================
# Landscape Mini - Automated Test Runner
# =============================================================================
#
# Non-interactive test flow:
#   1. Copy image to temp file (protect build artifacts)
#   2. Start QEMU daemonized with serial log + pidfile
#   3. Wait for SSH to become available (120s timeout)
#   4. Run health checks via SSH
#   5. Report results
#   6. Cleanup QEMU process
#
# Supports both systemd (Debian) and OpenRC (Alpine) init systems.
#
# Usage:
#   ./tests/test-auto.sh [image-path]
#
# Exit codes:
#   0 - All checks passed
#   1 - One or more checks failed
#   2 - Infrastructure error (QEMU failed to start, SSH timeout, etc.)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Configuration ─────────────────────────────────────────────────────────────

IMAGE_PATH="${1:-${PROJECT_DIR}/output/landscape-mini-x86.img}"
SSH_PORT="${SSH_PORT:-2222}"
WEB_PORT="${WEB_PORT:-9800}"
LANDSCAPE_CONTROL_PORT="${LANDSCAPE_CONTROL_PORT:-6443}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="landscape"
SSH_TIMEOUT="${SSH_TIMEOUT:-120}"  # seconds to wait for SSH
SHUTDOWN_TIMEOUT=15   # seconds to wait for ACPI shutdown

EXPECTED_WAN_IFACE="eth0"
EXPECTED_LAN_IFACE="eth1"
EXPECTED_LAN_SUBNET_PREFIX="192.168.10."

LOG_DIR="${PROJECT_DIR}/output/test-logs"
SERIAL_LOG="${LOG_DIR}/serial-console.log"
RESULTS_FILE="${LOG_DIR}/test-results.txt"
PIDFILE=""
TEMP_IMAGE=""
QEMU_PID=""

# Init system: detected at runtime (systemd or openrc)
INIT_SYSTEM=""

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    set +e

    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        info "Shutting down QEMU (PID ${QEMU_PID})..."

        if [[ -n "${MONITOR_SOCK:-}" ]] && [[ -S "${MONITOR_SOCK}" ]]; then
            echo "system_powerdown" | socat -T2 STDIN UNIX-CONNECT:"${MONITOR_SOCK}" &>/dev/null || true
            local waited=0
            while kill -0 "${QEMU_PID}" 2>/dev/null && [[ $waited -lt $SHUTDOWN_TIMEOUT ]]; do
                sleep 1
                ((waited++))
            done
            if kill -0 "${QEMU_PID}" 2>/dev/null && [[ -S "${MONITOR_SOCK}" ]]; then
                echo "quit" | socat -T2 STDIN UNIX-CONNECT:"${MONITOR_SOCK}" &>/dev/null || true
                sleep 2
            fi
        fi

        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            warn "QEMU did not shut down gracefully, sending SIGKILL"
            kill -9 "${QEMU_PID}" 2>/dev/null || true
            wait "${QEMU_PID}" 2>/dev/null || true
        fi
    fi

    [[ -n "${TEMP_IMAGE}" ]] && rm -f "${TEMP_IMAGE}"
    [[ -n "${PIDFILE}" ]] && rm -f "${PIDFILE}"
    [[ -n "${MONITOR_SOCK:-}" ]] && rm -f "${MONITOR_SOCK}"

    exit $exit_code
}

trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────

preflight() {
    info "Preflight checks..."

    if [[ ! -f "${IMAGE_PATH}" ]]; then
        error "Image not found: ${IMAGE_PATH}"
        error "Run 'make build' first."
        exit 2
    fi

    if ! require_commands qemu-system-x86_64 sshpass curl socat jq; then
        error "Run 'make deps-test' to install test dependencies."
        exit 2
    fi

    if ! ensure_local_ports_free "${SSH_PORT}" "${WEB_PORT}"; then
        exit 2
    fi

    ok "Preflight passed"
}

# ── Start QEMU ────────────────────────────────────────────────────────────────

start_qemu() {
    info "Preparing disk image..."
    mkdir -p "${LOG_DIR}"

    TEMP_IMAGE=$(mktemp "${LOG_DIR}/test-image-XXXXXX.img")
    cp "${IMAGE_PATH}" "${TEMP_IMAGE}"

    PIDFILE=$(mktemp "${LOG_DIR}/qemu-pid-XXXXXX")
    MONITOR_SOCK=$(mktemp -u "${LOG_DIR}/qemu-monitor-XXXXXX.sock")

    local kvm_flag
    kvm_flag=$(detect_kvm)

    local ovmf=""
    ovmf=$(detect_ovmf_firmware || true)

    local bios_args=()
    if [[ -n "$ovmf" ]]; then
        bios_args=(-bios "$ovmf")
        info "UEFI firmware: ${ovmf}"
    else
        warn "OVMF not found, falling back to SeaBIOS (BIOS boot)"
    fi

    info "Starting QEMU (SSH=${SSH_PORT}, Web=${WEB_PORT})..."

    qemu-system-x86_64 \
        ${kvm_flag} \
        -m "${QEMU_MEM}" \
        -smp "${QEMU_SMP}" \
        "${bios_args[@]}" \
        -drive "file=${TEMP_IMAGE},format=raw,if=virtio" \
        -device virtio-net-pci,netdev=wan \
        -netdev "user,id=wan,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:${LANDSCAPE_CONTROL_PORT}" \
        -device virtio-net-pci,netdev=lan \
        -netdev user,id=lan \
        -display none \
        -serial "file:${SERIAL_LOG}" \
        -monitor "unix:${MONITOR_SOCK},server,nowait" \
        -pidfile "${PIDFILE}" \
        -daemonize

    if wait_pid=$(wait_for_pidfile "${PIDFILE}" "QEMU" 10); then
        QEMU_PID="$wait_pid"
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            ok "QEMU started (PID ${QEMU_PID})"
        else
            error "QEMU process exited immediately"
            dump_log_tail "${SERIAL_LOG}" "serial console"
            exit 2
        fi
    else
        error "QEMU failed to start (no pidfile)"
        exit 2
    fi
}

# ── Init System Detection ────────────────────────────────────────────────────

detect_init_system() {
    if guest_run "command -v systemctl" &>/dev/null; then
        INIT_SYSTEM="systemd"
    elif guest_run "command -v rc-service" &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi
    info "Detected init system: ${INIT_SYSTEM}"
}

# ── Service status helper (works with both systemd and OpenRC) ───────────────

check_service_active() {
    local svc="$1"
    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        guest_run "systemctl is-active ${svc}"
    elif [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        guest_run "rc-service ${svc} status" 2>/dev/null
    else
        return 1
    fi
}

check_no_failed_services() {
    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        local failed
        failed=$(guest_run "systemctl --failed --no-legend --no-pager" 2>/dev/null)
        test -z "$failed"
    elif [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        local crashed
        crashed=$(guest_run "rc-status --crashed 2>/dev/null | tail -n +2" 2>/dev/null)
        test -z "$crashed"
    else
        return 0
    fi
}

# ── API Functional Tests ──────────────────────────────────────────────────────

run_api_checks() {
    local token ifaces svc_status dhcp_conf snat_maps dns_ups resolv dns_result exported

    if ! detect_landscape_api_base; then
        run_skip "API tests" "Landscape API not ready"
        return 0
    fi

    token=$(landscape_api_login 2>/dev/null || true)
    run_check "API auth login" test -n "$token"
    if [[ -z "$token" ]]; then
        echo "       Skipping remaining API tests (no auth token)"
        return 0
    fi

    if ! run_check "API layout detection" detect_landscape_api_layout "$token"; then
        echo "       Skipping remaining API tests (unknown API layout)"
        return 0
    fi

    info "Waiting for core API services to stabilize..."
    if ! wait_for_landscape_service_active "$token" "ipconfigs" "$EXPECTED_WAN_IFACE" 30; then
        run_check "API service bootstrap: WAN IP config (${EXPECTED_WAN_IFACE})" false
    fi
    if ! wait_for_landscape_service_active "$token" "nat" "$EXPECTED_WAN_IFACE" 30; then
        run_check "API service bootstrap: NAT (${EXPECTED_WAN_IFACE})" false
    fi
    if ! wait_for_landscape_service_active "$token" "dhcp_v4" "$EXPECTED_LAN_IFACE" 30; then
        run_check "API service bootstrap: DHCPv4 (${EXPECTED_LAN_IFACE})" false
    fi
    if ! wait_for_landscape_service_active "$token" "route_wans" "$EXPECTED_WAN_IFACE" 30; then
        run_check "API service bootstrap: WAN routing (${EXPECTED_WAN_IFACE})" false
    fi
    if ! wait_for_landscape_service_active "$token" "route_lans" "$EXPECTED_LAN_IFACE" 30; then
        run_check "API service bootstrap: LAN routing (${EXPECTED_LAN_IFACE})" false
    fi

    info "Checking API interfaces..."
    ifaces=$(landscape_api_interfaces "$token" 2>/dev/null || true)
    run_check "API interfaces detected (eth0+eth1)" \
        contains_all_text "$ifaces" "$EXPECTED_WAN_IFACE" "$EXPECTED_LAN_IFACE"

    info "Checking API WAN IP config status..."
    run_check "API service: WAN IP config (${EXPECTED_WAN_IFACE})" \
        test "$(landscape_api_service_active "$token" "ipconfigs" "$EXPECTED_WAN_IFACE" 2>/dev/null || true)" = "yes"

    info "Checking API NAT status..."
    run_check "API service: NAT (${EXPECTED_WAN_IFACE})" \
        test "$(landscape_api_service_active "$token" "nat" "$EXPECTED_WAN_IFACE" 2>/dev/null || true)" = "yes"

    info "Checking API DHCPv4 status..."
    run_check "API service: DHCPv4 server (${EXPECTED_LAN_IFACE})" \
        test "$(landscape_api_service_active "$token" "dhcp_v4" "$EXPECTED_LAN_IFACE" 2>/dev/null || true)" = "yes"

    info "Checking API WAN routing status..."
    run_check "API service: WAN routing (${EXPECTED_WAN_IFACE})" \
        test "$(landscape_api_service_active "$token" "route_wans" "$EXPECTED_WAN_IFACE" 2>/dev/null || true)" = "yes"

    info "Checking API LAN routing status..."
    run_check "API service: LAN routing (${EXPECTED_LAN_IFACE})" \
        test "$(landscape_api_service_active "$token" "route_lans" "$EXPECTED_LAN_IFACE" 2>/dev/null || true)" = "yes"

    info "Checking API DHCPv4 config..."
    dhcp_conf=$(landscape_api_dhcp_config "$token" "$EXPECTED_LAN_IFACE" 2>/dev/null || true)
    run_check "API DHCPv4 subnet 192.168.10.0/24" \
        contains_text "$dhcp_conf" "${EXPECTED_LAN_SUBNET_PREFIX%?}"

    info "Checking API static NAT mappings..."
    snat_maps=$(landscape_api_static_nat_mappings "$token" 2>/dev/null || true)
    run_check "API static NAT mappings configured" \
        matches_regex_i "$snat_maps" 'SSH|SSH Access'

    info "Checking API DNS upstreams..."
    dns_ups=$(landscape_api_dns_upstreams "$token" 2>/dev/null || true)
    run_check "API DNS upstream configured" \
        matches_regex "$dns_ups" '"ips"'

    resolv=$(guest_run "cat /etc/resolv.conf" 2>/dev/null || true)
    run_check "DNS resolver points to localhost" \
        contains_text "$resolv" "127.0.0.1"

    dns_result=$(guest_run "nslookup www.baidu.com 2>/dev/null || host www.baidu.com 2>/dev/null" 2>/dev/null || true)
    if matches_regex_i "$dns_result" '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        run_check "DNS resolves www.baidu.com" true
    else
        run_skip "DNS resolves www.baidu.com" "resolution failed (no upstream connectivity?)"
    fi

    exported=$(landscape_api_config_export "$token" 2>/dev/null || true)
    run_check "API config export (TOML)" \
        matches_regex "$exported" '\[\[ifaces\]\]|\[\[ipconfigs\]\]|\[\[dhcpv4_services\]\]'
}

# ── Health Checks ─────────────────────────────────────────────────────────────

run_all_checks() {
    set +e

    echo "============================================================"
    echo "Landscape Mini — Health Checks"
    echo "============================================================"
    echo ""

    detect_init_system

    run_check "SSH reachable" guest_run "echo ok"

    local kver major minor
    kver=$(guest_run "uname -r" 2>/dev/null)
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)
    run_check "Kernel version >= 6.12 (got ${kver})" \
        test "$major" -gt 6 -o \( "$major" -eq 6 -a "$minor" -ge 12 \)

    local hname
    hname=$(guest_run "hostname" 2>/dev/null)
    run_check "Hostname = landscape (got ${hname})" \
        test "$hname" = "landscape"

    local lsblk_out has_ext4 has_vfat
    lsblk_out=$(guest_run "lsblk -f" 2>/dev/null)
    echo "$lsblk_out" | grep -q "ext4" && has_ext4=1 || has_ext4=0
    echo "$lsblk_out" | grep -q "vfat" && has_vfat=1 || has_vfat=0
    run_check "Disk layout has ext4 + vfat" \
        test "$has_ext4" -eq 1 -a "$has_vfat" -eq 1

    run_check "User root exists" guest_run "id root"
    run_check "User ld exists" guest_run "id ld"

    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        wait_for_guest_command "landscape-router service" 30 3 \
            guest_run "systemctl is-active --quiet landscape-router"
        run_check "landscape-router service active" \
            guest_run "systemctl is-active --quiet landscape-router"
    else
        wait_for_guest_command "landscape-router service" 30 3 \
            check_service_active "landscape-router"
        run_check "landscape-router service active" \
            check_service_active "landscape-router"
    fi
    run_check "Landscape binary exists and is executable" \
        guest_run "test -x /root/landscape-webserver"

    run_check "Web UI listening on port ${LANDSCAPE_CONTROL_PORT}" \
        detect_landscape_api_base

    local ip_fwd
    ip_fwd=$(guest_run "sysctl -n net.ipv4.ip_forward" 2>/dev/null)
    run_check "IP forwarding enabled (got ${ip_fwd})" \
        test "$ip_fwd" = "1"

    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        run_skip "sshd service running" "SSH reachability already verified on systemd guests"
    else
        wait_for_guest_command "sshd service" 30 3 \
            check_service_active "sshd"
        run_check "sshd service running" \
            check_service_active "sshd"
    fi

    run_check "No failed services" \
        check_no_failed_services

    run_check "bpftool available" \
        guest_run "command -v bpftool >/dev/null 2>&1 || test -x /usr/sbin/bpftool || test -x /usr/bin/bpftool"

    if guest_run "command -v docker >/dev/null 2>&1 || test -x /usr/bin/docker || test -x /usr/sbin/docker" &>/dev/null; then
        wait_for_guest_command "docker service" 45 3 \
            check_service_active "docker"
        run_check "Docker service active" \
            check_service_active "docker"
    else
        run_skip "Docker service active" "Docker not installed"
    fi

    echo ""
    echo "---- Landscape Router API Tests ----"
    run_api_checks

    echo ""
    echo "============================================================"
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
    echo "============================================================"

    set -e
    return $FAIL_COUNT
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "============================================================"
    echo "  Landscape Mini — Automated Test Runner"
    echo "============================================================"
    echo ""
    info "Image: ${IMAGE_PATH}"
    echo ""

    preflight
    start_qemu
    setup_ssh
    wait_for_guest_ssh "${QEMU_PID}" "${SERIAL_LOG}" "Guest" "${SSH_TIMEOUT}" || exit 2

    echo ""
    run_all_checks 2>&1 | tee "${RESULTS_FILE}"
    local rc=${PIPESTATUS[0]}

    echo ""
    if [[ $rc -eq 0 ]]; then
        ok "All checks passed!"
    else
        error "${rc} check(s) failed"
        rc=1
    fi
    info "Serial log:   ${SERIAL_LOG}"
    info "Test results: ${RESULTS_FILE}"
    echo ""

    exit $rc
}

main
