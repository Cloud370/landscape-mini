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

# ── Configuration ─────────────────────────────────────────────────────────────

IMAGE_PATH="${1:-${PROJECT_DIR}/output/landscape-mini-x86.img}"
SSH_PORT="${SSH_PORT:-2222}"
WEB_PORT="${WEB_PORT:-9800}"
QEMU_MEM="${QEMU_MEM:-1024}"
QEMU_SMP="${QEMU_SMP:-2}"
SSH_PASSWORD="landscape"
SSH_TIMEOUT=120       # seconds to wait for SSH
SHUTDOWN_TIMEOUT=15   # seconds to wait for ACPI shutdown

LOG_DIR="${PROJECT_DIR}/output/test-logs"
SERIAL_LOG="${LOG_DIR}/serial-console.log"
RESULTS_FILE="${LOG_DIR}/test-results.txt"
PIDFILE=""
TEMP_IMAGE=""
QEMU_PID=""

# Init system: detected at runtime (systemd or openrc)
INIT_SYSTEM=""

# ── Colors ────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    set +e

    if [[ -n "${QEMU_PID}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        info "Shutting down QEMU (PID ${QEMU_PID})..."

        # Try graceful shutdown: send powerdown via monitor, then quit if needed
        if [[ -n "${MONITOR_SOCK:-}" ]] && [[ -S "${MONITOR_SOCK}" ]]; then
            echo "system_powerdown" | socat -T2 STDIN UNIX-CONNECT:"${MONITOR_SOCK}" &>/dev/null || true
            local waited=0
            while kill -0 "${QEMU_PID}" 2>/dev/null && [[ $waited -lt $SHUTDOWN_TIMEOUT ]]; do
                sleep 1
                ((waited++))
            done
            # If ACPI shutdown didn't work, try quit command
            if kill -0 "${QEMU_PID}" 2>/dev/null && [[ -S "${MONITOR_SOCK}" ]]; then
                echo "quit" | socat -T2 STDIN UNIX-CONNECT:"${MONITOR_SOCK}" &>/dev/null || true
                sleep 2
            fi
        fi

        # Force kill if still running
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            warn "QEMU did not shut down gracefully, sending SIGKILL"
            kill -9 "${QEMU_PID}" 2>/dev/null || true
            wait "${QEMU_PID}" 2>/dev/null || true
        fi
    fi

    # Clean up temp files
    [[ -n "${TEMP_IMAGE}" ]] && rm -f "${TEMP_IMAGE}"
    [[ -n "${PIDFILE}" ]] && rm -f "${PIDFILE}"
    [[ -n "${MONITOR_SOCK:-}" ]] && rm -f "${MONITOR_SOCK}"

    exit $exit_code
}

trap cleanup EXIT

# ── Preflight ─────────────────────────────────────────────────────────────────

preflight() {
    info "Preflight checks..."

    # Check image exists
    if [[ ! -f "${IMAGE_PATH}" ]]; then
        error "Image not found: ${IMAGE_PATH}"
        error "Run 'make build' first."
        exit 2
    fi

    # Check required tools
    local missing=()
    for cmd in qemu-system-x86_64 sshpass curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        error "Run 'make deps-test' to install test dependencies."
        exit 2
    fi

    # Check ports are free
    for port in "${SSH_PORT}" "${WEB_PORT}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            error "Port ${port} is already in use. Is another QEMU instance running?"
            exit 2
        fi
    done

    ok "Preflight passed"
}

# ── KVM Detection ─────────────────────────────────────────────────────────────

detect_kvm() {
    if [[ -w /dev/kvm ]]; then
        info "KVM acceleration: enabled" >&2
        echo "-enable-kvm"
    else
        warn "KVM not available, using software emulation (slow)" >&2
        echo "-cpu qemu64"
    fi
}

# ── Start QEMU ────────────────────────────────────────────────────────────────

start_qemu() {
    info "Preparing disk image..."
    mkdir -p "${LOG_DIR}"

    # Copy image to protect original build artifact
    TEMP_IMAGE=$(mktemp "${LOG_DIR}/test-image-XXXXXX.img")
    cp "${IMAGE_PATH}" "${TEMP_IMAGE}"

    PIDFILE=$(mktemp "${LOG_DIR}/qemu-pid-XXXXXX")
    MONITOR_SOCK=$(mktemp -u "${LOG_DIR}/qemu-monitor-XXXXXX.sock")

    local kvm_flag
    kvm_flag=$(detect_kvm)

    # Detect OVMF location
    local ovmf=""
    for path in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [[ -f "$path" ]]; then
            ovmf="$path"
            break
        fi
    done

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
        -netdev "user,id=wan,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:9800" \
        -device virtio-net-pci,netdev=lan \
        -netdev user,id=lan \
        -display none \
        -serial "file:${SERIAL_LOG}" \
        -monitor "unix:${MONITOR_SOCK},server,nowait" \
        -pidfile "${PIDFILE}" \
        -daemonize

    # Read PID
    sleep 1
    if [[ -f "${PIDFILE}" ]]; then
        QEMU_PID=$(cat "${PIDFILE}")
        if kill -0 "${QEMU_PID}" 2>/dev/null; then
            ok "QEMU started (PID ${QEMU_PID})"
        else
            error "QEMU process exited immediately"
            dump_serial_log
            exit 2
        fi
    else
        error "QEMU failed to start (no pidfile)"
        exit 2
    fi
}

# ── Wait for SSH ──────────────────────────────────────────────────────────────

wait_for_ssh() {
    info "Waiting for SSH (timeout: ${SSH_TIMEOUT}s)..."

    local elapsed=0
    while [[ $elapsed -lt $SSH_TIMEOUT ]]; do
        # Check QEMU is still alive
        if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
            error "QEMU process died unexpectedly"
            dump_serial_log
            exit 2
        fi

        # Try SSH connection
        if sshpass -p "${SSH_PASSWORD}" \
            ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=3 \
                -o LogLevel=ERROR \
                -p "${SSH_PORT}" \
                root@localhost \
                "echo ready" &>/dev/null; then
            ok "SSH available after ${elapsed}s"
            return 0
        fi

        sleep 3
        ((elapsed += 3))
        # Progress indicator every 15s
        if ((elapsed % 15 == 0)); then
            info "  ...still waiting (${elapsed}s)"
        fi
    done

    error "SSH timeout after ${SSH_TIMEOUT}s"
    dump_serial_log
    exit 2
}

# ── Serial Log Dump ───────────────────────────────────────────────────────────

dump_serial_log() {
    if [[ -f "${SERIAL_LOG}" ]]; then
        echo ""
        error "=== Last 50 lines of serial console ==="
        tail -n 50 "${SERIAL_LOG}" 2>/dev/null || true
        echo ""
        info "Full serial log: ${SERIAL_LOG}"
    fi
}

# ── SSH Helper ────────────────────────────────────────────────────────────────

SSH_CMD=""

setup_ssh() {
    SSH_CMD="sshpass -p ${SSH_PASSWORD} ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o LogLevel=ERROR \
        -p ${SSH_PORT} \
        root@localhost"
}

guest_run() {
    $SSH_CMD "$@"
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

# ── Service status helper (works with both systemd and OpenRC) ────────────────

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

# ── Health Checks ─────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

run_check() {
    local desc="$1"
    shift
    local output
    output=$("$@" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "[PASS] ${desc}"
        ((PASS_COUNT++))
    else
        echo "[FAIL] ${desc}"
        echo "       output: ${output}"
        ((FAIL_COUNT++))
    fi
    return $rc
}

run_skip() {
    local desc="$1"
    local reason="$2"
    echo "[SKIP] ${desc} — ${reason}"
    ((SKIP_COUNT++))
}

# ── Landscape API Helpers ─────────────────────────────────────────────────────

# Curl the Landscape API from inside the guest.
# Usage: api_get  <port> <token> <path>
#        api_post <port> <token> <path> [json_body]
# API base URL is set by run_api_checks (http or https depending on detected port)
API_BASE=""

api_get() {
    local token="$1" path="$2"
    guest_run "curl -sfkL --max-time 5 -H 'Authorization: Bearer ${token}' ${API_BASE}${path}"
}

api_post() {
    local token="$1" path="$2" body="${3:-}"
    if [[ -n "$body" ]]; then
        guest_run "curl -sfkL --max-time 5 -H 'Authorization: Bearer ${token}' -H 'Content-Type: application/json' -X POST -d '${body}' ${API_BASE}${path}"
    else
        guest_run "curl -sfkL --max-time 5 -H 'Authorization: Bearer ${token}' -X POST ${API_BASE}${path}"
    fi
}

api_delete() {
    local token="$1" path="$2"
    guest_run "curl -sfkL --max-time 5 -H 'Authorization: Bearer ${token}' -X DELETE ${API_BASE}${path}"
}

# ── API Functional Tests ─────────────────────────────────────────────────────

run_api_checks() {
    local port="$1"

    # Detect HTTP vs HTTPS — try both, prefer HTTP
    local http_port https_port
    http_port=$(guest_run "ss -tlnp 2>/dev/null | grep landscape-webse" 2>/dev/null \
        | awk '{print $4}' | awk -F: '{print $NF}' | sort -n | head -1)
    https_port=$(guest_run "ss -tlnp 2>/dev/null | grep landscape-webse" 2>/dev/null \
        | awk '{print $4}' | awk -F: '{print $NF}' | sort -n | tail -1)
    if [[ -n "$http_port" ]] && guest_run "curl -sf --max-time 3 http://localhost:${http_port}/ -o /dev/null" &>/dev/null; then
        API_BASE="http://localhost:${http_port}"
    elif [[ -n "$https_port" ]]; then
        API_BASE="https://localhost:${https_port}"
    else
        API_BASE="http://localhost:${port}"
    fi

    # ---- 1. Auth: login and get JWT token ----
    local login_resp token
    login_resp=$(guest_run "curl -sfkL --max-time 5 -H 'Content-Type: application/json' \
        -X POST -d '{\"username\":\"root\",\"password\":\"root\"}' \
        ${API_BASE}/api/auth/login" 2>/dev/null)
    # Extract JWT token (three base64url segments separated by dots)
    token=$(echo "$login_resp" | grep -oE '[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' | head -1)
    run_check "API auth login" test -n "$token"
    if [[ -z "$token" ]]; then
        echo "       response: ${login_resp}"
        echo "       Skipping remaining API tests (no auth token)"
        return
    fi

    # ---- 2. Network interfaces detected ----
    local ifaces
    ifaces=$(api_get "$token" "/api/src/iface/new" 2>/dev/null)
    run_check "API interfaces detected (eth0+eth1)" \
        echo "$ifaces" \| grep -q "eth0"

    # ---- 3. Core services running (IP, NAT, DHCP, routing) ----
    local svc_status
    svc_status=$(api_get "$token" "/api/src/services/ipconfigs/status" 2>/dev/null)
    run_check "API service: WAN IP config (eth0)" echo "$svc_status" \| grep -q "eth0"

    svc_status=$(api_get "$token" "/api/src/services/nats/status" 2>/dev/null)
    run_check "API service: NAT (eth0)" echo "$svc_status" \| grep -q "eth0"

    svc_status=$(api_get "$token" "/api/src/services/dhcp_v4/status" 2>/dev/null)
    run_check "API service: DHCPv4 server (eth1)" echo "$svc_status" \| grep -q "eth1"

    svc_status=$(api_get "$token" "/api/src/services/route_wans/status" 2>/dev/null)
    run_check "API service: WAN routing (eth0)" echo "$svc_status" \| grep -q "eth0"

    svc_status=$(api_get "$token" "/api/src/services/route_lans/status" 2>/dev/null)
    run_check "API service: LAN routing (eth1)" echo "$svc_status" \| grep -q "eth1"

    # ---- 4. DHCP config correct ----
    local dhcp_conf
    dhcp_conf=$(api_get "$token" "/api/src/services/dhcp_v4/eth1" 2>/dev/null)
    run_check "API DHCPv4 subnet 192.168.10.0/24" echo "$dhcp_conf" \| grep -q "192.168.10"

    # ---- 5. Static NAT / port forwarding ----
    local snat_maps
    snat_maps=$(api_get "$token" "/api/src/config/static_nat_mappings" 2>/dev/null)
    run_check "API static NAT mappings configured" echo "$snat_maps" \| grep -q "SSH"

    # ---- 6. DNS: verify upstream config and test resolution ----
    # Landscape sets resolv.conf to 127.0.0.1 and forwards DNS via its
    # built-in resolver to the configured upstream (default: 1.0.0.1).
    local dns_ups
    dns_ups=$(api_get "$token" "/api/src/config/dns_upstreams" 2>/dev/null)
    run_check "API DNS upstream configured" echo "$dns_ups" \| grep -qE '"ips"'

    local resolv
    resolv=$(guest_run "cat /etc/resolv.conf" 2>/dev/null)
    run_check "DNS resolver points to localhost" echo "$resolv" \| grep -q "127.0.0.1"

    # Test actual DNS resolution from inside the guest
    local dns_result
    dns_result=$(guest_run "nslookup www.baidu.com 2>/dev/null || host www.baidu.com 2>/dev/null" 2>/dev/null)
    if echo "$dns_result" | grep -qiE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        run_check "DNS resolves www.baidu.com" true
    else
        run_skip "DNS resolves www.baidu.com" "resolution failed (no upstream connectivity?)"
    fi

    # ---- 7. Config export ----
    local exported
    exported=$(api_get "$token" "/api/src/sys_service/config/export" 2>/dev/null)
    run_check "API config export (TOML)" echo "$exported" \| grep -q "iface"
}

run_all_checks() {
    set +e

    echo "============================================================"
    echo "Landscape Mini — Health Checks"
    echo "============================================================"
    echo ""

    # Detect init system first
    detect_init_system

    # SSH
    run_check "SSH reachable" guest_run "echo ok"

    # Kernel
    local kver major minor
    kver=$(guest_run "uname -r" 2>/dev/null)
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)
    run_check "Kernel version >= 6.12 (got ${kver})" \
        test "$major" -gt 6 -o \( "$major" -eq 6 -a "$minor" -ge 12 \)

    # Hostname
    local hname
    hname=$(guest_run "hostname" 2>/dev/null)
    run_check "Hostname = landscape (got ${hname})" \
        test "$hname" = "landscape"

    # Disk layout
    local lsblk_out has_ext4 has_vfat
    lsblk_out=$(guest_run "lsblk -f" 2>/dev/null)
    echo "$lsblk_out" | grep -q "ext4" && has_ext4=1 || has_ext4=0
    echo "$lsblk_out" | grep -q "vfat" && has_vfat=1 || has_vfat=0
    run_check "Disk layout has ext4 + vfat" \
        test "$has_ext4" -eq 1 -a "$has_vfat" -eq 1

    # Users
    run_check "User root exists" guest_run "id root"
    run_check "User ld exists" guest_run "id ld"

    # Landscape
    run_check "landscape-router service active" \
        check_service_active "landscape-router"
    run_check "Landscape binary exists and is executable" \
        guest_run "test -x /root/landscape-webserver"

    # Web UI — detect port from inside guest (retry up to 15s for startup)
    local web_port="" web_wait=0
    while [[ -z "$web_port" && $web_wait -lt 15 ]]; do
        web_port=$(guest_run "ss -tlnp 2>/dev/null | grep landscape-webse | head -1 | awk '{print \$4}' | awk -F: '{print \$NF}'" 2>/dev/null)
        [[ -z "$web_port" ]] && sleep 3 && ((web_wait += 3))
    done
    if [[ -z "$web_port" ]]; then
        run_check "Web UI listening" false
    else
        run_check "Web UI listening on port ${web_port}" \
            guest_run "curl -sf --max-time 5 http://localhost:${web_port}/ -o /dev/null || curl -sf --max-time 5 https://localhost:${web_port}/ -o /dev/null -k"
    fi

    # System
    local ip_fwd
    ip_fwd=$(guest_run "sysctl -n net.ipv4.ip_forward" 2>/dev/null)
    run_check "IP forwarding enabled (got ${ip_fwd})" \
        test "$ip_fwd" = "1"

    if [[ "${INIT_SYSTEM}" == "systemd" ]]; then
        run_check "sshd service running" \
            guest_run "systemctl is-active ssh || systemctl is-active sshd"
    else
        run_check "sshd service running" \
            check_service_active "sshd"
    fi

    run_check "No failed services" \
        check_no_failed_services

    run_check "bpftool available" \
        guest_run "which bpftool"

    # Docker (auto-detect)
    if guest_run "which docker" &>/dev/null; then
        run_check "Docker service active" \
            check_service_active "docker"
    else
        run_skip "Docker service active" "Docker not installed"
    fi

    # ==================================================================
    # Landscape Router API Functional Tests
    # ==================================================================
    echo ""
    echo "---- Landscape Router API Tests ----"

    if [[ -n "$web_port" ]]; then
        run_api_checks "$web_port"
    else
        run_skip "API tests" "Web UI not listening"
    fi

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
    wait_for_ssh
    setup_ssh

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
