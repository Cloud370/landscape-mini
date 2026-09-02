#!/bin/bash
set -euo pipefail

# =============================================================================
# Landscape Mini - Minimal x86 UEFI Image Builder
# =============================================================================
# Orchestrator: sources lib/common.sh + backend (lib/debian.sh or lib/alpine.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ENV_PROFILE="${BUILD_ENV_PROFILE:-}"

# Rootless shells often lack the sbin directories where mkfs/e2fsck/sgdisk
# live; add the conventional locations so the build works from any login.
for _sbin_dir in /usr/local/sbin /usr/sbin /sbin; do
    [[ -d "${_sbin_dir}" && ":${PATH}:" != *":${_sbin_dir}:"* ]] && PATH="${PATH}:${_sbin_dir}"
done
unset _sbin_dir
export PATH

# Supported config variables whose explicit shell environment should override
# layered env files such as build.env.<profile> and build.env.local.
declare -a CONFIG_ENV_KEYS=(
    BASE_SYSTEM
    LANDSCAPE_VERSION
    LANDSCAPE_REPO
    INCLUDE_LKIT
    LKIT_REPO
    LKIT_VERSION
    DEBIAN_RELEASE
    ALPINE_RELEASE
    IMAGE_SIZE_MB
    INCLUDE_DOCKER
    ROOT_PASSWORD
    LANDSCAPE_ADMIN_USER
    LANDSCAPE_ADMIN_PASS
    LANDSCAPE_LAN_SERVER_IP
    LANDSCAPE_LAN_RANGE_START
    LANDSCAPE_LAN_RANGE_END
    LANDSCAPE_LAN_NETMASK
    RUN_TEST
    TIMEZONE
    LOCALE
    EXTRA_LOCALES
    APT_MIRROR
    APT_MIRROR_CANDIDATES
    ALPINE_MIRROR
    ALPINE_MIRROR_CANDIDATES
    DOCKER_APT_MIRROR
    DOCKER_APT_MIRROR_CANDIDATES
    DOCKER_APT_GPG_URL
    DOCKER_APT_GPG_URL_CANDIDATES
    OUTPUT_FORMATS
    COMPRESS_OUTPUT
    EFFECTIVE_CONFIG_PATH
    EFFECTIVE_CONFIG_PROFILE
    EFFECTIVE_TOPOLOGY_SOURCE
    ROOT_PASSWORD_SOURCE
    LANDSCAPE_ADMIN_USER_SOURCE
    LANDSCAPE_ADMIN_PASS_SOURCE
    RELEASE_CHANNEL
    RELEASE_TAG
    REPOSITORY_OWNER
    SOURCE_PROBE_TIMEOUT
    SOURCE_FAILOVER_TIMEOUT
    CACHE_DIR
)
declare -A EXPLICIT_ENV_VALUES=()
declare -A EXPLICIT_ENV_IS_SET=()

snapshot_explicit_config_env() {
    local key
    for key in "${CONFIG_ENV_KEYS[@]}"; do
        if [[ -v ${key} ]]; then
            EXPLICIT_ENV_IS_SET["${key}"]=1
            EXPLICIT_ENV_VALUES["${key}"]="${!key}"
        fi
    done
}

restore_explicit_config_env() {
    local key
    for key in "${CONFIG_ENV_KEYS[@]}"; do
        if [[ "${EXPLICIT_ENV_IS_SET[${key}]:-0}" == "1" ]]; then
            printf -v "${key}" '%s' "${EXPLICIT_ENV_VALUES[${key}]}"
            export "${key}"
        fi
    done
}

source_build_config_file() {
    local file_path="$1"
    # shellcheck disable=SC1090
    source "${file_path}"
}

load_build_configuration() {
    local default_file="${SCRIPT_DIR}/build.env"
    local profile_file="${SCRIPT_DIR}/build.env.${BUILD_ENV_PROFILE}"
    local local_file="${SCRIPT_DIR}/build.env.local"

    if [[ ! -f "${default_file}" ]]; then
        echo "ERROR: build.env not found in ${SCRIPT_DIR}" >&2
        exit 1
    fi

    snapshot_explicit_config_env
    source_build_config_file "${default_file}"

    if [[ -n "${BUILD_ENV_PROFILE}" ]]; then
        if [[ ! -f "${profile_file}" ]]; then
            echo "ERROR: Requested profile file not found: ${profile_file}" >&2
            exit 1
        fi
        source_build_config_file "${profile_file}"
    fi

    if [[ -f "${local_file}" ]]; then
        source_build_config_file "${local_file}"
    fi

    restore_explicit_config_env
}

