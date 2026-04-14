#!/bin/bash

if [[ -n "${LANDSCAPE_TEST_COMMON_SOURCED:-}" ]]; then
    return 0
fi
LANDSCAPE_TEST_COMMON_SOURCED=1

# ── Colors / Logging ──────────────────────────────────────────────────────────

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

# ── Result Helpers ────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAIL_FAST="${FAIL_FAST:-0}"
LANDSCAPE_TEST_HTTP_TIMEOUT="${LANDSCAPE_TEST_HTTP_TIMEOUT:-10}"
LANDSCAPE_API_READY_TIMEOUT="${LANDSCAPE_API_READY_TIMEOUT:-45}"
LANDSCAPE_API_READY_INTERVAL="${LANDSCAPE_API_READY_INTERVAL:-3}"
LANDSCAPE_ROUTER_READY_TIMEOUT="${LANDSCAPE_ROUTER_READY_TIMEOUT:-90}"
LANDSCAPE_TEST_LOG_DIR="${LANDSCAPE_TEST_LOG_DIR:-${PROJECT_DIR:-$(pwd)}/output/test-logs}"
LANDSCAPE_INIT_CONFIG="${LANDSCAPE_INIT_CONFIG:-${PROJECT_DIR:-$(pwd)}/configs/landscape_init.toml}"

declare -a LANDSCAPE_ROUTER_CORE_SERVICE_BINDINGS=()

reset_test_counters() {
    PASS_COUNT=0
    FAIL_COUNT=0
    SKIP_COUNT=0
}

run_check() {
    local desc="$1"
    shift
    local output rc

    if output=$("$@" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        echo "[PASS] ${desc}"
        ((PASS_COUNT++))
    else
        echo "[FAIL] ${desc}"
        if [[ -n "$output" ]]; then
            echo "       output: ${output}"
        fi
        ((FAIL_COUNT++))
        if [[ "${FAIL_FAST}" == "1" ]]; then
            exit $rc
        fi
    fi

    return $rc
}

run_skip() {
    local desc="$1"
    local reason="$2"
    echo "[SKIP] ${desc} — ${reason}"
    ((SKIP_COUNT++))
}

contains_text() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]]
}

contains_all_text() {
    local haystack="$1"
    shift
    local needle
    for needle in "$@"; do
        [[ "$haystack" == *"$needle"* ]] || return 1
    done
}

matches_regex() {
    local haystack="$1"
    local regex="$2"
    printf '%s\n' "$haystack" | grep -qE "$regex"
}

matches_regex_i() {
    local haystack="$1"
    local regex="$2"
    printf '%s\n' "$haystack" | grep -qiE "$regex"
}

# ── Generic Test Helpers ──────────────────────────────────────────────────────

require_commands() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        return 1
    fi
}

ensure_image_exists() {
    local image_path="$1"
    if [[ ! -f "$image_path" ]]; then
        error "Image not found: ${image_path}"
        return 1
    fi
}

ensure_local_ports_free() {
    local port
    for port in "$@"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            error "Port ${port} is already in use. Is another QEMU instance running?"
            return 1
        fi
    done
}

detect_kvm() {
    if [[ -w /dev/kvm ]]; then
        info "KVM acceleration: enabled" >&2
        echo "-enable-kvm"
    else
        warn "KVM not available, using software emulation (slow)" >&2
        echo "-cpu qemu64"
    fi
}

