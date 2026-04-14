#!/bin/bash
# =============================================================================
# Landscape Mini - Smoke / Health Test
# =============================================================================
#
# Validates one thing only:
#   can the router image boot and satisfy the control-plane readiness contract?
#
# Ready means all of the following are true:
#   1. Guest SSH is reachable
#   2. https://localhost:6443 is reachable inside the guest
#   3. API login succeeds
#   4. API layout is detected
#   5. Expected interfaces are visible in the API
#   6. Core services are running on the expected interfaces
#
# This suite intentionally avoids brittle implementation-detail assertions.
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
LANDSCAPE_TEST_NAME="health"
LANDSCAPE_IMAGE_PATH="${IMAGE_PATH}"

resolve_default_landscape_version() {
    awk -F'"' '/^LANDSCAPE_VERSION=/{print $2; exit}' "${PROJECT_DIR}/build.env"
}

cleanup() {
    local exit_code=$?
    landscape_router_cleanup
    exit $exit_code
}

trap cleanup EXIT

docker_functional_check() {
    local init_system

    guest_run "command -v docker >/dev/null 2>&1"

    init_system="$(detect_guest_init_system)"
    case "$init_system" in
        systemd)
            wait_for_guest_command "docker service" 60 3 \
                guest_run "systemctl is-active --quiet docker"
            guest_run "systemctl is-active --quiet docker"
            ;;
        openrc)
            wait_for_guest_command "docker service" 60 3 \
                guest_run "rc-service docker status >/dev/null 2>&1"
            guest_run "rc-service docker status >/dev/null 2>&1"
            ;;
    esac

    guest_run "docker info >/dev/null 2>&1"
}

preflight() {
    info "Preflight checks..."

    ensure_image_exists "${IMAGE_PATH}" || {
        error "Run 'make build' first."
        exit 2
    }

    if ! require_commands qemu-system-x86_64 sshpass curl socat jq awk; then
        error "Run 'make deps-test' to install test dependencies."
        exit 2
    fi

    if ! ensure_local_ports_free "${SSH_PORT}" "${WEB_PORT}"; then
        exit 2
    fi

    load_landscape_topology || exit 2
    landscape_router_init_paths "health"

    LANDSCAPE_TEST_VARIANT="${LANDSCAPE_TEST_VARIANT:-$(landscape_guess_variant_from_image_path "${IMAGE_PATH}")}"
    LANDSCAPE_TEST_LANDSCAPE_VERSION="${LANDSCAPE_TEST_LANDSCAPE_VERSION:-$(resolve_default_landscape_version)}"
    landscape_write_test_metadata "${IMAGE_PATH}"

    ok "Preflight passed"
}

run_smoke_checks() {
    local token=""
    local ifaces=""
    local ip_forward=""
    local binding service_key iface

    reset_test_counters
    set +e

    echo "============================================================"
    echo "Landscape Mini — Smoke / Health Checks"
    echo "============================================================"
    echo ""

    run_check "SSH reachable" guest_run "echo ok"
    run_check "API listener ready" detect_landscape_api_base 10 1

    token="$(landscape_api_login 10 1 2>/dev/null || true)"
    run_check "API auth login" test -n "$token"

    if [[ -n "$token" ]]; then
        run_check "API layout detection" detect_landscape_api_layout "$token" 15

        ifaces="$(landscape_api_interfaces "$token" 2>/dev/null || true)"
        run_check "API interfaces detected (${LANDSCAPE_EXPECTED_WAN_IFACE}+${LANDSCAPE_EXPECTED_LAN_IFACE})" \
            contains_all_text "$ifaces" "$LANDSCAPE_EXPECTED_WAN_IFACE" "$LANDSCAPE_EXPECTED_LAN_IFACE"

        for binding in "${LANDSCAPE_ROUTER_CORE_SERVICE_BINDINGS[@]}"; do
            IFS=':' read -r service_key iface <<< "$binding"
            run_check "API service ${service_key} running on ${iface}" \
                test "$(landscape_api_service_active "$token" "$service_key" "$iface" 2>/dev/null || true)" = "yes"
        done

        landscape_router_dump_diagnostics "$token"
    else
        landscape_router_dump_diagnostics
    fi

    ip_forward="$(guest_run "cat /proc/sys/net/ipv4/ip_forward" 2>/dev/null || true)"
    run_check "IP forwarding enabled" test "$ip_forward" = "1"

    if landscape_variant_requires_docker; then
        run_check "Docker variant is functional" docker_functional_check
    else
        run_skip "Docker variant is functional" "Docker not expected for ${LANDSCAPE_TEST_VARIANT}"
    fi

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
    echo "  Landscape Mini — Smoke / Health Test"
    echo "============================================================"
    echo ""
    info "Image: ${IMAGE_PATH}"
    echo ""

    preflight

    if ! landscape_router_start_vm "${IMAGE_PATH}"; then
        exit 2
    fi

    setup_ssh

    if ! landscape_router_wait_ready "Router" "${SSH_TIMEOUT}"; then
        error "Router failed readiness contract"
        info "Router serial log:       ${LANDSCAPE_ROUTER_SERIAL_LOG}"
        info "Readiness snapshot:     ${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
        info "Service snapshot:       ${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
        info "Diagnostics snapshot:   ${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"
        info "Metadata snapshot:      ${LANDSCAPE_TEST_METADATA_FILE}"
        exit 1
    fi

    echo ""
    run_smoke_checks 2>&1 | tee "${LANDSCAPE_RESULTS_FILE}"
    local rc=${PIPESTATUS[0]}

    echo ""
    if [[ $rc -eq 0 ]]; then
        ok "Smoke / health checks passed"
    else
        error "${rc} smoke / health check(s) failed"
        rc=1
    fi
    info "Router serial log:       ${LANDSCAPE_ROUTER_SERIAL_LOG}"
    info "Results:                 ${LANDSCAPE_RESULTS_FILE}"
    info "Readiness snapshot:      ${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
    info "Service snapshot:        ${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
    info "Diagnostics snapshot:    ${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"
    info "Metadata snapshot:       ${LANDSCAPE_TEST_METADATA_FILE}"
    echo ""

    exit $rc
}

main