load_build_configuration

# ---------------------------------------------------------------------------
# Parse command line arguments
# ---------------------------------------------------------------------------
SKIP_TO_PHASE=0
EFFECTIVE_CONFIG_PATH="${EFFECTIVE_CONFIG_PATH:-}"
EFFECTIVE_CONFIG_PROFILE="${EFFECTIVE_CONFIG_PROFILE:-${BUILD_ENV_PROFILE:-default}}"
EFFECTIVE_TOPOLOGY_SOURCE="${EFFECTIVE_TOPOLOGY_SOURCE:-default}"
ROOT_PASSWORD_SOURCE="${ROOT_PASSWORD_SOURCE:-default}"
LANDSCAPE_ADMIN_USER="${LANDSCAPE_ADMIN_USER:-root}"
LANDSCAPE_ADMIN_USER_SOURCE="${LANDSCAPE_ADMIN_USER_SOURCE:-default}"
LANDSCAPE_ADMIN_PASS="${LANDSCAPE_ADMIN_PASS:-root}"
LANDSCAPE_ADMIN_PASS_SOURCE="${LANDSCAPE_ADMIN_PASS_SOURCE:-default}"
RUN_TEST="${RUN_TEST:-}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-local}"
RELEASE_TAG="${RELEASE_TAG:-}"
REPOSITORY_OWNER="${REPOSITORY_OWNER:-}"
INCLUDE_LKIT="${INCLUDE_LKIT:-false}"
LKIT_REPO="${LKIT_REPO:-https://github.com/landscape-router/landscape-kit}"
LKIT_VERSION="${LKIT_VERSION:-latest}"

declare -a CLI_OUTPUT_FORMATS=()
declare -a OUTPUT_FORMAT_LIST=()
RUN_READINESS=false
RUN_DATAPLANE=false

action_usage() {
    cat <<'EOF'
Usage:
  ./build.sh [options]

Options:
  --base-system debian|alpine
  --include-docker true|false
  --output-format img|vmdk|ova   (repeatable)
  --version VERSION
  --skip-to PHASE

Environment layering:
  build.env < build.env.<profile> < build.env.local < explicit env
  Use BUILD_ENV_PROFILE=<name> to load build.env.<name>
EOF
}

join_by() {
    local delimiter="$1"
    shift || true
    local first=1
    local value
    for value in "$@"; do
        if [[ ${first} -eq 1 ]]; then
            printf '%s' "${value}"
            first=0
        else
            printf '%s%s' "${delimiter}" "${value}"
        fi
    done
}

validate_base_system() {
    case "$1" in
        debian|alpine)
            ;;
        *)
            echo "ERROR: BASE_SYSTEM must be 'debian' or 'alpine', got '$1'." >&2
            exit 1
            ;;
    esac
}

validate_include_docker() {
    case "$1" in
        true|false)
            ;;
        *)
            echo "ERROR: INCLUDE_DOCKER must be 'true' or 'false', got '$1'." >&2
            exit 1
            ;;
    esac
}

validate_include_lkit() {
    case "$1" in
        true|false)
            ;;
        *)
            echo "ERROR: INCLUDE_LKIT must be 'true' or 'false', got '$1'." >&2
            exit 1
            ;;
    esac
}

validate_output_format() {
    case "$1" in
        img|vmdk|ova)
            ;;
        *)
            echo "ERROR: Unsupported output format '$1'. Use img, vmdk, or ova." >&2
            exit 1
            ;;
    esac
}

