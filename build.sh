#!/bin/bash
set -euo pipefail

# =============================================================================
# Landscape Mini - Minimal x86 UEFI Image Builder
# =============================================================================
# Orchestrator: sources lib/common.sh + backend (lib/debian.sh or lib/alpine.sh)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration
if [ -f "${SCRIPT_DIR}/build.env" ]; then
    source "${SCRIPT_DIR}/build.env"
else
    echo "ERROR: build.env not found in ${SCRIPT_DIR}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse command line arguments
# ---------------------------------------------------------------------------
SKIP_TO_PHASE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)
            if [[ -n "${2:-}" && ( "$2" == "debian" || "$2" == "alpine" ) ]]; then
                BASE_SYSTEM="$2"
                shift 2
            else
                echo "ERROR: --base requires 'debian' or 'alpine'"
                exit 1
            fi
            ;;
        --with-docker)
            INCLUDE_DOCKER="yes"
            shift
            ;;
        --version)
            if [[ -n "${2:-}" ]]; then
                LANDSCAPE_VERSION="$2"
                shift 2
            else
                echo "ERROR: --version requires a value (e.g. --version v0.12.4)"
                exit 1
            fi
            ;;
        --skip-to)
            if [[ -n "${2:-}" && "${2:-}" =~ ^[1-8]$ ]]; then
                SKIP_TO_PHASE="$2"
                shift 2
            else
                echo "ERROR: --skip-to requires a phase number (1-8)"
                exit 1
            fi
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--base debian|alpine] [--with-docker] [--version VERSION] [--skip-to PHASE]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Must run as root
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Source shared library and backend
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

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
WORK_DIR="$(pwd)/work"
OUTPUT_DIR="$(pwd)/output"
ROOTFS_DIR="${WORK_DIR}/rootfs"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
LOOP_DEV=""

# Docker suffix
IMAGE_SUFFIX=""
if [[ "${INCLUDE_DOCKER}" == "yes" ]]; then
    IMAGE_SUFFIX="-docker"
fi

# Base system suffix (alpine gets a suffix, debian is the default with no suffix)
BASE_SUFFIX=""
if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
    BASE_SUFFIX="-alpine"
fi

IMAGE_FILE="${OUTPUT_DIR}/landscape-mini-x86${BASE_SUFFIX}${IMAGE_SUFFIX}.img"

# Determine download base URL
if [ "${LANDSCAPE_VERSION}" == "latest" ]; then
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/latest/download"
else
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/download/${LANDSCAPE_VERSION}"
fi

# Mirror selection based on base system
if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
    MIRROR="${ALPINE_MIRROR}"
else
    MIRROR="${APT_MIRROR}"
fi

echo "============================================================"
echo "  Landscape Mini - x86 UEFI Image Builder"
echo "============================================================"
echo "  Base System       : ${BASE_SYSTEM}"
echo "  Landscape Version : ${LANDSCAPE_VERSION}"
echo "  Download Source    : ${DOWNLOAD_BASE}"
if [[ "${BASE_SYSTEM}" == "debian" ]]; then
    echo "  Debian Release    : ${DEBIAN_RELEASE}"
    echo "  APT Mirror        : ${MIRROR}"
else
    echo "  Alpine Release    : ${ALPINE_RELEASE}"
    echo "  Alpine Mirror     : ${MIRROR}"
fi
echo "  Image Size        : ${IMAGE_SIZE_MB} MB"
echo "  Include Docker    : ${INCLUDE_DOCKER}"
echo "  Output Format     : ${OUTPUT_FORMAT}"
echo "  Compress Output   : ${COMPRESS_OUTPUT}"
echo "============================================================"

# ---------------------------------------------------------------------------
# Setup trap
# ---------------------------------------------------------------------------
trap cleanup EXIT ERR

# =============================================================================
# Main Execution
# =============================================================================
main() {
    # Check backend-specific host dependencies
    backend_check_deps

    if [[ ${SKIP_TO_PHASE} -gt 0 ]]; then
        echo ""
        echo "==== Resuming from Phase ${SKIP_TO_PHASE} ===="
        echo "  Phase 1: Download      | Phase 5: Install Landscape"
        echo "  Phase 2: Create Image  | Phase 6: Install Docker"
        echo "  Phase 3: Bootstrap     | Phase 7: Cleanup & Shrink"
        echo "  Phase 4: Configure     | Phase 8: Report"
    fi

    # Phase 1: Download (always run unless skipping past it)
    [[ ${SKIP_TO_PHASE} -le 1 ]] && phase_download

    # Phase 2: Create image
    if [[ ${SKIP_TO_PHASE} -le 2 ]]; then
        phase_create_image
    elif [[ ${SKIP_TO_PHASE} -le 7 ]]; then
        # Need to re-attach image for phases 3-7
        resume_from_image
    fi

    [[ ${SKIP_TO_PHASE} -le 3 ]] && backend_bootstrap
    [[ ${SKIP_TO_PHASE} -le 4 ]] && backend_configure
    [[ ${SKIP_TO_PHASE} -le 5 ]] && phase_install_landscape
    [[ ${SKIP_TO_PHASE} -le 6 ]] && backend_install_docker
    [[ ${SKIP_TO_PHASE} -le 7 ]] && phase_cleanup_and_shrink
    phase_report
}

main
