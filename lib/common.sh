#!/bin/bash
# =============================================================================
# Landscape Mini - Shared Build Functions
# =============================================================================
# Sourced by build.sh. Provides common phases shared across all backends.
# Backend-specific functions (backend_*) are provided by lib/debian.sh or
# lib/alpine.sh.
#
# The build never needs loop devices, partitions, or persistent mounts: the
# root filesystem is assembled in a plain directory and packed into the disk
# image offline (mke2fs -d / mtools / sgdisk on image files). Commands that
# must run inside the rootfs go through a chroot engine:
#   - chroot  : real root, classic chroot with mounted /proc /sys /dev
#   - unshare : rootless via `unshare --map-root-user --mount` (default)
#   - proot   : rootless fallback when user namespaces are unavailable
# =============================================================================

# ---------------------------------------------------------------------------
# Cleanup trap - unmount anything the chroot engine left behind
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "==== Cleanup ===="

    # Unmount in reverse order, ignoring errors (only the classic chroot
    # engine mounts anything outside a private namespace)
    for mp in \
        "${ROOTFS_DIR}/var/cache/apt/archives" \
        "${ROOTFS_DIR}/etc/apk/cache" \
        "${ROOTFS_DIR}/proc" \
        "${ROOTFS_DIR}/sys" \
        "${ROOTFS_DIR}/dev/pts" \
        "${ROOTFS_DIR}/dev" \
        "${ROOTFS_DIR}/boot/efi" \
        "${ROOTFS_DIR}"; do
        if mountpoint -q "${mp}" 2>/dev/null; then
            echo "  Unmounting ${mp}"
            umount -lf "${mp}" 2>/dev/null || true
        fi
    done

    echo "  Cleanup complete."
}

# ---------------------------------------------------------------------------
# Privilege / chroot engine detection
# ---------------------------------------------------------------------------
BUILD_PRIVILEGE="root"
CHROOT_ENGINE="chroot"

unshare_engine_functional() {
    command -v unshare >/dev/null 2>&1 || return 1
    # Mirror the flags run_rootfs_cmd actually uses so a kernel that allows
    # mount namespaces but denies PID namespaces fails here, not mid-build.
    unshare --user --map-root-user --mount --pid --fork --propagation private true >/dev/null 2>&1
}

# A plain --map-root-user namespace can only represent uid/gid 0, so dpkg
# chowns to system groups (shadow, crontab, utmp, ...) fail with EINVAL.
# With /etc/subuid + /etc/subgid delegation and the newuidmap/newgidmap
# setuid helpers (uidmap package), --map-auto adds the delegated ranges and
# every guest id below 65536 becomes representable — chroot then runs at
# native speed with no ownership faking. Cached because the probe forks.
USERNS_FULL_MAPPING=""
userns_full_mapping_available() {
    if [[ -z "${USERNS_FULL_MAPPING}" ]]; then
        if [[ ${EUID} -eq 0 ]]; then
            USERNS_FULL_MAPPING="yes"
        elif command -v newuidmap >/dev/null 2>&1 \
            && command -v newgidmap >/dev/null 2>&1 \
            && unshare --user --map-root-user --map-auto -- true >/dev/null 2>&1; then
            USERNS_FULL_MAPPING="yes"
        else
            USERNS_FULL_MAPPING="no"
        fi
    fi
    [[ "${USERNS_FULL_MAPPING}" == "yes" ]]
}

# Extra unshare flags that widen --map-root-user with the delegated subuid
# ranges. Both the chroot engine and mkfs must use the same view so that
# group ids recorded in the ext4 image match what dpkg set in the tree.
userns_map_args() {
    if [[ ${EUID} -ne 0 ]] && userns_full_mapping_available; then
        echo "--map-auto"
    fi
}

detect_build_environment() {
    if [[ ${EUID} -eq 0 ]]; then
        BUILD_PRIVILEGE="root"
    else
        BUILD_PRIVILEGE="rootless"
    fi

    local requested="${BUILD_CHROOT_ENGINE:-auto}"

    case "${BUILD_PRIVILEGE}:${requested}" in
        root:auto)
            CHROOT_ENGINE="chroot"
            ;;
        root:chroot)
            CHROOT_ENGINE="chroot"
            ;;
        root:unshare)
            CHROOT_ENGINE="unshare"
            ;;
        root:proot)
            echo "ERROR: BUILD_CHROOT_ENGINE=proot is pointless as root; use chroot or unshare." >&2
            return 1
            ;;
        rootless:chroot)
            echo "ERROR: BUILD_CHROOT_ENGINE=chroot requires running as root." >&2
            return 1
            ;;
        rootless:auto)
            if unshare_engine_functional; then
                CHROOT_ENGINE="unshare"
            elif command -v proot >/dev/null 2>&1; then
                CHROOT_ENGINE="proot"
                echo "[WARN] User namespaces unavailable; falling back to proot (slower)." >&2
            else
                echo "ERROR: This build is rootless but no chroot engine is available." >&2
                echo "  Either enable unprivileged user namespaces (kernel.apparmor_restrict_unprivileged_userns=0" >&2
                echo "  on Ubuntu 24.04+) or install proot." >&2
                return 1
            fi
            ;;
        rootless:unshare)
            if ! unshare_engine_functional; then
                echo "ERROR: BUILD_CHROOT_ENGINE=unshare requested but user namespaces are not functional." >&2
                return 1
            fi
            CHROOT_ENGINE="unshare"
            ;;
        rootless:proot)
            if ! command -v proot >/dev/null 2>&1; then
                echo "ERROR: BUILD_CHROOT_ENGINE=proot requested but proot is not installed." >&2
                return 1
            fi
            CHROOT_ENGINE="proot"
            ;;
        *)
            echo "ERROR: Invalid BUILD_CHROOT_ENGINE='${requested}' (auto|chroot|unshare|proot)." >&2
            return 1
            ;;
    esac

    # dpkg maintainer scripts and dpkg --unpack itself set group ownership
    # (e.g. setgid-shadow unix_chkpwd) that a plain --map-root-user user
    # namespace cannot represent — those chowns fail with EINVAL
    # mid-install. With subid delegation (uidmap + /etc/subgid) the
    # namespace maps every guest id and chroot stays native-speed; proot
    # (which fakes the chowns) is the fallback when that is unavailable.
    if [[ "${BUILD_PRIVILEGE}" == "rootless" && "${BASE_SYSTEM:-}" == "debian" \
          && "${CHROOT_ENGINE}" == "unshare" ]]; then
        if userns_full_mapping_available; then
            echo "[INFO] Debian rootless build: chroot runs in a subid-mapped user namespace (native speed)."
        elif command -v proot >/dev/null 2>&1; then
            CHROOT_ENGINE="proot"
            echo "[WARN] Debian rootless build: subid-mapped user namespace unavailable," >&2
            echo "  falling back to proot (noticeably slower package phases)." >&2
            [[ "${requested}" != "auto" ]] \
                && echo "  (your BUILD_CHROOT_ENGINE=${requested} cannot run dpkg here and was overridden.)" >&2
            echo "  For native speed: sudo apt-get install uidmap and make sure /etc/subgid" >&2
            echo "  has a delegated range for your user (default for human users on Debian/Ubuntu)." >&2
        else
            echo "ERROR: rootless Debian builds need either a subid-mapped user namespace or proot:" >&2
            echo "  dpkg sets group ownership (shadow/crontab/...) a plain user namespace cannot represent." >&2
            echo "  Debian/Ubuntu: sudo apt-get install uidmap proot" >&2
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Run a host-side command with root-equivalent filesystem semantics.
# Rootless builds use a user namespace so files created / chowned by the
# command land as the invoking user on disk but map to uid 0 inside the image.
# ---------------------------------------------------------------------------
# Host-side commands that need a root identity (debootstrap stage 1, apk,
# ...). Independent of the chroot engine: dpkg inside the tree may need
# proot, while host-side extraction works best in a plain user namespace
# (proot's syscall emulation breaks GNU tar's symlink chmod).
run_as_build_root() {
    if [[ "${BUILD_PRIVILEGE}" != "rootless" ]]; then
        "$@"
        return
    fi

    if [[ -z "${ROOT_EMULATOR:-}" ]]; then
        if unshare_engine_functional; then
            ROOT_EMULATOR="unshare"
        elif command -v proot >/dev/null 2>&1; then
            ROOT_EMULATOR="proot"
        else
            echo "ERROR: root emulation unavailable: need user namespaces or proot." >&2
            return 1
        fi
    fi

    case "${ROOT_EMULATOR}" in
        unshare)
            unshare --user --map-root-user --mount --propagation private -- "$@"
            ;;
        proot)
            # Fake root identity (debootstrap refuses plain users); chowns
            # are faked, nothing is actually elevated.
            PROOT_NO_SECCOMP=1 proot -0 "$@"
            ;;
    esac
}