normalize_output_formats() {
    local -a raw_items=()
    local -a normalized=()
    local raw_value trimmed
    local seen=","

    if [[ ${#CLI_OUTPUT_FORMATS[@]} -gt 0 ]]; then
        raw_items=("${CLI_OUTPUT_FORMATS[@]}")
    else
        IFS=',' read -r -a raw_items <<< "${OUTPUT_FORMATS}"
    fi

    for raw_value in "${raw_items[@]}"; do
        trimmed="${raw_value//[[:space:]]/}"
        [[ -n "${trimmed}" ]] || continue
        validate_output_format "${trimmed}"
        if [[ "${seen}" == *",${trimmed},"* ]]; then
            continue
        fi
        normalized+=("${trimmed}")
        seen+="${trimmed},"
    done

    if [[ ${#normalized[@]} -eq 0 ]]; then
        echo "ERROR: At least one output format is required." >&2
        exit 1
    fi

    OUTPUT_FORMAT_LIST=("${normalized[@]}")
    OUTPUT_FORMATS="$(join_by , "${OUTPUT_FORMAT_LIST[@]}")"
}

normalize_run_test_selection() {
    local selection="${RUN_TEST,,}"
    selection="${selection//[[:space:]]/}"

    case "${selection}" in
        ""|none)
            RUN_TEST="none"
            RUN_READINESS=false
            RUN_DATAPLANE=false
            ;;
        readiness)
            RUN_TEST="readiness"
            RUN_READINESS=true
            RUN_DATAPLANE=false
            ;;
        readiness,dataplane)
            RUN_TEST="readiness,dataplane"
            RUN_READINESS=true
            RUN_DATAPLANE=true
            ;;
        *)
            echo "ERROR: RUN_TEST must be empty, 'none', 'readiness', or 'readiness,dataplane'; got '${RUN_TEST}'." >&2
            exit 1
            ;;
    esac
}

has_local_topology_inputs() {
    [[ -n "${LANDSCAPE_LAN_SERVER_IP:-}" || -n "${LANDSCAPE_LAN_RANGE_START:-}" || -n "${LANDSCAPE_LAN_RANGE_END:-}" || -n "${LANDSCAPE_LAN_NETMASK:-}" ]]
}

prepare_effective_topology_config() {
    if [[ -n "${EFFECTIVE_CONFIG_PATH}" ]]; then
        if has_local_topology_inputs; then
            echo "[WARN] EFFECTIVE_CONFIG_PATH is already set; ignoring LAN/DHCP env overrides." >&2
        fi
        return 0
    fi

    if ! has_local_topology_inputs; then
        return 0
    fi

    mkdir -p "${OUTPUT_METADATA_DIR}"
    bash "${SCRIPT_DIR}/.github/scripts/render-effective-topology.sh" "${OUTPUT_METADATA_DIR}/effective-landscape_init.toml"
    ensure_init_config_version "${OUTPUT_METADATA_DIR}/effective-landscape_init.toml"
    EFFECTIVE_CONFIG_PATH="${OUTPUT_METADATA_DIR}/effective-landscape_init.toml"

    if [[ "${EFFECTIVE_TOPOLOGY_SOURCE}" == "default" ]]; then
        EFFECTIVE_TOPOLOGY_SOURCE="input"
    fi

    if [[ -z "${BUILD_ENV_PROFILE}" && "${EFFECTIVE_CONFIG_PROFILE}" == "default" ]]; then
        EFFECTIVE_CONFIG_PROFILE="custom"
    fi
}

write_local_test_skip_marker() {
    local reason="$1"
    mkdir -p "${OUTPUT_DIR}/test-logs"
    cat > "${OUTPUT_DIR}/test-logs/dataplane-skipped.txt" <<EOF
base_system=${BASE_SYSTEM}
include_docker=${INCLUDE_DOCKER}
run_test=${RUN_TEST}
reason=${reason}
EOF
}

run_local_post_build_tests() {
    if [[ "${RUN_TEST}" == "none" ]]; then
        return 0
    fi

    export WORK_DIR="${WORK_DIR}"
    export OUTPUT_DIR="${OUTPUT_DIR}"
    export LANDSCAPE_TEST_BASE_SYSTEM="${BASE_SYSTEM}"
    export LANDSCAPE_TEST_INCLUDE_DOCKER="${INCLUDE_DOCKER}"
    export LANDSCAPE_TEST_OUTPUT_FORMATS="${OUTPUT_FORMATS}"
    export LANDSCAPE_TEST_RUN_TEST="${RUN_TEST}"
    export LANDSCAPE_TEST_RELEASE_CHANNEL="${RELEASE_CHANNEL}"
    export LANDSCAPE_TEST_LANDSCAPE_VERSION="${LANDSCAPE_VERSION}"
    export LANDSCAPE_EFFECTIVE_INIT_CONFIG="${EFFECTIVE_CONFIG_PATH:-${OUTPUT_METADATA_DIR}/effective-landscape_init.toml}"
    export SSH_PASSWORD="${ROOT_PASSWORD}"
    export API_USERNAME="${LANDSCAPE_ADMIN_USER}"
    export API_PASSWORD="${LANDSCAPE_ADMIN_PASS}"

    if [[ "${RUN_READINESS}" == "true" ]]; then
        echo ""
        echo "==== Local Validation: readiness ===="
        timeout --foreground 20m "${SCRIPT_DIR}/tests/test-readiness.sh" "${IMAGE_FILE}"
    fi

    if [[ "${RUN_DATAPLANE}" == "true" ]]; then
        if [[ "${INCLUDE_DOCKER}" == "true" ]]; then
            echo "[SKIP] Dataplane tests are not scheduled when INCLUDE_DOCKER=true." >&2
            write_local_test_skip_marker "Dataplane is only available for include_docker=false builds"
            return 0
        fi

        echo ""
        echo "==== Local Validation: dataplane ===="
        timeout --foreground 25m "${SCRIPT_DIR}/tests/test-dataplane.sh" "${IMAGE_FILE}"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-system)
            if [[ -n "${2:-}" ]]; then
                BASE_SYSTEM="$2"
                shift 2
            else
                echo "ERROR: --base-system requires 'debian' or 'alpine'" >&2
                exit 1
            fi
            ;;
        --include-docker)
            if [[ -n "${2:-}" ]]; then
                INCLUDE_DOCKER="$2"
                shift 2
            else
                echo "ERROR: --include-docker requires 'true' or 'false'" >&2
                exit 1
            fi
            ;;
        --output-format)
            if [[ -n "${2:-}" ]]; then
                CLI_OUTPUT_FORMATS+=("$2")
                shift 2
            else
                echo "ERROR: --output-format requires img, vmdk, or ova" >&2
                exit 1
            fi
            ;;
        --version)
            if [[ -n "${2:-}" ]]; then
                LANDSCAPE_VERSION="$2"
                shift 2
            else
                echo "ERROR: --version requires a value (e.g. --version v0.12.4)" >&2
                exit 1
            fi
            ;;
        --skip-to)
            if [[ -n "${2:-}" && "${2:-}" =~ ^[1-8]$ ]]; then
                SKIP_TO_PHASE="$2"
                shift 2
            else
                echo "ERROR: --skip-to requires a phase number (1-8)" >&2
                exit 1
            fi
            ;;
        --help|-h)
            action_usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            action_usage >&2
            exit 1
            ;;
    esac