detect_ovmf_firmware() {
    local path
    for path in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

wait_for_pidfile() {
    local pidfile="$1"
    local label="$2"
    local timeout="${3:-10}"
    local elapsed=0
    local pid=""

    while [[ $elapsed -lt $timeout ]]; do
        if [[ -s "${pidfile}" ]]; then
            pid=$(cat "${pidfile}" 2>/dev/null || true)
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                echo "$pid"
                return 0
            fi
        fi
        sleep 1
        ((elapsed++))
    done

    error "${label} failed to write pidfile after ${timeout}s"
    return 1
}

dump_log_tail() {
    local logfile="$1"
    local label="${2:-$1}"
    if [[ -f "${logfile}" ]]; then
        echo ""
        error "=== Last 50 lines of ${label} ==="
        tail -n 50 "${logfile}" 2>/dev/null || true
        echo ""
    fi
}

# ── SSH Helpers ───────────────────────────────────────────────────────────────

SSH_ARGS=()
LANDSCAPE_TEST_REMOTE_TIMEOUT="${LANDSCAPE_TEST_REMOTE_TIMEOUT:-15}"

setup_ssh() {
    local user="${SSH_USER:-root}"
    local host="${SSH_HOST:-localhost}"
    SSH_ARGS=(
        timeout --foreground "${LANDSCAPE_TEST_REMOTE_TIMEOUT}"
        sshpass -p "${SSH_PASSWORD}" ssh
        -n
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=10
        -o LogLevel=ERROR
        -p "${SSH_PORT}"
        "${user}@${host}"
    )
}

guest_run() {
    if [[ ${#SSH_ARGS[@]} -eq 0 ]]; then
        error "SSH helper not initialized; call setup_ssh first" >&2
        return 1
    fi
    "${SSH_ARGS[@]}" "$@"
}

wait_for_guest_ssh() {
    local pid="$1"
    local serial_log="$2"
    local label="$3"
    local timeout="${4:-${SSH_TIMEOUT:-60}}"

    info "Waiting for ${label} SSH (timeout: ${timeout}s)..."

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            error "${label} VM died unexpectedly"
            dump_log_tail "${serial_log}" "${label} serial log"
            return 1
        fi

        if guest_run "echo ready" &>/dev/null; then
            ok "SSH available after ${elapsed}s"
            return 0
        fi

        sleep 3
        ((elapsed += 3))
        if ((elapsed % 15 == 0)); then
            info "  ...still waiting (${elapsed}s)"
        fi
    done

    error "SSH timeout after ${timeout}s"
    dump_log_tail "${serial_log}" "${label} serial log"
    return 1
}

wait_for_guest_command() {
    local desc="$1"
    local timeout="$2"
    local interval="$3"
    shift 3

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if "$@" &>/dev/null; then
            return 0
        fi
        sleep "${interval}"
        ((elapsed += interval))
        if ((elapsed < timeout)) && ((elapsed % 15 == 0)); then
            info "  ...waiting for ${desc} (${elapsed}s)" >&2
        fi
    done

    return 1
}

# ── Topology Expectations ─────────────────────────────────────────────────────

LANDSCAPE_EXPECTED_WAN_IFACE=""
LANDSCAPE_EXPECTED_LAN_IFACE=""
LANDSCAPE_EXPECTED_LAN_GATEWAY=""
LANDSCAPE_EXPECTED_LAN_NETMASK=""
LANDSCAPE_EXPECTED_LAN_RANGE_START=""
LANDSCAPE_EXPECTED_LAN_RANGE_END=""
LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX=""

_landscape_toml_iface_name_by_zone() {
    local zone="$1"
    awk -v zone="$zone" '
        /^\[\[ifaces\]\]/ {
            if (!printed && in_block && current_zone == zone && current_name != "") {
                print current_name
                printed = 1
                exit
            }
            in_block = 1
            current_name = ""
            current_zone = ""
            next
        }
        /^\[\[/ || /^\[/ {
            if (!printed && in_block && current_zone == zone && current_name != "") {
                print current_name
                printed = 1
                exit
            }
            in_block = 0
        }
        in_block && /^[[:space:]]*name[[:space:]]*=/ {
            line = $0
            sub(/^[^=]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            current_name = line
        }
        in_block && /^[[:space:]]*zone_type[[:space:]]*=/ {
            line = $0
            sub(/^[^=]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            current_zone = line
        }
        END {
            if (!printed && in_block && current_zone == zone && current_name != "") {
                print current_name
            }
        }
    ' "${LANDSCAPE_INIT_CONFIG}"
}

_landscape_toml_section_value() {
    local section="$1"
    local key="$2"
    awk -v section="[$section]" -v key="$key" '
        /^\[/ {
            in_section = ($0 == section)
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            line = $0
            sub(/^[^=]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^"/, "", line)
            gsub(/"$/, "", line)
            print line
            exit
        }
    ' "${LANDSCAPE_INIT_CONFIG}"
}

load_landscape_topology() {
    if [[ ! -f "${LANDSCAPE_INIT_CONFIG}" ]]; then
        error "Topology config not found: ${LANDSCAPE_INIT_CONFIG}"
        return 1
    fi

    LANDSCAPE_EXPECTED_WAN_IFACE="$(_landscape_toml_iface_name_by_zone wan)"
    LANDSCAPE_EXPECTED_LAN_IFACE="$(_landscape_toml_iface_name_by_zone lan)"
    LANDSCAPE_EXPECTED_LAN_GATEWAY="$(_landscape_toml_section_value dhcpv4_services.config server_ip_addr)"
    LANDSCAPE_EXPECTED_LAN_NETMASK="$(_landscape_toml_section_value dhcpv4_services.config network_mask)"
    LANDSCAPE_EXPECTED_LAN_RANGE_START="$(_landscape_toml_section_value dhcpv4_services.config ip_range_start)"
    LANDSCAPE_EXPECTED_LAN_RANGE_END="$(_landscape_toml_section_value dhcpv4_services.config ip_range_end)"

    if [[ -n "${LANDSCAPE_EXPECTED_LAN_RANGE_START}" ]]; then
        LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX="${LANDSCAPE_EXPECTED_LAN_RANGE_START%.*}."
    elif [[ -n "${LANDSCAPE_EXPECTED_LAN_GATEWAY}" ]]; then
        LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX="${LANDSCAPE_EXPECTED_LAN_GATEWAY%.*}."
    else
        LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX=""
    fi

    if [[ -z "${LANDSCAPE_EXPECTED_WAN_IFACE}" || -z "${LANDSCAPE_EXPECTED_LAN_IFACE}" || -z "${LANDSCAPE_EXPECTED_LAN_GATEWAY}" ]]; then
        error "Failed to load expected topology from ${LANDSCAPE_INIT_CONFIG}"
        return 1
    fi

    LANDSCAPE_ROUTER_CORE_SERVICE_BINDINGS=(
        "ipconfigs:${LANDSCAPE_EXPECTED_WAN_IFACE}"
        "nat:${LANDSCAPE_EXPECTED_WAN_IFACE}"
        "route_wans:${LANDSCAPE_EXPECTED_WAN_IFACE}"
        "dhcp_v4:${LANDSCAPE_EXPECTED_LAN_IFACE}"
        "route_lans:${LANDSCAPE_EXPECTED_LAN_IFACE}"
    )
}

landscape_guess_variant_from_image_path() {
    local image_path="$1"
    local base
    base="$(basename "$image_path")"

    case "$base" in
        *alpine-docker*.img)
            echo "alpine-docker"
            ;;
        *alpine*.img)
            echo "alpine"
            ;;
        *docker*.img)
            echo "docker"
            ;;
        *)
            echo "default"
            ;;
    esac
}

landscape_variant_requires_docker() {
    local variant="${LANDSCAPE_TEST_VARIANT:-${LANDSCAPE_IMAGE_PATH:+$(landscape_guess_variant_from_image_path "${LANDSCAPE_IMAGE_PATH}")}}"
    [[ "$variant" == *docker* ]]
}

# ── Router Harness / Diagnostics ──────────────────────────────────────────────

LANDSCAPE_ROUTER_PID=""
LANDSCAPE_ROUTER_PIDFILE=""
LANDSCAPE_ROUTER_MONITOR=""
LANDSCAPE_ROUTER_TEMP_IMAGE=""
LANDSCAPE_ROUTER_SERIAL_LOG=""
LANDSCAPE_RESULTS_FILE=""
LANDSCAPE_READINESS_SNAPSHOT_FILE=""
LANDSCAPE_SERVICE_SNAPSHOT_FILE=""
LANDSCAPE_ROUTER_DIAGNOSTICS_FILE=""
LANDSCAPE_TEST_METADATA_FILE=""
LANDSCAPE_ROUTER_API_TOKEN=""
LANDSCAPE_TEST_NAME="${LANDSCAPE_TEST_NAME:-test}"

landscape_router_init_paths() {
    local prefix="$1"

    mkdir -p "${LANDSCAPE_TEST_LOG_DIR}"

    LANDSCAPE_ROUTER_SERIAL_LOG="${LANDSCAPE_TEST_LOG_DIR}/${prefix}-serial-router.log"
    LANDSCAPE_RESULTS_FILE="${LANDSCAPE_TEST_LOG_DIR}/${prefix}-results.txt"
    LANDSCAPE_READINESS_SNAPSHOT_FILE="${LANDSCAPE_TEST_LOG_DIR}/${prefix}-readiness.txt"
    LANDSCAPE_SERVICE_SNAPSHOT_FILE="${LANDSCAPE_TEST_LOG_DIR}/${prefix}-services.json"
    LANDSCAPE_ROUTER_DIAGNOSTICS_FILE="${LANDSCAPE_TEST_LOG_DIR}/${prefix}-diagnostics.txt"
    LANDSCAPE_TEST_METADATA_FILE="${LANDSCAPE_TEST_LOG_DIR}/${prefix}-metadata.txt"

    rm -f \
        "${LANDSCAPE_ROUTER_SERIAL_LOG}" \
        "${LANDSCAPE_RESULTS_FILE}" \
        "${LANDSCAPE_READINESS_SNAPSHOT_FILE}" \
        "${LANDSCAPE_SERVICE_SNAPSHOT_FILE}" \
        "${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}" \
        "${LANDSCAPE_TEST_METADATA_FILE}"
}

landscape_write_test_metadata() {
    local image_path="${1:-${LANDSCAPE_IMAGE_PATH:-}}"
    local image_base=""

    if [[ -n "$image_path" ]]; then
        image_base="$(basename "$image_path")"
    fi

    LANDSCAPE_TEST_VARIANT="${LANDSCAPE_TEST_VARIANT:-$(landscape_guess_variant_from_image_path "$image_path")}"
    LANDSCAPE_TEST_ARTIFACT_ID="${LANDSCAPE_TEST_ARTIFACT_ID:-${image_base:-unknown-image}}"
    LANDSCAPE_TEST_LANDSCAPE_VERSION="${LANDSCAPE_TEST_LANDSCAPE_VERSION:-unknown}"
    LANDSCAPE_TEST_GIT_SHA="${LANDSCAPE_TEST_GIT_SHA:-${GITHUB_SHA:-unknown}}"
    LANDSCAPE_TEST_RUN_ID="${LANDSCAPE_TEST_RUN_ID:-${GITHUB_RUN_ID:-local}}"

    cat > "${LANDSCAPE_TEST_METADATA_FILE}" <<EOF
name=${LANDSCAPE_TEST_NAME}
image_path=${image_path}
image_basename=${image_base}
variant=${LANDSCAPE_TEST_VARIANT}
artifact_id=${LANDSCAPE_TEST_ARTIFACT_ID}
landscape_version=${LANDSCAPE_TEST_LANDSCAPE_VERSION}
git_sha=${LANDSCAPE_TEST_GIT_SHA}
run_id=${LANDSCAPE_TEST_RUN_ID}
expected_wan_iface=${LANDSCAPE_EXPECTED_WAN_IFACE}
expected_lan_iface=${LANDSCAPE_EXPECTED_LAN_IFACE}
expected_lan_gateway=${LANDSCAPE_EXPECTED_LAN_GATEWAY}
expected_lan_range_start=${LANDSCAPE_EXPECTED_LAN_RANGE_START}
expected_lan_range_end=${LANDSCAPE_EXPECTED_LAN_RANGE_END}
expected_lan_netmask=${LANDSCAPE_EXPECTED_LAN_NETMASK}
expected_lan_subnet_prefix=${LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX}
timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

landscape_router_start_vm() {
    local image_path="$1"
    local wan_netdev="${ROUTER_WAN_NETDEV:-user,id=wan,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${WEB_PORT}-:${LANDSCAPE_CONTROL_PORT}}"
    local lan_netdev="${ROUTER_LAN_NETDEV:-user,id=lan}"
    local wan_device_opts="${ROUTER_WAN_DEVICE_OPTS:-}"
    local lan_device_opts="${ROUTER_LAN_DEVICE_OPTS:-}"
    local qemu_mem="${QEMU_MEM:-1024}"
    local qemu_smp="${QEMU_SMP:-2}"
    local qemu_label="${ROUTER_LABEL:-Router}"

    mkdir -p "${LANDSCAPE_TEST_LOG_DIR}"

    LANDSCAPE_ROUTER_TEMP_IMAGE=$(mktemp "${LANDSCAPE_TEST_LOG_DIR}/${LANDSCAPE_TEST_NAME}-router-XXXXXX.img")
    cp "${image_path}" "${LANDSCAPE_ROUTER_TEMP_IMAGE}"

    LANDSCAPE_ROUTER_PIDFILE=$(mktemp "${LANDSCAPE_TEST_LOG_DIR}/${LANDSCAPE_TEST_NAME}-router-pid-XXXXXX")
    LANDSCAPE_ROUTER_MONITOR=$(mktemp -u "${LANDSCAPE_TEST_LOG_DIR}/${LANDSCAPE_TEST_NAME}-router-monitor-XXXXXX.sock")

    local kvm_args=()
    read -r -a kvm_args <<< "$(detect_kvm)"

    local ovmf=""
    local bios_args=()
    ovmf=$(detect_ovmf_firmware || true)
    if [[ -n "$ovmf" ]]; then
        bios_args=(-bios "$ovmf")
        info "UEFI firmware: ${ovmf}"
    else
        warn "OVMF not found, falling back to SeaBIOS"
    fi

    info "Starting ${qemu_label} VM (SSH=${SSH_PORT}, Web=${WEB_PORT})..."

    qemu-system-x86_64 \
        "${kvm_args[@]}" \
        -m "${qemu_mem}" \
        -smp "${qemu_smp}" \
        "${bios_args[@]}" \
        -drive "file=${LANDSCAPE_ROUTER_TEMP_IMAGE},format=raw,if=virtio" \
        -device "virtio-net-pci,netdev=wan${wan_device_opts}" \
        -netdev "${wan_netdev}" \
        -device "virtio-net-pci,netdev=lan${lan_device_opts}" \
        -netdev "${lan_netdev}" \
        -display none \
        -serial "file:${LANDSCAPE_ROUTER_SERIAL_LOG}" \
        -monitor "unix:${LANDSCAPE_ROUTER_MONITOR},server,nowait" \
        -pidfile "${LANDSCAPE_ROUTER_PIDFILE}" \
        -daemonize

    if LANDSCAPE_ROUTER_PID=$(wait_for_pidfile "${LANDSCAPE_ROUTER_PIDFILE}" "${qemu_label} VM" 10); then
        if kill -0 "${LANDSCAPE_ROUTER_PID}" 2>/dev/null; then
            ok "${qemu_label} VM started (PID ${LANDSCAPE_ROUTER_PID})"
            return 0
        fi
    fi

    error "${qemu_label} VM exited immediately"
    dump_log_tail "${LANDSCAPE_ROUTER_SERIAL_LOG}" "${qemu_label} serial log"
    return 1
}

landscape_router_stop_vm() {
    local shutdown_timeout="${SHUTDOWN_TIMEOUT:-15}"

    if [[ -n "${LANDSCAPE_ROUTER_PID}" ]] && kill -0 "${LANDSCAPE_ROUTER_PID}" 2>/dev/null; then
        info "Stopping router VM (PID ${LANDSCAPE_ROUTER_PID})..."

        if [[ -n "${LANDSCAPE_ROUTER_MONITOR}" ]] && [[ -S "${LANDSCAPE_ROUTER_MONITOR}" ]]; then
            echo "system_powerdown" | socat -T2 STDIN UNIX-CONNECT:"${LANDSCAPE_ROUTER_MONITOR}" &>/dev/null || true
            local waited=0
            while kill -0 "${LANDSCAPE_ROUTER_PID}" 2>/dev/null && [[ $waited -lt $shutdown_timeout ]]; do
                sleep 1
                ((waited++))
            done
            if kill -0 "${LANDSCAPE_ROUTER_PID}" 2>/dev/null; then
                echo "quit" | socat -T2 STDIN UNIX-CONNECT:"${LANDSCAPE_ROUTER_MONITOR}" &>/dev/null || true
                sleep 2
            fi
        fi

        if kill -0 "${LANDSCAPE_ROUTER_PID}" 2>/dev/null; then
            warn "Router VM did not shut down gracefully, sending SIGKILL"
            kill -9 "${LANDSCAPE_ROUTER_PID}" 2>/dev/null || true
            wait "${LANDSCAPE_ROUTER_PID}" 2>/dev/null || true
        fi
    fi
}

landscape_router_cleanup() {
    set +e
    landscape_router_stop_vm

    [[ -n "${LANDSCAPE_ROUTER_TEMP_IMAGE}" ]] && rm -f "${LANDSCAPE_ROUTER_TEMP_IMAGE}"
    [[ -n "${LANDSCAPE_ROUTER_PIDFILE}" ]] && rm -f "${LANDSCAPE_ROUTER_PIDFILE}"
    [[ -n "${LANDSCAPE_ROUTER_MONITOR}" ]] && rm -f "${LANDSCAPE_ROUTER_MONITOR}"
}

detect_guest_init_system() {
    if guest_run "command -v systemctl" &>/dev/null; then
        echo "systemd"
    elif guest_run "command -v rc-service" &>/dev/null; then
        echo "openrc"
    else
        echo "unknown"
    fi
}

_landscape_json_or_empty() {
    local payload="$1"
    if printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$payload"
    else
        printf '{}'
    fi
}

landscape_router_write_service_snapshot() {
    local token="$1"
    local interfaces_json ipconfigs_json nat_json route_wans_json dhcp_json route_lans_json

    interfaces_json=$(_landscape_json_or_empty "$(landscape_api_interfaces "$token" 2>/dev/null || printf '{}')")
    ipconfigs_json=$(_landscape_json_or_empty "$(landscape_api_service_status "$token" ipconfigs 2>/dev/null || printf '{}')")
    nat_json=$(_landscape_json_or_empty "$(landscape_api_service_status "$token" nat 2>/dev/null || printf '{}')")
    route_wans_json=$(_landscape_json_or_empty "$(landscape_api_service_status "$token" route_wans 2>/dev/null || printf '{}')")
    dhcp_json=$(_landscape_json_or_empty "$(landscape_api_service_status "$token" dhcp_v4 2>/dev/null || printf '{}')")
    route_lans_json=$(_landscape_json_or_empty "$(landscape_api_service_status "$token" route_lans 2>/dev/null || printf '{}')")

    jq -n \
        --arg timestamp_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg api_base "${API_BASE:-}" \
        --arg api_layout "${API_LAYOUT:-}" \
        --arg wan_iface "${LANDSCAPE_EXPECTED_WAN_IFACE}" \
        --arg lan_iface "${LANDSCAPE_EXPECTED_LAN_IFACE}" \
        --argjson interfaces "$interfaces_json" \
        --argjson ipconfigs "$ipconfigs_json" \
        --argjson nat "$nat_json" \
        --argjson route_wans "$route_wans_json" \
        --argjson dhcp_v4 "$dhcp_json" \
        --argjson route_lans "$route_lans_json" \
        '{
            timestamp_utc: $timestamp_utc,
            api_base: $api_base,
            api_layout: $api_layout,
            expected: {
                wan_iface: $wan_iface,
                lan_iface: $lan_iface
            },
            interfaces: $interfaces,
            services: {
                ipconfigs: $ipconfigs,
                nat: $nat,
                route_wans: $route_wans,
                dhcp_v4: $dhcp_v4,
                route_lans: $route_lans
            }
        }' > "${LANDSCAPE_SERVICE_SNAPSHOT_FILE}"
}

landscape_router_write_readiness_snapshot() {
    local status="$1"
    local failure_reason="$2"
    local ssh_state="$3"
    local api_listener_state="$4"
    local api_login_state="$5"
    local api_layout_state="$6"
    local interfaces_state="$7"
    shift 7
    local service_line

    {
        echo "status=${status}"
        echo "failure_reason=${failure_reason}"
        echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "api_base=${API_BASE:-}"
        echo "api_layout=${API_LAYOUT:-}"
        echo "ssh=${ssh_state}"
        echo "api_listener=${api_listener_state}"
        echo "api_login=${api_login_state}"
        echo "api_layout_detection=${api_layout_state}"
        echo "interfaces=${interfaces_state}"
        echo "expected_wan_iface=${LANDSCAPE_EXPECTED_WAN_IFACE}"
        echo "expected_lan_iface=${LANDSCAPE_EXPECTED_LAN_IFACE}"
        echo "expected_lan_gateway=${LANDSCAPE_EXPECTED_LAN_GATEWAY}"
        echo "expected_lan_subnet_prefix=${LANDSCAPE_EXPECTED_LAN_SUBNET_PREFIX}"
        echo "services:"
        for service_line in "$@"; do
            echo "  - ${service_line}"
        done
    } > "${LANDSCAPE_READINESS_SNAPSHOT_FILE}"
}

landscape_router_dump_diagnostics() {
    local token="${1:-}"
    local init_system="unknown"

    if [[ ${#SSH_ARGS[@]} -gt 0 ]]; then
        init_system=$(detect_guest_init_system 2>/dev/null || echo unknown)
    fi

    {
        echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "init_system=${init_system}"
        echo "api_base=${API_BASE:-}"
        echo "api_layout=${API_LAYOUT:-}"
        echo ""
        echo "== metadata =="
        if [[ -f "${LANDSCAPE_TEST_METADATA_FILE}" ]]; then
            cat "${LANDSCAPE_TEST_METADATA_FILE}"
        fi
        echo ""
        echo "== guest uname =="
        guest_run "uname -a" 2>&1 || true
        echo ""
        echo "== guest ip addr =="
        guest_run "ip addr" 2>&1 || true
        echo ""
        echo "== guest ip route =="
        guest_run "ip route" 2>&1 || true
        echo ""
        echo "== guest listening sockets =="
        guest_run "ss -tlnp" 2>&1 || true
        echo ""
        echo "== guest resolv.conf =="
        guest_run "cat /etc/resolv.conf" 2>&1 || true
        echo ""
        echo "== guest ip_forward =="
        guest_run "cat /proc/sys/net/ipv4/ip_forward" 2>&1 || true
        echo ""

        if [[ "${init_system}" == "systemd" ]]; then
            echo "== systemd status: landscape-router =="
            guest_run "systemctl status landscape-router --no-pager -l" 2>&1 || true
            echo ""
            echo "== journalctl: landscape-router =="
            guest_run "journalctl -u landscape-router -n 100 --no-pager" 2>&1 || true
        elif [[ "${init_system}" == "openrc" ]]; then
            echo "== openrc status: landscape-router =="
            guest_run "rc-service landscape-router status" 2>&1 || true
            echo ""
            echo "== openrc crashed services =="
            guest_run "rc-status --crashed" 2>&1 || true
        fi
    } > "${LANDSCAPE_ROUTER_DIAGNOSTICS_FILE}"

    if [[ -n "$token" ]]; then
        landscape_router_write_service_snapshot "$token"
    fi
}

landscape_router_wait_ready() {
    local label="${1:-Router}"
    local ssh_timeout="${2:-${SSH_TIMEOUT:-120}}"
    local ready_timeout="${3:-${LANDSCAPE_ROUTER_READY_TIMEOUT}}"
    local ssh_state="pending"
    local api_listener_state="pending"
    local api_login_state="pending"
    local api_layout_state="pending"
    local interfaces_state="pending"
    local -a service_states=()
    local token=""
    local ifaces=""
    local service_key iface binding failure_reason=""

    LANDSCAPE_ROUTER_API_TOKEN=""

    if ! wait_for_guest_ssh "${LANDSCAPE_ROUTER_PID}" "${LANDSCAPE_ROUTER_SERIAL_LOG}" "$label" "$ssh_timeout"; then
        ssh_state="failed"
        failure_reason="guest ssh unreachable"
        landscape_router_write_readiness_snapshot failed "$failure_reason" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state"
        landscape_router_dump_diagnostics
        return 1
    fi
    ssh_state="ready"

    if ! detect_landscape_api_base "$ready_timeout" "$LANDSCAPE_API_READY_INTERVAL"; then
        api_listener_state="failed"
        failure_reason="api listener unreachable"
        landscape_router_write_readiness_snapshot failed "$failure_reason" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state"
        landscape_router_dump_diagnostics
        return 1
    fi
    api_listener_state="ready"

    token=$(landscape_api_login "$ready_timeout" "$LANDSCAPE_API_READY_INTERVAL" 2>/dev/null || true)
    if [[ -z "$token" ]]; then
        api_login_state="failed"
        failure_reason="api login failed"
        landscape_router_write_readiness_snapshot failed "$failure_reason" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state"
        landscape_router_dump_diagnostics
        return 1
    fi
    api_login_state="ready"

    if ! detect_landscape_api_layout "$token" "$ready_timeout"; then
        api_layout_state="failed"
        failure_reason="api layout detection failed"
        landscape_router_write_readiness_snapshot failed "$failure_reason" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state"
        landscape_router_dump_diagnostics "$token"
        return 1
    fi
    api_layout_state="ready"

    ifaces=$(landscape_api_interfaces "$token" 2>/dev/null || true)
    if ! contains_all_text "$ifaces" "$LANDSCAPE_EXPECTED_WAN_IFACE" "$LANDSCAPE_EXPECTED_LAN_IFACE"; then
        interfaces_state="failed"
        failure_reason="expected interfaces missing from api"
        landscape_router_write_readiness_snapshot failed "$failure_reason" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state"
        landscape_router_dump_diagnostics "$token"
        return 1
    fi
    interfaces_state="ready"

    for binding in "${LANDSCAPE_ROUTER_CORE_SERVICE_BINDINGS[@]}"; do
        IFS=':' read -r service_key iface <<< "$binding"
        if wait_for_landscape_service_active "$token" "$service_key" "$iface" "$ready_timeout"; then
            service_states+=("${service_key}.${iface}=ready")
        else
            service_states+=("${service_key}.${iface}=failed")
            failure_reason="service ${service_key} on ${iface} not running"
            landscape_router_write_readiness_snapshot failed "$failure_reason" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state" "${service_states[@]}"
            landscape_router_dump_diagnostics "$token"
            return 1
        fi
    done

    LANDSCAPE_ROUTER_API_TOKEN="$token"
    landscape_router_write_readiness_snapshot ready "" "$ssh_state" "$api_listener_state" "$api_login_state" "$api_layout_state" "$interfaces_state" "${service_states[@]}"
    landscape_router_dump_diagnostics "$token"
    ok "${label} readiness contract satisfied"
    return 0
}

# ── Landscape API Compatibility Layer ─────────────────────────────────────────

API_BASE="${API_BASE:-}"
API_LAYOUT="${API_LAYOUT:-}"
API_AUTH_PATH="${API_AUTH_PATH:-/api/auth/login}"
API_USERNAME="${API_USERNAME:-root}"
API_PASSWORD="${API_PASSWORD:-root}"
LANDSCAPE_CONTROL_PORT="${LANDSCAPE_CONTROL_PORT:-6443}"

_landscape_api_preferred_prefixes() {
    case "${API_LAYOUT:-}" in
        v1)
            printf '%s\n' 'v1' 'src'
            ;;
        src)
            printf '%s\n' 'src' 'v1'
            ;;
        *)
            printf '%s\n' 'src' 'v1'
            ;;
    esac
}

_landscape_api_candidate_paths() {
    local key="$1"
    local arg="${2:-}"
    local prefix

    while IFS= read -r prefix; do
        case "$key" in
            interfaces)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/interfaces/all\n'
                else
                    printf '/api/src/iface/new\n'
                fi
                ;;
            ipconfigs_status)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/services/ip/status\n'
                else
                    printf '/api/src/services/ipconfigs/status\n'
                fi
                ;;
            nat_status)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/services/nat/status\n'
                else
                    printf '/api/src/services/nats/status\n'
                fi
                ;;
            dhcp_status)
                printf '/api/%s/services/dhcp_v4/status\n' "$prefix"
                ;;
            route_wans_status)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/services/wan/status\n'
                else
                    printf '/api/src/services/route_wans/status\n'
                fi
                ;;
            route_lans_status)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/services/lan/status\n'
                else
                    printf '/api/src/services/route_lans/status\n'
                fi
                ;;
            dhcp_config)
                printf '/api/%s/services/dhcp_v4/%s\n' "$prefix" "$arg"
                ;;
            assigned_ips)
                printf '/api/%s/services/dhcp_v4/assigned_ips\n' "$prefix"
                ;;
            static_nat_mappings)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/nat/static_mappings\n'
                else
                    printf '/api/src/config/static_nat_mappings\n'
                fi
                ;;
            dns_upstreams)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/dns/upstreams\n'
                else
                    printf '/api/src/config/dns_upstreams\n'
                fi
                ;;
            config_export)
                if [[ "$prefix" == 'v1' ]]; then
                    printf '/api/v1/system/config/export\n'
                else
                    printf '/api/src/sys_service/config/export\n'
                fi
                ;;
            *)
                return 1
                ;;
        esac
    done < <(_landscape_api_preferred_prefixes)
}