# Commands that specifically need the builder uid mapped to 0 (mkfs -d
# recording filesystem ownership), regardless of the chroot engine. When a
# subid-mapped namespace is available it is preferred so tree files whose
# groups were set through delegated ranges pack with their real image gids.
run_uid_mapped() {
    if [[ "${BUILD_PRIVILEGE}" == "rootless" ]]; then
        # shellcheck disable=SC2046
        unshare --user --map-root-user $(userns_map_args) -- "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Engine-aware mount of the special filesystems for the classic chroot engine.
# unshare/proot engines set them up per invocation instead.
# ---------------------------------------------------------------------------
mount_chroot_fs() {
    [[ "${CHROOT_ENGINE}" == "chroot" ]] || return 0

    echo "  Mounting special filesystems for chroot ..."
    if ! mountpoint -q "${ROOTFS_DIR}/dev" 2>/dev/null; then
        mount --bind /dev "${ROOTFS_DIR}/dev"
    fi
    if ! mountpoint -q "${ROOTFS_DIR}/dev/pts" 2>/dev/null; then
        mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    fi
    if ! mountpoint -q "${ROOTFS_DIR}/proc" 2>/dev/null; then
        mount -t proc proc "${ROOTFS_DIR}/proc"
    fi
    if ! mountpoint -q "${ROOTFS_DIR}/sys" 2>/dev/null; then
        mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
    fi
}

# ---------------------------------------------------------------------------
# Helper: unmount special filesystems (classic chroot engine only)
# ---------------------------------------------------------------------------
umount_chroot_fs() {
    [[ "${CHROOT_ENGINE}" == "chroot" ]] || return 0

    echo "  Unmounting special filesystems ..."
    umount "${ROOTFS_DIR}/var/cache/apt/archives" 2>/dev/null || true
    umount "${ROOTFS_DIR}/etc/apk/cache" 2>/dev/null || true
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Run a command inside the rootfs through the active chroot engine
# ---------------------------------------------------------------------------
run_rootfs_cmd() {
    local script="$1"

    case "${CHROOT_ENGINE}" in
        chroot)
            chroot "${ROOTFS_DIR}" \
                /usr/bin/env -i \
                LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                "${CHROOT_SHELL}" -c "$1"
            ;;
        unshare)
            ROOTFS_ENGINE_ROOT="${ROOTFS_DIR}" \
            ROOTFS_ENGINE_SHELL="${CHROOT_SHELL}" \
            ROOTFS_ENGINE_SCRIPT="${script}" \
            unshare --user --map-root-user $(userns_map_args) \
                --mount --pid --fork --propagation private \
                /bin/bash -c '
                    set -e
                    # Prefer a fresh procfs for the private PID namespace; some
                    # container runtimes (e.g. nested Docker) deny creating a
                    # new proc instance even with --pid, so fall back to a
                    # recursive bind of the host /proc.
                    mount -t proc proc "$ROOTFS_ENGINE_ROOT/proc" 2>/dev/null \
                        || mount --rbind /proc "$ROOTFS_ENGINE_ROOT/proc"
                    mount --rbind /dev "$ROOTFS_ENGINE_ROOT/dev"
                    mount --make-rslave "$ROOTFS_ENGINE_ROOT/dev"
                    mount --rbind /sys "$ROOTFS_ENGINE_ROOT/sys"
                    mount --make-rslave "$ROOTFS_ENGINE_ROOT/sys"
                    exec chroot "$ROOTFS_ENGINE_ROOT" \
                        /usr/bin/env -i \
                        LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                        "$ROOTFS_ENGINE_SHELL" -c "$ROOTFS_ENGINE_SCRIPT"
                '
            ;;
        proot)
            # PROOT_NO_SECCOMP=1: proot's seccomp-accelerated syscall path
            # corrupts path translation on hosts with restrictive seccomp
            # filters (some sandboxes/CI); ptrace-only is slightly slower
            # but robust everywhere.
            PROOT_NO_SECCOMP=1 proot -R "${ROOTFS_DIR}" -w / -0 \
                /usr/bin/env -i \
                LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                "${CHROOT_SHELL}" -c "$1"
            ;;
    esac
}

# Backwards-compatible aliases for the pre-engine helper names
run_in_chroot() {
    run_rootfs_cmd "$1"
}

# ---------------------------------------------------------------------------
# Helper: prepare build-time DNS inside chroot
# ---------------------------------------------------------------------------
configure_build_resolver() {
    echo "  Preparing build-time /etc/resolv.conf ..."
    # The tree may not exist yet on the very first build (this runs before
    # bootstrap creates it).
    mkdir -p "${ROOTFS_DIR}/etc"
    rm -f "${ROOTFS_DIR}/etc/resolv.conf"

    if [[ -s /etc/resolv.conf ]]; then
        cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
    else
        echo "nameserver 1.1.1.1" > "${ROOTFS_DIR}/etc/resolv.conf"
    fi
}

# ---------------------------------------------------------------------------
# Helper: write image default DNS inside chroot
# ---------------------------------------------------------------------------
configure_image_resolver() {
    echo "  Writing image /etc/resolv.conf ..."
    rm -f "${ROOTFS_DIR}/etc/resolv.conf"
    echo "nameserver 1.1.1.1" > "${ROOTFS_DIR}/etc/resolv.conf"
}

# ---------------------------------------------------------------------------
# Helper: run a command inside the rootfs with retries
# ---------------------------------------------------------------------------
run_rootfs_cmd_retry() {
    local max_attempts="${1:-3}"
    local delay_seconds="${2:-5}"
    local script="$3"

    retry_command "${max_attempts}" "${delay_seconds}" \
        run_rootfs_cmd "set -e
${script}"
}

run_in_chroot_retry() {
    run_rootfs_cmd_retry "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Helper: retry transient network/package commands
# ---------------------------------------------------------------------------
retry_command() {
    local attempt
    local max_attempts="${1:-3}"
    local delay_seconds="${2:-5}"

    shift 2

    for attempt in $(seq 1 "${max_attempts}"); do
        if "$@"; then
            return 0
        fi
        if [[ "${attempt}" -eq "${max_attempts}" ]]; then
            echo "ERROR: Command failed after ${attempt} attempts: $*" >&2
            return 1
        fi
        echo "WARN: Command failed on attempt ${attempt}, retrying: $*" >&2
        sleep "${delay_seconds}"
    done
}

# ---------------------------------------------------------------------------
# Helper: measure URL download health and speed
# ---------------------------------------------------------------------------
probe_url() {
    local url="$1"
    local timeout_seconds="${2:-5}"
    local sample_bytes="${3:-5242880}"
    local output
    local curl_exit=0
    local http_code size_download speed_download

    output=$(curl -fsSLo /dev/null \
        --connect-timeout "${timeout_seconds}" \
        --max-time "${timeout_seconds}" \
        --range "0-$((sample_bytes - 1))" \
        --write-out '%{http_code} %{size_download} %{speed_download}' \
        "$url" 2>/dev/null) || curl_exit=$?

    if [[ "${curl_exit}" -ne 0 || -z "${output}" ]]; then
        return 1
    fi

    read -r http_code size_download speed_download <<< "${output}"
    if [[ "${http_code}" != "200" && "${http_code}" != "206" ]]; then
        return 1
    fi

    if ! awk "BEGIN {exit !(${size_download} > 0 && ${speed_download} > 0)}"; then
        return 1
    fi

    printf '%s\n' "${speed_download}"
}

# ---------------------------------------------------------------------------
# Helper: extract first package path from Debian-style Packages content
# ---------------------------------------------------------------------------
extract_debian_package_path() {
    awk '
        /^Filename: / && first == "" { first = $2 }
        END {
            if (first != "") {
                print first
            } else {
                exit 1
            }
        }
    '
}

# ---------------------------------------------------------------------------
# Helper: derive a representative Debian package URL from Packages index
# ---------------------------------------------------------------------------
derive_debian_package_url() {
    local candidate="$1"
    local packages_suffix="$2"
    local timeout_seconds="${3:-5}"
    local packages_url="${candidate%/}${packages_suffix}"
    local index_file
    local package_path

    index_file=$(mktemp)
    if ! curl -fsSL \
        --connect-timeout "${timeout_seconds}" \
        --max-time "$((timeout_seconds * 4))" \
        -o "${index_file}" \
        "$packages_url" 2>/dev/null; then
        rm -f "${index_file}"
        return 1
    fi

    package_path=$(xz -dc "${index_file}" 2>/dev/null | extract_debian_package_path)
    rm -f "${index_file}"

    if [[ -z "${package_path}" ]]; then
        return 1
    fi

    printf '%s/%s\n' "${candidate%/}" "${package_path#/}"
}

# ---------------------------------------------------------------------------
# Helper: derive a representative Alpine package URL from APKINDEX
# ---------------------------------------------------------------------------
derive_alpine_package_url() {
    local candidate="$1"
    local repo_prefix="$2"
    local timeout_seconds="${3:-5}"
    local index_url="${candidate%/}${repo_prefix}/APKINDEX.tar.gz"
    local index_file
    local package_file

    index_file=$(mktemp)
    if ! curl -fsSL \
        --connect-timeout "${timeout_seconds}" \
        --max-time "${timeout_seconds}" \
        -o "${index_file}" \
        "$index_url" 2>/dev/null; then
        rm -f "${index_file}"
        return 1
    fi

    package_file=$(tar -xOzf "${index_file}" 2>/dev/null | awk -F: '
        /^P:/ && pkg == "" { pkg=$2 }
        /^V:/ && ver == "" && pkg != "" { ver=$2 }
        END {
            if (pkg != "" && ver != "") {
                print pkg "-" ver ".apk"
            } else {
                exit 1
            }
        }
    ')
    rm -f "${index_file}"

    if [[ -z "${package_file}" ]]; then
        return 1
    fi

    printf '%s%s/%s\n' "${candidate%/}" "${repo_prefix}" "${package_file}"
}

# ---------------------------------------------------------------------------
# Helper: derive a representative Debian package URL from plain-text Packages index
# ---------------------------------------------------------------------------
derive_plain_debian_package_url() {
    local candidate="$1"
    local packages_suffix="$2"
    local timeout_seconds="${3:-5}"
    local packages_url="${candidate%/}${packages_suffix}"
    local index_file
    local package_path

    index_file=$(mktemp)
    if ! curl -fsSL \
        --connect-timeout "${timeout_seconds}" \
        --max-time "$((timeout_seconds * 4))" \
        -o "${index_file}" \
        "$packages_url" 2>/dev/null; then
        rm -f "${index_file}"
        return 1
    fi

    package_path=$(extract_debian_package_path < "${index_file}")
    rm -f "${index_file}"

    if [[ -z "${package_path}" ]]; then
        return 1
    fi

    printf '%s/%s\n' "${candidate%/}" "${package_path#/}"
}

# ---------------------------------------------------------------------------
# Helper: derive a representative direct URL
# ---------------------------------------------------------------------------
derive_direct_probe_url() {
    local candidate="$1"
    local probe_target="$2"

    printf '%s%s\n' "${candidate%/}" "${probe_target}"
}

# ---------------------------------------------------------------------------
# Helper: derive a representative probe URL for one candidate
# ---------------------------------------------------------------------------
derive_probe_url_for_candidate() {
    local candidate="$1"
    local probe_mode="$2"
    local probe_target="$3"
    local timeout_seconds="${4:-5}"

    case "${probe_mode}" in
        direct)
            derive_direct_probe_url "${candidate}" "${probe_target}"
            ;;
        debian-package)
            derive_debian_package_url "${candidate}" "${probe_target}" "${timeout_seconds}"
            ;;
        plain-debian-package)
            derive_plain_debian_package_url "${candidate}" "${probe_target}" "${timeout_seconds}"
            ;;
        alpine-package)
            derive_alpine_package_url "${candidate}" "${probe_target}" "${timeout_seconds}"
            ;;
        *)
            echo "ERROR: Unknown probe mode '${probe_mode}'." >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Helper: resolve LANDSCAPE_VERSION="latest" to a concrete release tag