done

validate_base_system "${BASE_SYSTEM}"
validate_include_docker "${INCLUDE_DOCKER}"
validate_include_lkit "${INCLUDE_LKIT}"
if [[ "${INCLUDE_LKIT}" == "true" && "${BASE_SYSTEM}" != "debian" ]]; then
    echo "ERROR: INCLUDE_LKIT=true requires BASE_SYSTEM=debian (lkit manages systemd units)." >&2
    exit 1
fi
normalize_output_formats
normalize_run_test_selection

# ---------------------------------------------------------------------------
# Source shared library and backend, then detect the privilege model
# (root with classic chroot, or rootless via unshare/proot)
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/common.sh"

case "${BASE_SYSTEM}" in
    debian)
        source "${SCRIPT_DIR}/lib/debian.sh"
        ;;
    alpine)
        source "${SCRIPT_DIR}/lib/alpine.sh"
        ;;
    *)
        echo "ERROR: Unknown base system '${BASE_SYSTEM}'. Use 'debian' or 'alpine'."
        exit 1
        ;;
esac

detect_build_environment
check_core_deps
backend_check_deps

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
WORK_DIR="${WORK_DIR:-$(pwd)/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
OUTPUT_METADATA_DIR="${OUTPUT_DIR}/metadata"
ROOTFS_DIR="${WORK_DIR}/rootfs"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/.cache}"
SOURCE_PROBE_TIMEOUT="${SOURCE_PROBE_TIMEOUT:-5}"
SOURCE_FAILOVER_TIMEOUT="${SOURCE_FAILOVER_TIMEOUT:-120}"

# Resolve "latest" to a concrete release tag so downloads stay cacheable and
# the init config version field can be pinned (upstream requires an exact
# match since v0.19).
resolve_landscape_release_version
RESOLVED_LANDSCAPE_VERSION="${RESOLVED_LANDSCAPE_VERSION:-${LANDSCAPE_VERSION}}"
DOWNLOAD_DIR="${CACHE_DIR}/downloads/${RESOLVED_LANDSCAPE_VERSION}"