landscape_api_get_path() {
    local token="$1"
    local path="$2"
    local auth_header auth_header_q url_q

    auth_header="Authorization: Bearer ${token}"
    printf -v auth_header_q '%q' "$auth_header"
    printf -v url_q '%q' "${API_BASE}${path}"

    guest_run "curl -sfkL --max-time ${LANDSCAPE_TEST_HTTP_TIMEOUT} -H ${auth_header_q} ${url_q}"
}

_landscape_api_get_operation() {
    local token="$1"
    local key="$2"
    local arg="${3:-}"
    local path response

    while IFS= read -r path; do
        response=$(landscape_api_get_path "$token" "$path" 2>/dev/null) && {
            echo "$response"
            return 0
        }
    done < <(_landscape_api_candidate_paths "$key" "$arg")

    return 1
}

detect_landscape_api_base() {
    API_BASE="https://localhost:${LANDSCAPE_CONTROL_PORT}"

    local elapsed=0
    local timeout="${1:-${LANDSCAPE_API_READY_TIMEOUT}}"
    local interval="${2:-${LANDSCAPE_API_READY_INTERVAL}}"

    while [[ $elapsed -lt $timeout ]]; do
        if guest_run "curl -skI --max-time ${LANDSCAPE_TEST_HTTP_TIMEOUT} ${API_BASE}/ -o /dev/null" &>/dev/null; then
            info "API base: ${API_BASE}"
            return 0
        fi

        sleep "${interval}"
        ((elapsed += interval))
        if ((elapsed < timeout)) && ((elapsed % 15 == 0)); then
            info "  ...waiting for Landscape API (${elapsed}s)"
        fi
    done

    error "Landscape API not reachable at ${API_BASE} after ${timeout}s"
    return 1
}

