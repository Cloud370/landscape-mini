#!/bin/sh
# Switch APT/APK package mirrors for Landscape Mini
# Works on both Debian and Alpine images
#
# Usage:
#   setup-mirror.sh              # Interactive: list available mirrors
#   setup-mirror.sh tuna         # Set Tsinghua TUNA mirror
#   setup-mirror.sh aliyun       # Set Alibaba Cloud mirror
#   setup-mirror.sh ustc         # Set USTC mirror
#   setup-mirror.sh huawei       # Set Huawei Cloud mirror
#   setup-mirror.sh reset        # Restore official mirrors
#   setup-mirror.sh show         # Show current mirror config

set -e

# ---- Mirror presets ----

mirror_url() {
    case "$1" in
        tuna)   echo "https://mirrors.tuna.tsinghua.edu.cn" ;;
        aliyun) echo "https://mirrors.aliyun.com" ;;
        ustc)   echo "https://mirrors.ustc.edu.cn" ;;
        huawei) echo "https://repo.huaweicloud.com" ;;
        *)      return 1 ;;
    esac
}

MIRROR_LIST="tuna aliyun ustc huawei"

# ---- Detect distro ----

detect_distro() {
    if [ -f /etc/apk/repositories ]; then
        echo "alpine"
    elif [ -f /etc/apt/sources.list ] || [ -d /etc/apt/sources.list.d ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# ---- Detect Debian release ----

detect_debian_release() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${VERSION_CODENAME:-trixie}"
    else
        echo "trixie"
    fi
}

# ---- Detect Alpine release ----

detect_alpine_release() {
    if [ -f /etc/alpine-release ]; then
        local ver
        ver=$(cat /etc/alpine-release)
        # e.g. 3.21.0 -> v3.21
        echo "v$(echo "$ver" | cut -d. -f1-2)"
    else
        echo "v3.21"
    fi
}

# ---- Backup config before overwriting ----

backup_config() {
    local file="$1"
    local bak="${file}.bak"
    if [ -f "$file" ]; then
        cp "$file" "$bak"
        echo "Backup saved to: $bak"
    fi
}

# ---- Show current config ----

show_current() {
    local distro
    distro=$(detect_distro)
    case "$distro" in
        debian)
            echo "System: Debian ($(detect_debian_release))"
            echo ""
            echo "/etc/apt/sources.list:"
            cat /etc/apt/sources.list
            if [ -f /etc/apt/sources.list.bak ]; then
                echo ""
                echo "Backup: /etc/apt/sources.list.bak"
            fi
            ;;
        alpine)
            echo "System: Alpine ($(detect_alpine_release))"
            echo ""
            echo "/etc/apk/repositories:"
            cat /etc/apk/repositories
            if [ -f /etc/apk/repositories.bak ]; then
                echo ""
                echo "Backup: /etc/apk/repositories.bak"
            fi
            ;;
        *)
            echo "Error: unknown system" >&2
            exit 1
            ;;
    esac
}

# ---- Apply mirror ----

apply_debian_mirror() {
    local mirror_base="$1"
    local release
    release=$(detect_debian_release)

    backup_config /etc/apt/sources.list
    echo "Updating /etc/apt/sources.list ..."
    cat > /etc/apt/sources.list <<EOF
deb ${mirror_base}/debian ${release} main contrib non-free non-free-firmware
deb ${mirror_base}/debian ${release}-updates main contrib non-free non-free-firmware
deb ${mirror_base}/debian ${release}-backports main contrib non-free non-free-firmware
EOF
    echo "Running apt update ..."
    apt update
}

apply_alpine_mirror() {
    local mirror_base="$1"
    local release
    release=$(detect_alpine_release)

    backup_config /etc/apk/repositories
    echo "Updating /etc/apk/repositories ..."
    cat > /etc/apk/repositories <<EOF
${mirror_base}/alpine/${release}/main
${mirror_base}/alpine/${release}/community
EOF
    echo "Running apk update ..."
    apk update
}