resolve_lkit_release_version
RESOLVED_LKIT_VERSION="${RESOLVED_LKIT_VERSION:-${LKIT_VERSION}}"
LKIT_DOWNLOAD_DIR="${CACHE_DIR}/downloads/lkit/${RESOLVED_LKIT_VERSION}"
LKIT_BINARY_FILE="${LKIT_DOWNLOAD_DIR}/lkit-x86_64"
IMAGE_CREATED_AT="${IMAGE_CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# Determine download base URL
if [[ "${RESOLVED_LANDSCAPE_VERSION}" == "latest" ]]; then
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/latest/download"
else
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/download/${RESOLVED_LANDSCAPE_VERSION}"
fi

BUILD_NAME="landscape-mini-x86-${BASE_SYSTEM}"
if [[ "${INCLUDE_DOCKER}" == "true" ]]; then
    BUILD_NAME+="-docker"
fi
if [[ "${INCLUDE_LKIT}" == "true" ]]; then
    BUILD_NAME+="-lkit"
fi

IMAGE_FILE="${OUTPUT_DIR}/${BUILD_NAME}.img"
VMDK_FILE="${OUTPUT_DIR}/${BUILD_NAME}.vmdk"
OVA_FILE="${OUTPUT_DIR}/${BUILD_NAME}.ova"
BUILD_METADATA_FILE="${OUTPUT_METADATA_DIR}/build-metadata.txt"
RESOLVED_SOURCES_FILE="${OUTPUT_METADATA_DIR}/resolved-sources.env"

# ---------------------------------------------------------------------------
# Source resolution helpers
# ---------------------------------------------------------------------------
resolve_build_sources() {
    echo ""
    echo "==== Source Resolution ===="

    if [[ "${BASE_SYSTEM}" == "debian" ]]; then
        resolve_source \
            "Debian APT mirror" \
            "${APT_MIRROR}" \
            "${APT_MIRROR_CANDIDATES}" \
            "debian-package" \
            "/dists/${DEBIAN_RELEASE}/main/binary-amd64/Packages.xz" \
            "RESOLVED_APT_MIRROR" \
            "RESOLVED_APT_MIRROR_SOURCE" \
            "${SOURCE_PROBE_TIMEOUT}" \
            "${SOURCE_FAILOVER_TIMEOUT}"
        RESOLVED_ALPINE_MIRROR=""
        RESOLVED_ALPINE_MIRROR_SOURCE="unused"
    else
        resolve_source \
            "Alpine mirror" \
            "${ALPINE_MIRROR}" \
            "${ALPINE_MIRROR_CANDIDATES}" \
            "alpine-package" \
            "/${ALPINE_RELEASE}/main/x86_64" \
            "RESOLVED_ALPINE_MIRROR" \
            "RESOLVED_ALPINE_MIRROR_SOURCE" \
            "${SOURCE_PROBE_TIMEOUT}" \
            "${SOURCE_FAILOVER_TIMEOUT}"
        RESOLVED_APT_MIRROR=""
        RESOLVED_APT_MIRROR_SOURCE="unused"
    fi

    if [[ "${INCLUDE_DOCKER}" == "true" && "${BASE_SYSTEM}" == "debian" ]]; then
        resolve_source \
            "Docker APT mirror" \
            "${DOCKER_APT_MIRROR}" \
            "${DOCKER_APT_MIRROR_CANDIDATES}" \
            "plain-debian-package" \
            "/dists/${DEBIAN_RELEASE}/stable/binary-amd64/Packages" \
            "RESOLVED_DOCKER_APT_MIRROR" \
            "RESOLVED_DOCKER_APT_MIRROR_SOURCE" \
            "${SOURCE_PROBE_TIMEOUT}" \
            "${SOURCE_FAILOVER_TIMEOUT}"

        resolve_source \
            "Docker APT GPG URL" \
            "${DOCKER_APT_GPG_URL}" \
            "${DOCKER_APT_GPG_URL_CANDIDATES}" \
            "direct" \
            "" \
            "RESOLVED_DOCKER_APT_GPG_URL" \
            "RESOLVED_DOCKER_APT_GPG_URL_SOURCE" \
            "${SOURCE_PROBE_TIMEOUT}" \
            "${SOURCE_FAILOVER_TIMEOUT}"
    else
        RESOLVED_DOCKER_APT_MIRROR=""
        RESOLVED_DOCKER_APT_MIRROR_SOURCE="unused"
        RESOLVED_DOCKER_APT_GPG_URL=""
        RESOLVED_DOCKER_APT_GPG_URL_SOURCE="unused"
    fi

    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        MIRROR="${RESOLVED_ALPINE_MIRROR}"
    else
        MIRROR="${RESOLVED_APT_MIRROR}"
    fi

    DOCKER_MIRROR_DISPLAY="${RESOLVED_DOCKER_APT_MIRROR:-}"
    DOCKER_GPG_DISPLAY="${RESOLVED_DOCKER_APT_GPG_URL:-}"

    mkdir -p "${OUTPUT_METADATA_DIR}"
    printf '%s\n' \
        "resolved_apt_mirror=${RESOLVED_APT_MIRROR}" \
        "resolved_apt_mirror_source=${RESOLVED_APT_MIRROR_SOURCE}" \
        "resolved_alpine_mirror=${RESOLVED_ALPINE_MIRROR}" \
        "resolved_alpine_mirror_source=${RESOLVED_ALPINE_MIRROR_SOURCE}" \
        "resolved_docker_apt_mirror=${RESOLVED_DOCKER_APT_MIRROR}" \
        "resolved_docker_apt_mirror_source=${RESOLVED_DOCKER_APT_MIRROR_SOURCE}" \
        "resolved_docker_apt_gpg_url=${RESOLVED_DOCKER_APT_GPG_URL}" \
        "resolved_docker_apt_gpg_url_source=${RESOLVED_DOCKER_APT_GPG_URL_SOURCE}" \
        > "${RESOLVED_SOURCES_FILE}"

    echo "  Source resolution complete."
}