landscape_api_login() {
    local payload payload_q content_type_q url_q login_resp token
    local elapsed=0
    local timeout="${1:-${LANDSCAPE_API_READY_TIMEOUT}}"
    local interval="${2:-${LANDSCAPE_API_READY_INTERVAL}}"

    payload=$(jq -cn --arg username "$API_USERNAME" --arg password "$API_PASSWORD" '{username:$username,password:$password}')
    printf -v payload_q '%q' "$payload"
    printf -v content_type_q '%q' 'Content-Type: application/json'
    printf -v url_q '%q' "${API_BASE}${API_AUTH_PATH}"

    while [[ $elapsed -lt $timeout ]]; do
        login_resp=$(guest_run "curl -sfkL --max-time ${LANDSCAPE_TEST_HTTP_TIMEOUT} -H ${content_type_q} -X POST -d ${payload_q} ${url_q}" 2>/dev/null) || login_resp=""
        token=$(echo "$login_resp" | jq -r '.data.token // empty' 2>/dev/null || true)

        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi

        sleep "${interval}"
        ((elapsed += interval))
        if ((elapsed < timeout)) && ((elapsed % 15 == 0)); then
            info "  ...waiting for Landscape API auth (${elapsed}s)" >&2
        fi
    done

    return 1
}

detect_landscape_api_layout() {
    local token="$1"
    local elapsed=0
    local timeout="${2:-60}"

    while [[ $elapsed -lt $timeout ]]; do
        if landscape_api_get_path "$token" '/api/v1/services/dhcp_v4/status' &>/dev/null; then
            API_LAYOUT='v1'
            info "Detected API layout: ${API_LAYOUT}"
            return 0
        fi

        if landscape_api_get_path "$token" '/api/src/services/dhcp_v4/status' &>/dev/null; then
            API_LAYOUT='src'
            info "Detected API layout: ${API_LAYOUT}"
            return 0
        fi

        sleep 3
        ((elapsed += 3))
        if ((elapsed % 15 == 0)); then
            info "  ...waiting for supported API layout (${elapsed}s)"
        fi
    done

    error 'Unable to detect supported API layout'
    return 1
}