# Sets RESOLVED_LANDSCAPE_VERSION (falls back to "latest" when resolution
# fails, e.g. no network to github.com yet).
# ---------------------------------------------------------------------------
resolve_landscape_release_version() {
    if [[ "${LANDSCAPE_VERSION:-}" != "latest" ]]; then
        RESOLVED_LANDSCAPE_VERSION="${LANDSCAPE_VERSION}"
        return 0
    fi

    local redirect_url tag
    if redirect_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' --max-time 30 \
        "${LANDSCAPE_REPO}/releases/latest" 2>/dev/null) \
        && tag="${redirect_url##*/}" \
        && [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RESOLVED_LANDSCAPE_VERSION="${tag}"
        echo "  Resolved landscape 'latest' to ${tag}."
    else
        RESOLVED_LANDSCAPE_VERSION="latest"
        echo "  [WARN] Could not resolve the 'latest' landscape release tag; keeping 'latest'." >&2
        echo "  [WARN] The init config version field will not be pinned; upstream may reject it." >&2
    fi
}

# ---------------------------------------------------------------------------
# Helper: pin the init config `version` field to the resolved landscape version
# Upstream (>= v0.19) requires this field to exactly match the webserver
# build version, otherwise the router refuses to start.
# ---------------------------------------------------------------------------
ensure_init_config_version() {
    local file_path="$1"

    if [[ "${RESOLVED_LANDSCAPE_VERSION:-latest}" == "latest" ]]; then
        echo "  [WARN] Landscape version unresolved; leaving init config version untouched: ${file_path}" >&2
        return 0
    fi

    local expected_version="${RESOLVED_LANDSCAPE_VERSION#v}"
    if grep -qE '^[[:space:]]*version[[:space:]]*=' "${file_path}"; then
        sed -i -E "s|^([[:space:]]*version[[:space:]]*=[[:space:]]*\").*(\"[[:space:]]*)\$|\1${expected_version}\2|" "${file_path}"
    else
        sed -i "1i version = \"${expected_version}\"" "${file_path}"
    fi
    echo "  Init config version pinned to ${expected_version}."
}

# ---------------------------------------------------------------------------
# Helper: guard against pinning a pre-v0.24 landscape binary together with a
# v0.24-schema init config. Pre-v0.24 binaries silently drop the
# static_nat_mappings_v4/v6 tables (DHCP/SSH/WUI port mappings lost), so fail
# the build for that combination and warn on other downgrade paths where
# compatibility cannot be verified.
# Returns 0 (compatible or warn-only), 1 on definite incompatibility.
# ---------------------------------------------------------------------------
check_init_config_schema_compat() {
    local config_file="$1"
    local pinned="${RESOLVED_LANDSCAPE_VERSION:-${LANDSCAPE_VERSION:-latest}}"
    pinned="${pinned#v}"

    local major minor
    if ! [[ "${pinned}" =~ ^([0-9]+)\.([0-9]+) ]]; then
        # "latest" or otherwise unparseable: nothing decisive to check.
        return 0
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    if (( major > 0 || minor >= 24 )); then
        return 0
    fi

    if grep -Eq '^[[:space:]]*\[\[?static_nat_mappings_v[46]' "${config_file}"; then
        echo "  [ERROR] LANDSCAPE_VERSION=${pinned} predates the v0.24 config schema, but ${config_file} uses static_nat_mappings_v4/v6 tables." >&2
        echo "          Pre-v0.24 binaries silently drop those tables, losing the DHCP/SSH/WUI port mappings." >&2
        echo "          Pin a v0.24+ release, or hand-migrate the config to the old [[static_nat_mappings]] format (see CLAUDE.md)." >&2
        return 1
    fi

    echo "  [WARN] LANDSCAPE_VERSION=v${pinned} predates the v0.24 config schema; make sure the init config matches that version's expected format." >&2
    return 0
}

# ---------------------------------------------------------------------------
# Helper: verify a cached/downloaded file against SHASUM256sum.txt
# Returns 0 (ok or skipped), 1 on mismatch.
# ---------------------------------------------------------------------------
verify_download_checksum() {
    local sums_file="$1"
    local file_path="$2"
    local asset_name="$3"
    local expected actual

    if [[ ! -f "${sums_file}" ]]; then
        echo "  [WARN] SHASUM256sum.txt unavailable; skipping checksum verification for ${asset_name}." >&2
        return 0
    fi

    expected=$(awk -v name="${asset_name}" '$2 == name {print $1; exit}' "${sums_file}")
    if [[ -z "${expected}" ]]; then
        echo "  [WARN] ${asset_name} not listed in SHASUM256sum.txt; skipping checksum verification." >&2
        return 0
    fi

    actual=$(sha256sum "${file_path}" | awk '{print $1}')
    if [[ "${actual}" != "${expected}" ]]; then
        echo "  [ERROR] Checksum mismatch for ${asset_name}: expected ${expected}, got ${actual}." >&2
        return 1
    fi

    echo "  [OK] ${asset_name} checksum verified."
    return 0
}