load_resolved_sources() {
    if [[ ! -f "${RESOLVED_SOURCES_FILE}" ]]; then
        echo "ERROR: Missing ${RESOLVED_SOURCES_FILE} for resumed build." >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "${RESOLVED_SOURCES_FILE}"

    RESOLVED_APT_MIRROR="${resolved_apt_mirror:-}"
    RESOLVED_APT_MIRROR_SOURCE="${resolved_apt_mirror_source:-unknown}"
    RESOLVED_ALPINE_MIRROR="${resolved_alpine_mirror:-}"
    RESOLVED_ALPINE_MIRROR_SOURCE="${resolved_alpine_mirror_source:-unknown}"
    RESOLVED_DOCKER_APT_MIRROR="${resolved_docker_apt_mirror:-}"
    RESOLVED_DOCKER_APT_MIRROR_SOURCE="${resolved_docker_apt_mirror_source:-unknown}"
    RESOLVED_DOCKER_APT_GPG_URL="${resolved_docker_apt_gpg_url:-}"
    RESOLVED_DOCKER_APT_GPG_URL_SOURCE="${resolved_docker_apt_gpg_url_source:-unknown}"

    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        MIRROR="${RESOLVED_ALPINE_MIRROR}"
    else
        MIRROR="${RESOLVED_APT_MIRROR}"
    fi

    DOCKER_MIRROR_DISPLAY="${RESOLVED_DOCKER_APT_MIRROR:-}"
    DOCKER_GPG_DISPLAY="${RESOLVED_DOCKER_APT_GPG_URL:-}"

    echo "  Reusing resolved sources from ${RESOLVED_SOURCES_FILE}."
}