reset_debian_mirror() {
    local release
    release=$(detect_debian_release)

    backup_config /etc/apt/sources.list
    echo "Restoring official Debian mirrors ..."
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${release} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${release}-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${release}-backports main contrib non-free non-free-firmware
EOF
    echo "Running apt update ..."
    apt update
}

reset_alpine_mirror() {
    local release
    release=$(detect_alpine_release)

    backup_config /etc/apk/repositories
    echo "Restoring official Alpine mirrors ..."
    cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/${release}/main
https://dl-cdn.alpinelinux.org/alpine/${release}/community
EOF
    echo "Running apk update ..."
    apk update
}

# ---- Interactive menu ----

interactive_menu() {
    local distro
    distro=$(detect_distro)

    echo "Landscape Mini - Mirror Setup"
    echo "=============================="
    echo ""
    show_current
    echo ""
    echo "Available mirrors:"
    echo "  1) tuna    - Tsinghua TUNA    (mirrors.tuna.tsinghua.edu.cn)"
    echo "  2) aliyun  - Alibaba Cloud    (mirrors.aliyun.com)"
    echo "  3) ustc    - USTC             (mirrors.ustc.edu.cn)"
    echo "  4) huawei  - Huawei Cloud     (repo.huaweicloud.com)"
    echo "  5) reset   - Official mirror"
    echo "  0) exit    - Cancel"
    echo ""
    printf "Select mirror [1-5, 0 to cancel]: "
    read -r choice

    case "$choice" in
        1) apply_mirror "tuna"   "$distro" ;;
        2) apply_mirror "aliyun" "$distro" ;;
        3) apply_mirror "ustc"   "$distro" ;;
        4) apply_mirror "huawei" "$distro" ;;
        5) reset_mirror "$distro" ;;
        0) echo "Cancelled."; exit 0 ;;
        *) echo "Invalid choice."; exit 1 ;;
    esac
}

# ---- Dispatch ----

apply_mirror() {
    local name="$1"
    local distro="$2"
    local base_url

    base_url=$(mirror_url "$name") || {
        echo "Error: unknown mirror '$name'" >&2
        echo "Available: ${MIRROR_LIST} reset show" >&2
        exit 1
    }

    echo "Setting mirror to: $name ($base_url)"
    echo ""

    case "$distro" in
        debian) apply_debian_mirror "$base_url" ;;
        alpine) apply_alpine_mirror "$base_url" ;;
        *)      echo "Error: unknown system" >&2; exit 1 ;;
    esac

    echo ""
    echo "Done. Mirror set to: $name"
}

reset_mirror() {
    local distro="$1"
    case "$distro" in
        debian) reset_debian_mirror ;;
        alpine) reset_alpine_mirror ;;
        *)      echo "Error: unknown system" >&2; exit 1 ;;
    esac
    echo ""
    echo "Done. Restored to official mirrors."
}

# ---- Main ----

main() {
    local distro
    distro=$(detect_distro)

    if [ "$distro" = "unknown" ]; then
        echo "Error: cannot detect system type (neither Debian nor Alpine)" >&2
        exit 1
    fi

    case "${1:-}" in
        "")     interactive_menu ;;
        show)   show_current ;;
        reset)  reset_mirror "$distro" ;;
        -h|--help)
            echo "Usage: setup-mirror.sh [tuna|aliyun|ustc|huawei|reset|show]"
            echo ""
            echo "Switch package mirrors for Landscape Mini (Debian/Alpine)."
            echo ""
            echo "Mirrors:"
            echo "  tuna    Tsinghua TUNA    (mirrors.tuna.tsinghua.edu.cn)"
            echo "  aliyun  Alibaba Cloud    (mirrors.aliyun.com)"
            echo "  ustc    USTC             (mirrors.ustc.edu.cn)"
            echo "  huawei  Huawei Cloud     (repo.huaweicloud.com)"
            echo "  reset   Restore official mirrors"
            echo "  show    Show current config"
            ;;
        *)      apply_mirror "$1" "$distro" ;;
    esac
}

main "$@"