# ---------------------------------------------------------------------------
# Helper: probe candidates in configured order with preferred-source failover
# ---------------------------------------------------------------------------
select_preferred_source() {
    local source_name="$1"
    local candidates="$2"
    local probe_mode="$3"
    local probe_target="$4"
    local timeout_seconds="${5:-5}"
    local failover_timeout_seconds="${6:-120}"
    local sample_bytes="${7:-5242880}"
    local -a candidate_list=()
    local preferred_candidate=""
    local candidate representative_url measured_speed
    local start_ts now_ts elapsed

    for candidate in ${candidates}; do
        candidate_list+=("${candidate}")
    done

    if [[ ${#candidate_list[@]} -eq 0 ]]; then
        return 1
    fi

    preferred_candidate="${candidate_list[0]}"
    echo "  Preferring ${source_name}: ${preferred_candidate}" >&2
    start_ts=$(date +%s)

    while true; do
        representative_url=$(derive_probe_url_for_candidate "${preferred_candidate}" "${probe_mode}" "${probe_target}" "${timeout_seconds}") || representative_url=""

        if [[ -n "${representative_url}" ]]; then
            echo "  Probing ${source_name}: ${representative_url}" >&2
            if measured_speed=$(probe_url "${representative_url}" "${timeout_seconds}" "${sample_bytes}"); then
                echo "  [OK] ${source_name}: ${preferred_candidate} (${measured_speed} B/s)" >&2
                printf '%s\n' "${preferred_candidate}"
                return 0
            fi
        fi

        now_ts=$(date +%s)
        elapsed=$(( now_ts - start_ts ))
        if (( elapsed >= failover_timeout_seconds )); then
            break
        fi

        echo "  [WAIT] ${source_name}: ${preferred_candidate} is still unhealthy, retrying until ${failover_timeout_seconds}s before fallback" >&2
        sleep "${timeout_seconds}"
    done

    if (( ${#candidate_list[@]} == 1 )); then
        return 1
    fi

    echo "  [FALLBACK] ${source_name}: ${preferred_candidate} stayed unhealthy for ${failover_timeout_seconds}s, trying backup candidates in order" >&2

    for candidate in "${candidate_list[@]:1}"; do
        representative_url=$(derive_probe_url_for_candidate "${candidate}" "${probe_mode}" "${probe_target}" "${timeout_seconds}") || representative_url=""
        if [[ -z "${representative_url}" ]]; then
            echo "  [SKIP] ${source_name}: ${candidate}" >&2
            continue
        fi

        echo "  Probing ${source_name}: ${representative_url}" >&2
        if measured_speed=$(probe_url "${representative_url}" "${timeout_seconds}" "${sample_bytes}"); then
            echo "  [OK] ${source_name}: ${candidate} (${measured_speed} B/s)" >&2
            printf '%s\n' "${candidate}"
            return 0
        fi

        echo "  [SKIP] ${source_name}: ${candidate}" >&2
    done

    return 1
}

# ---------------------------------------------------------------------------
# Helper: resolve explicit or ordered-fallback source
# ---------------------------------------------------------------------------
resolve_source() {
    local source_name="$1"
    local explicit_value="$2"
    local candidates="$3"
    local probe_mode="$4"
    local probe_target="$5"
    local resolved_var_name="$6"
    local source_origin_var_name="$7"
    local timeout_seconds="${8:-5}"
    local failover_timeout_seconds="${9:-120}"
    local sample_bytes="${10:-5242880}"
    local resolved_value

    if [[ -n "${explicit_value}" ]]; then
        printf -v "${resolved_var_name}" '%s' "${explicit_value}"
        printf -v "${source_origin_var_name}" '%s' "explicit"
        echo "  Using explicit ${source_name}: ${explicit_value}"
        return 0
    fi

    if ! resolved_value=$(select_preferred_source "${source_name}" "${candidates}" "${probe_mode}" "${probe_target}" "${timeout_seconds}" "${failover_timeout_seconds}" "${sample_bytes}"); then
        echo "ERROR: No healthy ${source_name} candidates found." >&2
        return 1
    fi

    printf -v "${resolved_var_name}" '%s' "${resolved_value}"
    printf -v "${source_origin_var_name}" '%s' "probed"
    echo "  Selected ${source_name}: ${resolved_value}"
}

output_format_requested() {
    local requested="$1"
    local format
    for format in "${OUTPUT_FORMAT_LIST[@]}"; do
        if [[ "${format}" == "${requested}" ]]; then
            return 0
        fi
    done
    return 1
}

build_produced_files_manifest() {
    local artifact
    local manifest=()

    for artifact in "${IMAGE_FILE}" "${VMDK_FILE}" "${OVA_FILE}"; do
        if [[ -f "${artifact}" ]]; then
            manifest+=("$(basename "${artifact}")")
        fi
    done

    printf '%s\n' "$(IFS=,; echo "${manifest[*]}")"
}

write_local_build_metadata() {
    mkdir -p "${OUTPUT_METADATA_DIR}"

    local produced_files
    produced_files="$(build_produced_files_manifest)"

    if [[ -f "${RESOLVED_SOURCES_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${RESOLVED_SOURCES_FILE}"
    fi

    cat > "${BUILD_METADATA_FILE}" <<EOF
base_system=${BASE_SYSTEM}
include_docker=${INCLUDE_DOCKER}
output_formats=${OUTPUT_FORMATS}
run_test=${RUN_TEST:-none}
produced_files=${produced_files}
landscape_version=${LANDSCAPE_VERSION}
landscape_version_resolved=${RESOLVED_LANDSCAPE_VERSION:-${LANDSCAPE_VERSION}}
build_name=${BUILD_NAME}
image_file=$(basename "${IMAGE_FILE}")
config_profile=${EFFECTIVE_CONFIG_PROFILE}
topology_source=${EFFECTIVE_TOPOLOGY_SOURCE}
release_channel=${RELEASE_CHANNEL:-local}
release_tag=${RELEASE_TAG:-}
repository_owner=${REPOSITORY_OWNER:-}
build_privilege=${BUILD_PRIVILEGE}
chroot_engine=${CHROOT_ENGINE}
root_password_source=${ROOT_PASSWORD_SOURCE}
api_username_source=${LANDSCAPE_ADMIN_USER_SOURCE}
api_password_source=${LANDSCAPE_ADMIN_PASS_SOURCE}
api_username=${LANDSCAPE_ADMIN_USER}
resolved_apt_mirror=${resolved_apt_mirror:-${RESOLVED_APT_MIRROR:-unused}}
resolved_apt_mirror_source=${resolved_apt_mirror_source:-${RESOLVED_APT_MIRROR_SOURCE:-unused}}
resolved_alpine_mirror=${resolved_alpine_mirror:-${RESOLVED_ALPINE_MIRROR:-unused}}
resolved_alpine_mirror_source=${resolved_alpine_mirror_source:-${RESOLVED_ALPINE_MIRROR_SOURCE:-unused}}
resolved_docker_apt_mirror=${resolved_docker_apt_mirror:-${RESOLVED_DOCKER_APT_MIRROR:-unused}}
resolved_docker_apt_mirror_source=${resolved_docker_apt_mirror_source:-${RESOLVED_DOCKER_APT_MIRROR_SOURCE:-unused}}
resolved_docker_apt_gpg_url=${resolved_docker_apt_gpg_url:-${RESOLVED_DOCKER_APT_GPG_URL:-unused}}
resolved_docker_apt_gpg_url_source=${resolved_docker_apt_gpg_url_source:-${RESOLVED_DOCKER_APT_GPG_URL_SOURCE:-unused}}
timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

xml_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&apos;}"
    printf '%s' "${value}"
}

export_vmdk() {
    if [[ -f "${VMDK_FILE}" ]]; then
        echo "  [OK] VMDK already present: ${VMDK_FILE}"
        return 0
    fi

    echo "  Exporting VMDK ..."
    qemu-img convert -f raw -O vmdk "${IMAGE_FILE}" "${VMDK_FILE}"
    echo "  VMDK created: ${VMDK_FILE}"
}

export_ova() {
    local work_dir ovf_path mf_path stream_vmdk_path stream_vmdk_name
    local ovf_name mf_name
    local raw_size_bytes sectors_512 stream_vmdk_size_bytes ovf_disk_format
    local vm_name escaped_vm_name os_desc escaped_os_desc os_id cpu_cores memory_mb nic_model nic_desc

    if [[ -f "${OVA_FILE}" ]]; then
        echo "  [OK] OVA already present: ${OVA_FILE}"
        return 0
    fi

    echo "  Exporting OVA ..."

    work_dir=$(mktemp -d "${OUTPUT_DIR}/.ova-XXXXXX")
    ovf_name="${BUILD_NAME}.ovf"
    mf_name="${BUILD_NAME}.mf"
    stream_vmdk_name="${BUILD_NAME}.vmdk"
    ovf_path="${work_dir}/${ovf_name}"
    mf_path="${work_dir}/${mf_name}"
    stream_vmdk_path="${work_dir}/${stream_vmdk_name}"

    raw_size_bytes=$(stat -c '%s' "${IMAGE_FILE}")
    sectors_512=$(( raw_size_bytes / 512 ))
    cpu_cores=2
    memory_mb=2048
    nic_model="virtio"
    nic_desc="VirtIO ethernet adapter"

    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        os_id="101"
        os_desc="Alpine Linux 64-bit"
    else
        os_id="96"
        os_desc="Debian GNU/Linux 64-bit"
    fi

    if [[ "${INCLUDE_DOCKER}" == "true" ]]; then
        vm_name="${BUILD_NAME} (docker)"
    else
        vm_name="${BUILD_NAME}"
    fi

    escaped_vm_name=$(xml_escape "${vm_name}")
    escaped_os_desc=$(xml_escape "${os_desc}")
    ovf_disk_format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"

    qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "${IMAGE_FILE}" "${stream_vmdk_path}"
    stream_vmdk_size_bytes=$(stat -c '%s' "${stream_vmdk_path}")

    cat > "${ovf_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:cim="http://schemas.dmtf.org/wbem/wscim/1/common"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:id="file1" ovf:href="${stream_vmdk_name}" ovf:size="${stream_vmdk_size_bytes}"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:diskId="disk1"
          ovf:fileRef="file1"
          ovf:capacity="${sectors_512}"
          ovf:capacityAllocationUnits="byte * 512"
          ovf:format="${ovf_disk_format}"/>
  </DiskSection>
  <NetworkSection>
    <Info>Logical networks</Info>
    <Network ovf:name="bridged">
      <Description>Default bridged network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${escaped_vm_name}">
    <Info>A virtual machine</Info>
    <Name>${escaped_vm_name}</Name>
    <OperatingSystemSection ovf:id="${os_id}">
      <Info>Guest operating system</Info>
      <Description>${escaped_os_desc}</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${escaped_vm_name}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-14</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>${cpu_cores} virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>${cpu_cores}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>${memory_mb}MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>${memory_mb}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>SATA Controller</rasd:Description>
        <rasd:ElementName>sataController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>AHCI</rasd:ResourceSubType>
        <rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Description>Disk Drive</rasd:Description>
        <rasd:ElementName>disk1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/disk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>bridged</rasd:Connection>
        <rasd:Description>${nic_desc}</rasd:Description>
        <rasd:ElementName>ethernet0</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>${nic_model}</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

    (
        cd "${work_dir}"
        sha256sum "${ovf_name}" "${stream_vmdk_name}" | awk '{print "SHA256(" $2 ")= " $1}' > "${mf_name}"
        tar --format=ustar -cf "${OVA_FILE}" "${ovf_name}" "${stream_vmdk_name}" "${mf_name}"
    )

    rm -rf "${work_dir}"
    echo "  OVA created: ${OVA_FILE}"
}

# ---------------------------------------------------------------------------
# Helper: gzip-compress a file, using pigz when available
# ---------------------------------------------------------------------------
compress_file_gzip() {
    local file_path="$1"

    if command -v pigz >/dev/null 2>&1; then
        pigz -c "${file_path}" > "${file_path}.gz"
    else
        gzip -k -f "${file_path}"
    fi
}

# =============================================================================
# Phase 1: Download Landscape
# =============================================================================
phase_download() {
    echo ""
    echo "==== Phase 1: Downloading Landscape ===="

    mkdir -p "${DOWNLOAD_DIR}"

    # Use musl binary for Alpine, glibc binary for Debian
    local bin_suffix=""
    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        bin_suffix="-musl"
    fi
    local bin_name="landscape-webserver-x86_64${bin_suffix}"
    local bin_url="${DOWNLOAD_BASE}/${bin_name}"
    local bin_file="${DOWNLOAD_DIR}/${bin_name}"
    local static_url="${DOWNLOAD_BASE}/static.zip"
    local static_file="${DOWNLOAD_DIR}/static.zip"
    local sums_url="${DOWNLOAD_BASE}/SHASUM256sum.txt"
    local sums_file="${DOWNLOAD_DIR}/SHASUM256sum.txt"
    local tmp_file=""

    # Best-effort checksum manifest; downloaded first so cached assets can be
    # verified before reuse.
    if [[ ! -f "${sums_file}" ]]; then
        echo "  Fetching SHASUM256sum.txt ..."
        tmp_file="${sums_file}.part"
        if curl -fsSL --retry 3 --retry-delay 2 -o "${tmp_file}" "${sums_url}"; then
            mv "${tmp_file}" "${sums_file}"
        else
            rm -f "${tmp_file}"
            echo "  [WARN] Could not fetch SHASUM256sum.txt; downloads will be unverified." >&2
        fi
    else
        echo "  [OK] SHASUM256sum.txt already cached."
    fi

    if [[ -f "${bin_file}" ]] && verify_download_checksum "${sums_file}" "${bin_file}" "${bin_name}"; then
        echo "  [OK] ${bin_name} already downloaded (cache hit)."
    else
        rm -f "${bin_file}"
        echo "  [DOWNLOADING] ${bin_name} ..."
        tmp_file="${bin_file}.part"
        rm -f "${tmp_file}"
        curl -fL --retry 3 --retry-delay 2 -o "${tmp_file}" "${bin_url}"
        verify_download_checksum "${sums_file}" "${tmp_file}" "${bin_name}" || {
            rm -f "${tmp_file}"
            return 1
        }
        mv "${tmp_file}" "${bin_file}"
    fi
    chmod +x "${bin_file}"

    if [[ -f "${static_file}" ]]; then
        if ! unzip -tq "${static_file}" >/dev/null 2>&1 \
            || ! verify_download_checksum "${sums_file}" "${static_file}" "static.zip"; then
            echo "  [WARN] Cached static.zip is invalid, removing and re-downloading ..."
            rm -f "${static_file}"
        fi
    fi

    if [[ ! -f "${static_file}" ]]; then
        echo "  [DOWNLOADING] static.zip ..."
        tmp_file="${static_file}.part"
        rm -f "${tmp_file}"
        curl -fL --retry 3 --retry-delay 2 -o "${tmp_file}" "${static_url}"
        if ! unzip -tq "${tmp_file}" >/dev/null 2>&1; then
            rm -f "${tmp_file}"
            echo "  [ERROR] Downloaded static.zip is not a valid zip archive. Check LANDSCAPE_VERSION / DOWNLOAD_BASE."
            return 1
        fi
        verify_download_checksum "${sums_file}" "${tmp_file}" "static.zip" || {
            rm -f "${tmp_file}"
            return 1
        }
        mv "${tmp_file}" "${static_file}"
    fi

    echo "  Phase 1 complete."
}

# =============================================================================
# Phase 2: Prepare Workspace
# =============================================================================
# The disk image itself is assembled offline in Phase 7 from the rootfs
# directory; this phase only prepares directories and the persistent
# filesystem identity (UUIDs) used by fstab, initramfs, and grub.cfg.
# =============================================================================
IMAGE_LAYOUT_FILE=""

PART3_START_SECTOR=413696
ESP_START_SECTOR=4096
ESP_END_SECTOR=413695
BIOS_EMBED_START_SECTOR=2048
ESP_SIZE_MB=200

load_image_layout() {
    IMAGE_LAYOUT_FILE="${WORK_DIR}/image-layout.env"

    if [[ -f "${IMAGE_LAYOUT_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${IMAGE_LAYOUT_FILE}"
        return 0
    fi

    ROOT_UUID="$(cat /proc/sys/kernel/random/uuid)"
    local raw_serial
    raw_serial="$(cat /proc/sys/kernel/random/uuid)"
    raw_serial="${raw_serial//-/}"
    ESP_SERIAL="${raw_serial:0:8}"

    cat > "${IMAGE_LAYOUT_FILE}" <<EOF
ROOT_UUID=${ROOT_UUID}
ESP_SERIAL=${ESP_SERIAL}
EOF
    echo "  Generated new filesystem identity (ROOT_UUID=${ROOT_UUID})."
}

# FAT serial numbers are rendered by blkid/mount as UPPERCASE XXXX-XXXX;
# fstab UUID matching is case-sensitive, so the dash form must be uppercased.
esp_uuid_pretty() {
    local serial="${ESP_SERIAL}"
    echo "${serial:0:4}-${serial:4:4}" | tr 'a-f' 'A-F'
}

phase_create_image() {
    echo ""
    echo "==== Phase 2: Preparing Workspace ===="

    mkdir -p "${OUTPUT_DIR}" "${OUTPUT_METADATA_DIR}" "${ROOTFS_DIR}" "${WORK_DIR}"

    load_image_layout

    # Remove stale artifacts from earlier builds of this tree
    rm -f "${WORK_DIR}/rootfs.ext4" "${WORK_DIR}/esp.img"

    echo "  Phase 2 complete."
}

# ---------------------------------------------------------------------------
# Resume support: later phases operate on the persistent rootfs directory
# ---------------------------------------------------------------------------
require_rootfs_tree() {
    if [[ ! -d "${ROOTFS_DIR}/usr" ]]; then
        echo "ERROR: Cannot resume from phase ${SKIP_TO_PHASE} - no rootfs tree at ${ROOTFS_DIR}." >&2
        echo "Run a full build first (work/ persists the rootfs tree between phases)." >&2
        exit 1
    fi
    load_image_layout
    # Phase 3 recreates the tree from scratch; mounting the special
    # filesystems first would leave bootstrap's rm -rf hitting busy mounts
    # (chroot engine), so only resume paths that keep the tree mount them.
    if [[ ${SKIP_TO_PHASE} -ge 4 ]]; then
        mount_chroot_fs
    fi
}

# ---------------------------------------------------------------------------
# GRUB configuration rendering (host side, no chroot needed)
# ---------------------------------------------------------------------------
render_grub_cfg() {
    local kernel initrd cmdline
    kernel="$(backend_grub_kernel_path)"
    initrd="$(backend_grub_initrd_path)"
    cmdline="$(backend_grub_cmdline_extra)"

    if [[ -z "${kernel}" || -z "${initrd}" ]]; then
        echo "ERROR: Could not locate kernel/initrd under ${ROOTFS_DIR}/boot." >&2
        return 1
    fi

    mkdir -p "${ROOTFS_DIR}/boot/grub"
    cat > "${ROOTFS_DIR}/boot/grub/grub.cfg" <<EOF
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console
set default=0
set timeout=3

menuentry 'Landscape GNU/Linux' --class gnu-linux {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux ${kernel} root=UUID=${ROOT_UUID} ro ${cmdline}
    initrd ${initrd}
}
EOF
    echo "  grub.cfg rendered (kernel=${kernel})."
}

# ---------------------------------------------------------------------------
# Host GRUB module directories for BIOS core.img / EFI standalone binaries
# ---------------------------------------------------------------------------
grub_module_dir() {
    local platform="$1"
    local dir
    for dir in "/usr/lib/grub/${platform}" "/usr/lib/grub/${platform}-efi" "/usr/local/lib/grub/${platform}" "/opt/homebrew/lib/grub/${platform}" "/usr/home/linuxbrew/.linuxbrew/lib/grub/${platform}"; do
        if [[ -d "${dir}" ]]; then
            echo "${dir}"
            return 0
        fi
    done
    return 1
}

require_grub_modules() {
    if ! grub_module_dir i386-pc >/dev/null; then
        echo "ERROR: GRUB i386-pc modules not found (need /usr/lib/grub/i386-pc)." >&2
        echo "  Debian/Ubuntu: sudo apt-get install grub-pc-bin" >&2
        echo "  Fedora: sudo dnf install grub2-pc-modules" >&2
        echo "  Arch: sudo pacman -S grub" >&2
        return 1
    fi
    if ! grub_module_dir x86_64-efi >/dev/null; then
        echo "ERROR: GRUB x86_64-efi modules not found (need /usr/lib/grub/x86_64-efi)." >&2
        echo "  Debian/Ubuntu: sudo apt-get install grub-efi-amd64-bin" >&2
        echo "  Fedora: sudo dnf install grub2-efi-x64-modules" >&2
        echo "  Arch: sudo pacman -S grub" >&2
        return 1
    fi
}

check_core_deps() {
    local -a missing=()
    local cmd

    for cmd in mkfs.vfat mkfs.ext4 e2fsck resize2fs dumpe2fs sgdisk \
               mmd mcopy grub-mkimage grub-mkstandalone \
               curl unzip xz rsync truncate; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done

    case "${CHROOT_ENGINE}" in
        unshare)
            command -v unshare >/dev/null 2>&1 || missing+=(unshare)
            ;;
        proot)
            command -v proot >/dev/null 2>&1 || missing+=(proot)
            ;;
    esac

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Required commands not found: ${missing[*]}" >&2
        echo "" >&2
        echo "Install the build dependencies for your system:" >&2
        echo "  Debian/Ubuntu: sudo apt-get install debootstrap dosfstools e2fsprogs gdisk \\" >&2
        echo "      grub-efi-amd64-bin grub-pc-bin mtools rsync wget curl unzip xz-utils \\" >&2
        echo "      qemu-utils proot uidmap" >&2
        echo "  Fedora:         sudo dnf install debootstrap dosfstools e2fsprogs gdisk grub2-efi-x64-modules \\" >&2
        echo "      grub2-pc-modules mtools rsync curl unzip xz qemu-img" >&2
        echo "  Arch:           sudo pacman -S debootstrap dosfstools e2fsprogs gdisk grub mtools rsync curl unzip xz qemu-img" >&2
        echo "" >&2
        echo "Or run: make deps" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Build the EFI System Partition image (vfat, populated with mtools)
# ---------------------------------------------------------------------------
build_esp_image() {
    local esp_img="${WORK_DIR}/esp.img"
    local efi_staging standalone_dir

    echo "  Building EFI System Partition image ..."

    truncate -s "${ESP_SIZE_MB}M" "${esp_img}"
    # Serial is set deterministically so the fstab UUID=XXXX-XXXX stays stable
    mkfs.vfat -F 32 -n ESP -i "${ESP_SERIAL}" "${esp_img}" >/dev/null

    # Standalone EFI GRUB with an embedded early config that locates the
    # rootfs by UUID and loads the real grub.cfg from (root)/boot/grub.
    efi_staging="$(mktemp -d)"
    standalone_dir="${efi_staging}/standalone"
    mkdir -p "${standalone_dir}/boot/grub"

    cat > "${standalone_dir}/boot/grub/grub.cfg" <<EOF
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EOF

    (
        cd "${standalone_dir}"
        # The standalone binary must embed the linux loader itself: the image
        # ships no /boot/grub/<platform> module directory, so GRUB cannot
        # auto-load linux.mod at boot time.
        grub-mkstandalone \
            --directory="$(grub_module_dir x86_64-efi)" \
            -O x86_64-efi \
            -o "${efi_staging}/BOOTX64.EFI" \
            --modules="part_gpt part_msdos fat ext2 normal configfile echo ls search search_fs_uuid serial terminal test linux" \
            boot/grub/grub.cfg >/dev/null 2>"${efi_staging}/mkstandalone.err"
    ) || {
        echo "ERROR: grub-mkstandalone failed:" >&2
        cat "${efi_staging}/mkstandalone.err" >&2
        rm -rf "${efi_staging}"
        return 1
    }
    [[ -s "${efi_staging}/BOOTX64.EFI" ]] || {
        echo "ERROR: grub-mkstandalone produced no EFI binary:" >&2
        cat "${efi_staging}/mkstandalone.err" >&2
        rm -rf "${efi_staging}"
        return 1
    }
    rm -rf "${standalone_dir}"

    mmd -i "${esp_img}" ::/EFI ::/EFI/BOOT
    mcopy -i "${esp_img}" "${efi_staging}/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
    rm -rf "${efi_staging}"

    echo "  ESP image built: ${esp_img}"
}

# ---------------------------------------------------------------------------
# Pack the rootfs directory into a shrunk ext4 filesystem image
# ---------------------------------------------------------------------------
build_rootfs_ext4() {
    local rootfs_img="${WORK_DIR}/rootfs.ext4"
    local tree_bytes img_bytes

    echo "  Packing rootfs into ext4 image (offline, no mounting) ..."

    # Rootless trees cannot contain device nodes; the running system mounts
    # devtmpfs on /dev long before they could matter.
    if [[ "${BUILD_PRIVILEGE}" == "rootless" ]]; then
        find "${ROOTFS_DIR}" -xdev \( -type b -o -type c -o -type p \) -delete 2>/dev/null || true
    fi

    # Run du through the mapped namespace: apt drops privileges to _apt, so
    # cache dirs can be owned by a delegated id the plain builder cannot read.
    tree_bytes=$(run_uid_mapped du -s --apparent-size -B 1 "${ROOTFS_DIR}" | awk '{print $1}')
    img_bytes=$(( tree_bytes + tree_bytes / 8 + 67108864 ))

    rm -f "${rootfs_img}"
    truncate -s "${img_bytes}" "${rootfs_img}"

    run_uid_mapped mkfs.ext4 -q -F \
        -O ^has_journal -m 1 \
        -U "${ROOT_UUID}" \
        -d "${ROOTFS_DIR}" \
        "${rootfs_img}"

    echo "  Checking and shrinking ext4 image ..."
    e2fsck -f -y "${rootfs_img}" >/dev/null 2>&1 || true
    if ! resize2fs -M "${rootfs_img}" >/dev/null 2>&1; then
        echo "  [WARN] resize2fs -M failed; keeping the unshrunk image (larger file, still valid)." >&2
    fi

    local root_blocks root_blocksize
    root_blocks=$(dumpe2fs -h "${rootfs_img}" 2>/dev/null | awk '/^Block count:/{print $3}')
    root_blocksize=$(dumpe2fs -h "${rootfs_img}" 2>/dev/null | awk '/^Block size:/{print $3}')
    if [[ -z "${root_blocks}" || -z "${root_blocksize}" ]]; then
        echo "ERROR: could not read ext4 geometry from ${rootfs_img} (dumpe2fs)." >&2
        rm -rf "${esp_staging:-/nonexistent}" 2>/dev/null || true
        return 1
    fi
    ROOTFS_BYTES=$(( root_blocks * root_blocksize ))
    echo "  Rootfs ext4 image: $(( ROOTFS_BYTES / 1048576 )) MB (${root_blocks} blocks @ ${root_blocksize})."
}

# ---------------------------------------------------------------------------
# Embed BIOS GRUB (boot.img + core.img) directly into the image file.
# Mirrors what grub-bios-setup writes, without needing a block device:
#   - MBR sector 0: first 440 bytes of boot.img, with kernel_sector (offset
#     0x5c, 8 bytes LE) patched to the LBA of core.img
#   - BIOS-boot partition (sectors 2048..4095): core.img, with the diskboot
#     blocklist start (offset 0x1f4, 8 bytes LE) patched to LBA+1
# ---------------------------------------------------------------------------
write_le64_at() {
    local file="$1"
    local offset="$2"
    local value="$3"

    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((value & 0xff)) $(((value >> 8) & 0xff)) $(((value >> 16) & 0xff)) $(((value >> 24) & 0xff)) \
        $(((value >> 32) & 0xff)) $(((value >> 40) & 0xff)) $(((value >> 48) & 0xff)) $(((value >> 56) & 0xff)))" \
        | dd of="${file}" bs=1 seek="${offset}" conv=notrunc 2>/dev/null
}

install_grub_bios() {
    local image_file="$1"
    local grub_tmp core_img boot_img core_sectors

    grub_tmp="$(mktemp -d)"
    core_img="${grub_tmp}/core.img"

    grub-mkimage \
        --directory="$(grub_module_dir i386-pc)" \
        -O i386-pc \
        -o "${core_img}" \
        -p '(,gpt3)/boot/grub' \
        biosdisk part_gpt part_msdos ext2 fat normal configfile \
        echo ls search search_fs_uuid serial terminal test linux \
        >/dev/null 2>&1
    if [[ ! -s "${core_img}" ]]; then
        echo "ERROR: grub-mkimage failed to produce a BIOS core.img." >&2
        rm -rf "${grub_tmp}"
        return 1
    fi

    core_sectors=$(( ( $(stat -c '%s' "${core_img}") + 511 ) / 512 ))
    if (( core_sectors > ESP_START_SECTOR - BIOS_EMBED_START_SECTOR )); then
        echo "ERROR: GRUB core.img (${core_sectors} sectors) exceeds the BIOS embed area." >&2
        rm -rf "${grub_tmp}"
        return 1
    fi

    # Patch the diskboot blocklist start (last sector's trailing entry)
    write_le64_at "${core_img}" 500 $(( BIOS_EMBED_START_SECTOR + 1 ))

    dd if="${core_img}" of="${image_file}" bs=512 seek="${BIOS_EMBED_START_SECTOR}" conv=notrunc 2>/dev/null

    boot_img="${grub_tmp}/boot.img"
    cp "$(grub_module_dir i386-pc)/boot.img" "${boot_img}"
    write_le64_at "${boot_img}" 92 "${BIOS_EMBED_START_SECTOR}"
    dd if="${boot_img}" of="${image_file}" bs=440 count=1 conv=notrunc 2>/dev/null

    rm -rf "${grub_tmp}"
    echo "  BIOS GRUB embedded (core.img: ${core_sectors} sectors @ LBA ${BIOS_EMBED_START_SECTOR})."
}

# ---------------------------------------------------------------------------
# Assemble the final GPT disk image from the offline filesystem images
# ---------------------------------------------------------------------------
assemble_disk_image() {
    local rootfs_img="${WORK_DIR}/rootfs.ext4"
    local esp_img="${WORK_DIR}/esp.img"
    local root_sectors part3_end_sector total_sectors total_bytes

    echo "  Assembling final disk image ..."

    root_sectors=$(( ( ROOTFS_BYTES + 511 ) / 512 ))
    part3_end_sector=$(( PART3_START_SECTOR + root_sectors ))
    part3_end_sector=$(( ((part3_end_sector + 2047) / 2048) * 2048 - 1 ))
    total_sectors=$(( part3_end_sector + 1 + 2048 ))
    total_bytes=$(( total_sectors * 512 ))

    truncate -s "${total_bytes}" "${IMAGE_FILE}"

    sgdisk --zap-all "${IMAGE_FILE}" >/dev/null 2>&1
    sgdisk \
        -n 1:${BIOS_EMBED_START_SECTOR}:$(( ESP_START_SECTOR - 1 )) -t 1:EF02 -c 1:bios \
        -n 2:${ESP_START_SECTOR}:${ESP_END_SECTOR} -t 2:EF00 -c 2:ESP \
        -n 3:${PART3_START_SECTOR}:${part3_end_sector} -t 3:8300 -c 3:root \
        "${IMAGE_FILE}" >/dev/null

    dd if="${rootfs_img}" of="${IMAGE_FILE}" bs=512 seek="${PART3_START_SECTOR}" conv=notrunc 2>/dev/null
    dd if="${esp_img}" of="${IMAGE_FILE}" bs=512 seek="${ESP_START_SECTOR}" conv=notrunc 2>/dev/null

    install_grub_bios "${IMAGE_FILE}"

    rm -f "${rootfs_img}" "${esp_img}"

    echo "  Disk image assembled: ${IMAGE_FILE} ($(( total_bytes / 1048576 )) MB)."
}

# =============================================================================
# Phase 5: Install Landscape Router (shared parts)
# =============================================================================
phase_install_landscape() {
    echo ""
    echo "==== Phase 5: Installing Landscape Router ===="

    # Copy the landscape binary (musl for Alpine, glibc for Debian)
    local bin_suffix=""
    if [[ "${BASE_SYSTEM}" == "alpine" ]]; then
        bin_suffix="-musl"
    fi
    echo "  Installing landscape-webserver binary ..."
    cp "${DOWNLOAD_DIR}/landscape-webserver-x86_64${bin_suffix}" "${ROOTFS_DIR}/root/landscape-webserver"
    chmod +x "${ROOTFS_DIR}/root/landscape-webserver"

    # Copy and extract static web assets
    echo "  Installing static web assets ..."
    mkdir -p "${ROOTFS_DIR}/root/.landscape-router"
    if ! unzip -tq "${DOWNLOAD_DIR}/static.zip" >/dev/null 2>&1; then
        echo "  [ERROR] Cached static.zip is invalid. Re-run phase_download with a valid LANDSCAPE_VERSION."
        return 1
    fi
    cp "${DOWNLOAD_DIR}/static.zip" "${ROOTFS_DIR}/root/.landscape-router/static.zip"
    unzip -o "${ROOTFS_DIR}/root/.landscape-router/static.zip" -d "${ROOTFS_DIR}/root/.landscape-router/"
    rm -f "${ROOTFS_DIR}/root/.landscape-router/static.zip"

    # Copy effective landscape_init.toml when available, otherwise fall back to repo default.
    local landscape_init_source="${EFFECTIVE_CONFIG_PATH:-${SCRIPT_DIR}/configs/landscape_init.toml}"
    if [[ -f "${landscape_init_source}" ]]; then
        echo "  Installing landscape_init.toml from ${landscape_init_source} ..."
        # Stage a copy under the metadata dir so inputs (repo template or a
        # user-provided config) are never modified in place, and local builds
        # also ship the effective config artifact.
        local staged_init="${OUTPUT_METADATA_DIR}/effective-landscape_init.toml"
        mkdir -p "${OUTPUT_METADATA_DIR}"
        if [[ "$(realpath -m "${landscape_init_source}")" != "$(realpath -m "${staged_init}")" ]]; then
            cp "${landscape_init_source}" "${staged_init}"
        fi
        ensure_init_config_version "${staged_init}"
        if ! check_init_config_schema_compat "${staged_init}"; then
            return 1
        fi
        cp "${staged_init}" "${ROOTFS_DIR}/root/.landscape-router/landscape_init.toml"
    else
        echo "  [SKIP] No landscape_init.toml found (will use --auto mode)."
    fi

    # Copy sysctl config
    if [[ -f "${SCRIPT_DIR}/rootfs/etc/sysctl.d/99-landscape.conf" ]]; then
        echo "  Installing sysctl config ..."
        mkdir -p "${ROOTFS_DIR}/etc/sysctl.d"
        cp "${SCRIPT_DIR}/rootfs/etc/sysctl.d/99-landscape.conf" \
            "${ROOTFS_DIR}/etc/sysctl.d/99-landscape.conf"
    else
        echo "  [SKIP] No rootfs/etc/sysctl.d/99-landscape.conf found."
    fi

    # Copy build runtime environment for non-topology settings.
    echo "  Writing runtime environment ..."
    mkdir -p "${ROOTFS_DIR}/etc/landscape"
    cat > "${ROOTFS_DIR}/etc/landscape/runtime.env" <<EOF
LANDSCAPE_ADMIN_USER=${LANDSCAPE_ADMIN_USER}
LANDSCAPE_ADMIN_PASS=${LANDSCAPE_ADMIN_PASS}
EOF
    chmod 600 "${ROOTFS_DIR}/etc/landscape/runtime.env"

    # Install login welcome script
    if [[ -f "${SCRIPT_DIR}/rootfs/etc/profile.d/welcome.sh" ]]; then
        echo "  Installing login welcome script ..."
        mkdir -p "${ROOTFS_DIR}/etc/profile.d"
        cp "${SCRIPT_DIR}/rootfs/etc/profile.d/welcome.sh" \
            "${ROOTFS_DIR}/etc/profile.d/welcome.sh"
        chmod +x "${ROOTFS_DIR}/etc/profile.d/welcome.sh"
    fi

    # Install expand-rootfs script
    echo "  Installing expand-rootfs script ..."
    mkdir -p "${ROOTFS_DIR}/usr/local/bin"
    cp "${SCRIPT_DIR}/rootfs/usr/local/bin/expand-rootfs.sh" \
        "${ROOTFS_DIR}/usr/local/bin/expand-rootfs.sh"
    chmod +x "${ROOTFS_DIR}/usr/local/bin/expand-rootfs.sh"

    # Install mirror setup script
    echo "  Installing setup-mirror script ..."
    cp "${SCRIPT_DIR}/rootfs/usr/local/bin/setup-mirror.sh" \
        "${ROOTFS_DIR}/usr/local/bin/setup-mirror.sh"
    chmod +x "${ROOTFS_DIR}/usr/local/bin/setup-mirror.sh"

    # Backend-specific: install init services (systemd or OpenRC)
    backend_install_landscape_services

    echo "  Phase 5 complete."
}

# =============================================================================
# Phase 7: Cleanup, Shrink, and Export
# =============================================================================
phase_cleanup_and_shrink() {
    echo ""
    echo "==== Phase 7: Cleanup, Shrink, and Export ===="

    # ---- Strip landscape binary ----
    echo "  Stripping landscape-webserver binary ..."
    if [[ -f "${ROOTFS_DIR}/root/landscape-webserver" ]]; then
        local BEFORE_SIZE AFTER_SIZE
        BEFORE_SIZE=$(stat -c%s "${ROOTFS_DIR}/root/landscape-webserver")
        strip --strip-unneeded "${ROOTFS_DIR}/root/landscape-webserver" 2>/dev/null || true
        AFTER_SIZE=$(stat -c%s "${ROOTFS_DIR}/root/landscape-webserver")
        echo "    Binary: $((BEFORE_SIZE/1024/1024))M -> $((AFTER_SIZE/1024/1024))M"
    fi

    # ---- Remove unneeded kernel modules ----
    echo "  Removing unneeded kernel modules ..."
    run_rootfs_cmd "
        KDIR=\$(ls -d /usr/lib/modules/*/kernel 2>/dev/null | head -1)
        if [ -z \"\$KDIR\" ]; then
            KDIR=\$(ls -d /lib/modules/*/kernel 2>/dev/null | head -1)
        fi
        if [ -n \"\$KDIR\" ]; then
            rm -rf \"\$KDIR/sound\"

            for d in media gpu infiniband iio comedi staging hid input video \
                     bluetooth usb platform md mtd misc target \
                     accel mmc isdn edac crypto \
                     nfc firewire thunderbolt ufs atm vfio \
                     leds vdpa ntb dma accessibility gpio pinctrl pcmcia \
                     spi memstick power soundwire ssb parport uio \
                     nvdimm rpmsg bcma auxdisplay cdrom mfd gnss mux \
                     pwm powercap soc regulator extcon dax devfreq; do
                rm -rf \"\$KDIR/drivers/\$d\"
            done

            # Keep full wired NIC driver coverage and adjacent support modules.
            # Hardware NIC compatibility takes priority over image size trimming.


            for d in bluetooth mac80211 wireless sunrpc ceph tipc nfc rxrpc smc sctp \
                     atm dccp ieee802154 mac802154 6lowpan 9p openvswitch \
                     rds l2tp phonet can x25 appletalk rfkill lapb nsh; do
                rm -rf \"\$KDIR/net/\$d\"
            done

            for d in bcachefs btrfs xfs ocfs2 f2fs jfs reiserfs gfs2 nilfs2 orangefs coda \
                     smb nfs nfsd ceph ubifs afs ntfs3 dlm jffs2 udf netfs \
                     hfsplus hfs hpfs exfat ufs ext2 ecryptfs squashfs sysv minix \
                     isofs vboxsf omfs efs romfs nfs_common lockd cachefiles 9p; do
                rm -rf \"\$KDIR/fs/\$d\"
            done

            MODDIR=\$(ls -d /usr/lib/modules/*/ 2>/dev/null | head -1)
            if [ -z \"\$MODDIR\" ]; then
                MODDIR=\$(ls -d /lib/modules/*/ 2>/dev/null | head -1)
            fi
            if [ -n \"\$MODDIR\" ]; then
                KVER=\$(basename \"\$MODDIR\")
                depmod \"\$KVER\" 2>/dev/null || true
            fi
        fi
    "

    # ---- Clean GRUB leftovers ----
    echo "  Cleaning GRUB locale and modules ..."
    rm -rf "${ROOTFS_DIR}/boot/grub/locale"
    rm -rf "${ROOTFS_DIR}/usr/lib/grub"

    # ---- Generate SSH host keys ----
    echo "  Generating SSH host keys ..."
    run_rootfs_cmd "ssh-keygen -A"

    # ---- Strip all binaries and shared libraries ----
    echo "  Stripping binaries and shared libraries ..."
    run_rootfs_cmd "
        find /usr/bin /usr/sbin /usr/lib -type f \
            \( -name '*.so*' -o -executable \) \
            -exec strip --strip-unneeded {} + 2>/dev/null || true
    "

    # ---- Backend-specific cleanup (apt/apk, initramfs, locale) ----
    backend_cleanup

    # ---- Truncate udev hwdb ----
    echo "  Truncating udev hardware database ..."
    rm -rf "${ROOTFS_DIR}/usr/lib/udev/hwdb.d" 2>/dev/null || true
    if [[ -f "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin" ]]; then
        # systemd-hwdb leaves the database read-only (444); root silently
        # bypasses that, a normal builder needs the write bit restored first.
        chmod u+w "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin" 2>/dev/null || true
        if ! : > "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin" 2>/dev/null; then
            echo "  [WARN] could not truncate hwdb.bin; image keeps the full database" >&2
        fi
    fi

    # ---- General cleanup ----
    echo "  Cleaning caches and unnecessary files ..."
    run_rootfs_cmd "
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/lintian/*
        rm -rf /usr/share/bash-completion/*
        rm -rf /usr/share/common-licenses/*
        rm -f /var/log/*.log
        rm -rf /tmp/*
        rm -rf /var/tmp/*
        rm -rf /var/log/journal
    "

    # ---- Unmount special filesystems (classic chroot engine only) ----
    umount_chroot_fs

    # ---- Render final grub.cfg ----
    render_grub_cfg

    # ---- Assemble the offline disk image ----
    require_grub_modules
    build_rootfs_ext4
    build_esp_image
    assemble_disk_image

    output_format_requested vmdk && export_vmdk
    output_format_requested ova && export_ova

    if [[ "${COMPRESS_OUTPUT}" == "yes" ]]; then
        echo "  Compressing raw image with gzip ..."
        compress_file_gzip "${IMAGE_FILE}"
        echo "  Compressed: ${IMAGE_FILE}.gz"

        if [[ -f "${VMDK_FILE}" ]]; then
            echo "  Compressing VMDK image with gzip ..."
            compress_file_gzip "${VMDK_FILE}"
            echo "  Compressed: ${VMDK_FILE}.gz"
        fi
    fi

    write_local_build_metadata

    echo "  Phase 7 complete."
}

# =============================================================================
# Phase 8: Report
# =============================================================================
phase_report() {
    echo ""
    echo "==== Phase 8: Build Complete ===="
    echo ""
    echo "Output files:"
    echo "------------------------------------------------------------"

    if [[ -f "${IMAGE_FILE}" ]]; then
        local IMG_SIZE
        IMG_SIZE=$(du -h "${IMAGE_FILE}" | awk '{print $1}')
        echo "  RAW image : ${IMAGE_FILE} (${IMG_SIZE})"
    fi

    if [[ -f "${IMAGE_FILE}.gz" ]]; then
        local IMG_GZ_SIZE
        IMG_GZ_SIZE=$(du -h "${IMAGE_FILE}.gz" | awk '{print $1}')
        echo "  Compressed: ${IMAGE_FILE}.gz (${IMG_GZ_SIZE})"
    fi

    if [[ -f "${VMDK_FILE}" ]]; then
        local VMDK_SIZE
        VMDK_SIZE=$(du -h "${VMDK_FILE}" | awk '{print $1}')
        echo "  VMDK image: ${VMDK_FILE} (${VMDK_SIZE})"
    fi

    if [[ -f "${VMDK_FILE}.gz" ]]; then
        local VMDK_GZ_SIZE
        VMDK_GZ_SIZE=$(du -h "${VMDK_FILE}.gz" | awk '{print $1}')
        echo "  Compressed: ${VMDK_FILE}.gz (${VMDK_GZ_SIZE})"
    fi

    if [[ -f "${OVA_FILE}" ]]; then
        local OVA_SIZE
        OVA_SIZE=$(du -h "${OVA_FILE}" | awk '{print $1}')
        echo "  OVA image : ${OVA_FILE} (${OVA_SIZE})"
    fi

    if [[ -f "${BUILD_METADATA_FILE}" ]]; then
        echo "  Metadata  : ${BUILD_METADATA_FILE}"
    fi

    echo ""
    echo "To write the raw image to a disk:"
    echo "  dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "To boot in QEMU:"
    echo "  qemu-system-x86_64 -enable-kvm -m 512 -bios /usr/share/ovmf/OVMF.fd ..."
    echo "    -drive file=${IMAGE_FILE},format=raw -nic user,hostfwd=tcp::2222-:22"
    echo ""
    echo "Default credentials:  root / ${ROOT_PASSWORD}  |  ld / ${ROOT_PASSWORD}"
    echo "============================================================"
}

# =============================================================================
# Helper: Validate rootfs tree for resumed builds (mounts handled by engine)
# =============================================================================