should_resolve_sources() {
    if [[ ${SKIP_TO_PHASE} -le 4 ]]; then
        return 0
    fi

    if [[ "${INCLUDE_DOCKER}" == "true" && ${SKIP_TO_PHASE} -le 6 ]]; then
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Setup trap
# ---------------------------------------------------------------------------
# EXIT alone: on a failing command under `set -e`, ERR would fire first and
# EXIT right after, running cleanup twice for one failure.
trap cleanup EXIT

main() {
    prepare_effective_topology_config

    if should_resolve_sources; then
        resolve_build_sources
    elif [[ ${SKIP_TO_PHASE} -gt 0 ]]; then
        load_resolved_sources
    fi

    echo "============================================================"
    echo "  Landscape Mini - x86 UEFI Image Builder"
    echo "============================================================"
    echo "  Build Name        : ${BUILD_NAME}"
    echo "  Base System       : ${BASE_SYSTEM}"
    echo "  Include Docker    : ${INCLUDE_DOCKER}"
    echo "  Output Formats    : ${OUTPUT_FORMATS}"
    echo "  Landscape Version : ${LANDSCAPE_VERSION}"
    if [[ "${RESOLVED_LANDSCAPE_VERSION}" != "${LANDSCAPE_VERSION}" ]]; then
        echo "  Resolved Version  : ${RESOLVED_LANDSCAPE_VERSION}"
    fi
    echo "  Download Source   : ${DOWNLOAD_BASE}"
    echo "  Download Cache    : ${DOWNLOAD_DIR}"
    if [[ "${BASE_SYSTEM}" == "debian" ]]; then
        echo "  Debian Release    : ${DEBIAN_RELEASE}"
        echo "  APT Mirror        : ${MIRROR} (${RESOLVED_APT_MIRROR_SOURCE})"
    else
        echo "  Alpine Release    : ${ALPINE_RELEASE}"
        echo "  Alpine Mirror     : ${MIRROR} (${RESOLVED_ALPINE_MIRROR_SOURCE})"
    fi
    echo "  Image Size        : ${IMAGE_SIZE_MB} MB"
    if [[ "${INCLUDE_DOCKER}" == "true" && "${BASE_SYSTEM}" == "debian" ]]; then
        echo "  Docker APT Mirror : ${DOCKER_MIRROR_DISPLAY} (${RESOLVED_DOCKER_APT_MIRROR_SOURCE})"
        echo "  Docker GPG URL    : ${DOCKER_GPG_DISPLAY} (${RESOLVED_DOCKER_APT_GPG_URL_SOURCE})"
    elif [[ "${INCLUDE_DOCKER}" == "true" && "${BASE_SYSTEM}" == "alpine" ]]; then
        echo "  Docker Source     : Alpine packages via ${MIRROR} (${RESOLVED_ALPINE_MIRROR_SOURCE})"
    fi
    echo "  Compress Output   : ${COMPRESS_OUTPUT}"
    echo "  Config Profile    : ${EFFECTIVE_CONFIG_PROFILE}"
    echo "  Topology Source   : ${EFFECTIVE_TOPOLOGY_SOURCE}"
    echo "  Run Test          : ${RUN_TEST}"
    echo "  Privilege         : ${BUILD_PRIVILEGE} (engine: ${CHROOT_ENGINE})"
    if [[ "${INCLUDE_LKIT}" == "true" ]]; then
        echo "  Include lkit      : true"
        echo "  lkit Repo         : ${LKIT_REPO}"
        echo "  lkit Version      : ${LKIT_VERSION}"
        if [[ "${RESOLVED_LKIT_VERSION}" != "${LKIT_VERSION}" ]]; then
            echo "  Resolved lkit     : ${RESOLVED_LKIT_VERSION}"
        fi
    else
        echo "  Include lkit      : false"
    fi
    if [[ -n "${EFFECTIVE_CONFIG_PATH}" ]]; then
        echo "  Effective Config  : ${EFFECTIVE_CONFIG_PATH}"
    fi
    echo "  Admin User        : ${LANDSCAPE_ADMIN_USER}"
    echo "============================================================"

    if [[ ${SKIP_TO_PHASE} -gt 0 ]]; then
        echo ""
        echo "==== Resuming from Phase ${SKIP_TO_PHASE} ===="
        echo "  Phase 1: Download      | Phase 5: Install Landscape"
        echo "  Phase 2: Prepare Tree  | Phase 6: Install Docker"
        echo "  Phase 3: Bootstrap     | Phase 7: Cleanup & Assemble"
        echo "  Phase 4: Configure     | Phase 8: Report"
    fi

    [[ ${SKIP_TO_PHASE} -le 1 ]] && phase_download

    if [[ ${SKIP_TO_PHASE} -le 2 ]]; then
        phase_create_image
    else
        require_rootfs_tree
    fi

    [[ ${SKIP_TO_PHASE} -le 3 ]] && backend_bootstrap
    [[ ${SKIP_TO_PHASE} -le 4 ]] && backend_configure
    [[ ${SKIP_TO_PHASE} -le 5 ]] && phase_install_landscape
    [[ ${SKIP_TO_PHASE} -le 6 ]] && backend_install_docker
    [[ ${SKIP_TO_PHASE} -le 7 ]] && phase_cleanup_and_shrink
    phase_report
    run_local_post_build_tests
}

main