landscape_api_interfaces() {
    local token="$1"
    _landscape_api_get_operation "$token" 'interfaces'
}

landscape_api_service_status() {
    local token="$1"
    local service_key="$2"
    local op

    case "$service_key" in
        ipconfigs)
            op='ipconfigs_status'
            ;;
        nat)
            op='nat_status'
            ;;
        dhcp_v4)
            op='dhcp_status'
            ;;
        route_wans)
            op='route_wans_status'
            ;;
        route_lans)
            op='route_lans_status'
            ;;
        *)
            error "Unknown Landscape service key: ${service_key}" >&2
            return 1
            ;;
    esac

    _landscape_api_get_operation "$token" "$op"
}

landscape_api_service_active() {
    local token="$1"
    local service_key="$2"
    local iface="$3"

    landscape_api_service_status "$token" "$service_key" \
        | jq -r --arg key "$iface" '.data[$key].t // empty | select(. == "running") | "yes"'
}

landscape_api_dhcp_config() {
    local token="$1"
    local iface="$2"
    _landscape_api_get_operation "$token" 'dhcp_config' "$iface"
}

landscape_api_dhcp_assigned() {
    local token="$1"
    _landscape_api_get_operation "$token" 'assigned_ips'
}

landscape_api_dhcp_assigned_ip() {
    local token="$1"
    local subnet_prefix="$2"

    landscape_api_dhcp_assigned "$token" | jq -r --arg prefix "$subnet_prefix" '
        .data
        | to_entries[]?.value.offered_ips[]?.ip
        | select(type == "string" and startswith($prefix))
    ' | head -n 1
}

landscape_api_static_nat_mappings() {
    local token="$1"
    _landscape_api_get_operation "$token" 'static_nat_mappings'
}

landscape_api_dns_upstreams() {
    local token="$1"
    _landscape_api_get_operation "$token" 'dns_upstreams'
}

wait_for_landscape_service_active() {
    local token="$1"
    local service_key="$2"
    local iface="$3"
    local timeout="${4:-30}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if [[ "$(landscape_api_service_active "$token" "$service_key" "$iface" 2>/dev/null || true)" == "yes" ]]; then
            return 0
        fi
        sleep 2
        ((elapsed += 2))
    done

    return 1
}

landscape_api_config_export() {
    local token="$1"
    _landscape_api_get_operation "$token" 'config_export'
}
