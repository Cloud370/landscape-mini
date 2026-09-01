#!/bin/bash
# =============================================================================
# Landscape Mini - Shared Build Functions
# =============================================================================
# Sourced by build.sh. Provides common phases shared across all backends.
# Backend-specific functions (backend_*) are provided by lib/debian.sh or
# lib/alpine.sh.
# =============================================================================

# ---------------------------------------------------------------------------
# Cleanup trap - unmount everything and detach loop devices on exit/error
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "==== Cleanup: Unmounting and detaching ===="

    # Unmount in reverse order, ignoring errors
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

    # Detach loop device
    if [[ -n "${LOOP_DEV}" && -b "${LOOP_DEV}" ]]; then
        echo "  Detaching loop device ${LOOP_DEV}"
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi

    echo "  Cleanup complete."
}

# ---------------------------------------------------------------------------
# Helper: prepare build-time DNS inside chroot
# ---------------------------------------------------------------------------
configure_build_resolver() {
    echo "  Preparing build-time /etc/resolv.conf ..."
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
# Helper: run a command inside the chroot
# ---------------------------------------------------------------------------
run_in_chroot() {
    LANG=C.UTF-8 LC_ALL=C.UTF-8 chroot "${ROOTFS_DIR}" ${CHROOT_SHELL} -c "$1"
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
# Helper: run a command inside chroot with retries
# ---------------------------------------------------------------------------
run_in_chroot_retry() {
    local max_attempts="${1:-3}"
    local delay_seconds="${2:-5}"
    local script="$3"

    retry_command "${max_attempts}" "${delay_seconds}" \
        env LANG=C.UTF-8 LC_ALL=C.UTF-8 chroot "${ROOTFS_DIR}" ${CHROOT_SHELL} -c "set -e
${script}"
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

# ---------------------------------------------------------------------------
# Helper: mount special filesystems for chroot
# ---------------------------------------------------------------------------
mount_chroot_fs() {
    echo "  Mounting special filesystems for chroot ..."
    mount --bind /dev "${ROOTFS_DIR}/dev"
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
}

# ---------------------------------------------------------------------------
# Helper: unmount special filesystems
# ---------------------------------------------------------------------------
umount_chroot_fs() {
    echo "  Unmounting special filesystems ..."
    umount "${ROOTFS_DIR}/var/cache/apt/archives" 2>/dev/null || true
    umount "${ROOTFS_DIR}/etc/apk/cache" 2>/dev/null || true
    umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
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
# Phase 2: Create Disk Image
# =============================================================================
phase_create_image() {
    echo ""
    echo "==== Phase 2: Creating Disk Image ===="

    mkdir -p "${OUTPUT_DIR}" "${OUTPUT_METADATA_DIR}" "${ROOTFS_DIR}"

    # Create raw image (sparse file — no need to write 2GB of zeros)
    echo "  Creating ${IMAGE_SIZE_MB}MB raw image ..."
    truncate -s "${IMAGE_SIZE_MB}M" "${IMAGE_FILE}"

    # Partition with GPT: BIOS boot (1-2MiB) + ESP (2-202MiB) + root (202MiB - 100%)
    echo "  Partitioning (GPT: BIOS + UEFI hybrid) ..."
    parted -s "${IMAGE_FILE}" \
        mklabel gpt \
        mkpart bios 1MiB 2MiB \
        set 1 bios_grub on \
        mkpart ESP fat32 2MiB 202MiB \
        set 2 esp on \
        mkpart root ext4 202MiB 100%

    # Setup loop device
    echo "  Setting up loop device ..."
    LOOP_DEV=$(losetup --show -fP "${IMAGE_FILE}")
    echo "  Loop device: ${LOOP_DEV}"

    # Wait for partition devices to appear
    sleep 1
    partprobe "${LOOP_DEV}" 2>/dev/null || true
    sleep 1

    # Format partitions (partition 1 = BIOS boot, no filesystem needed)
    echo "  Formatting EFI partition (FAT32) ..."
    mkfs.vfat -F32 "${LOOP_DEV}p2"

    echo "  Formatting root partition (ext4, no journal, 1% reserved) ..."
    mkfs.ext4 -F -O ^has_journal -m 1 "${LOOP_DEV}p3"

    # Mount root
    echo "  Mounting root filesystem ..."
    mount "${LOOP_DEV}p3" "${ROOTFS_DIR}"

    # Mount EFI
    mkdir -p "${ROOTFS_DIR}/boot/efi"
    echo "  Mounting EFI partition ..."
    mount "${LOOP_DEV}p2" "${ROOTFS_DIR}/boot/efi"

    echo "  Phase 2 complete."
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
    run_in_chroot "
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
    run_in_chroot "ssh-keygen -A"

    # ---- Strip all binaries and shared libraries ----
    echo "  Stripping binaries and shared libraries ..."
    run_in_chroot "
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
        : > "${ROOTFS_DIR}/usr/lib/udev/hwdb.bin"
    fi

    # ---- General cleanup ----
    echo "  Cleaning caches and unnecessary files ..."
    run_in_chroot "
        rm -rf /usr/share/doc/*
        rm -rf /usr/share/man/*
        rm -rf /usr/share/info/*
        rm -rf /usr/share/lintian/*
        rm -rf /usr/share/bash-completion/*
        rm -rf /usr/share/common-licenses/*
        rm -f /var/log/*.log
        rm -rf /tmp/*
        rm -rf /var/tmp/*
    "

    # Unmount special filesystems
    umount_chroot_fs

    # Unmount EFI partition
    echo "  Unmounting EFI partition ..."
    umount "${ROOTFS_DIR}/boot/efi" 2>/dev/null || true

    # ---- Clean journal AFTER special fs unmounted ----
    echo "  Cleaning journal logs ..."
    rm -rf "${ROOTFS_DIR}/var/log/journal"

    # Unmount root BEFORE e2fsck/resize2fs
    echo "  Unmounting root filesystem ..."
    umount "${ROOTFS_DIR}" 2>/dev/null || true

    # Shrink the ext4 filesystem
    echo "  Running filesystem check ..."
    e2fsck -f -y "${LOOP_DEV}p3" || true

    echo "  Shrinking ext4 filesystem to minimum size ..."
    resize2fs -M "${LOOP_DEV}p3"

    # Get the actual filesystem size after shrink
    echo "  Calculating final image size ..."
    local ROOT_BLOCKS ROOT_BLOCKSIZE ROOT_BYTES
    ROOT_BLOCKS=$(dumpe2fs -h "${LOOP_DEV}p3" 2>/dev/null | grep "Block count:" | awk '{print $3}')
    ROOT_BLOCKSIZE=$(dumpe2fs -h "${LOOP_DEV}p3" 2>/dev/null | grep "Block size:" | awk '{print $3}')
    ROOT_BYTES=$(( ROOT_BLOCKS * ROOT_BLOCKSIZE ))

    # Detach loop device first (before modifying partition table)
    echo "  Detaching loop device ..."
    losetup -d "${LOOP_DEV}"
    LOOP_DEV=""

    # Partition 3 starts at sector 413696 (202MiB = 211812352 bytes / 512)
    local PART3_START_SECTOR=413696
    local ROOT_SECTORS=$(( ROOT_BYTES / 512 ))
    local PART3_END_SECTOR=$(( PART3_START_SECTOR + ROOT_SECTORS ))
    PART3_END_SECTOR=$(( ((PART3_END_SECTOR + 2047) / 2048) * 2048 - 1 ))
    local TOTAL_SECTORS=$(( PART3_END_SECTOR + 1 + 2048 ))
    local TOTAL_BYTES=$(( TOTAL_SECTORS * 512 ))

    # Save GRUB i386-pc boot code from MBR
    echo "  Saving GRUB MBR boot code ..."
    dd if="${IMAGE_FILE}" of="${IMAGE_FILE}.mbr" bs=440 count=1 2>/dev/null

    # Truncate the image to the new size
    echo "  Truncating image to $(( TOTAL_BYTES / 1048576 )) MB ..."
    truncate -s "${TOTAL_BYTES}" "${IMAGE_FILE}"

    # Wipe all GPT/MBR structures, then recreate clean GPT
    echo "  Rebuilding GPT partition table ..."
    sgdisk --zap-all "${IMAGE_FILE}" >/dev/null 2>&1
    sgdisk \
        -n 1:2048:4095 -t 1:EF02 -c 1:bios \
        -n 2:4096:413695 -t 2:EF00 -c 2:ESP \
        -n 3:${PART3_START_SECTOR}:${PART3_END_SECTOR} -t 3:8300 \
        "${IMAGE_FILE}"

    # Restore GRUB i386-pc boot code to MBR
    echo "  Restoring GRUB MBR boot code ..."
    dd if="${IMAGE_FILE}.mbr" of="${IMAGE_FILE}" bs=440 count=1 conv=notrunc 2>/dev/null
    rm -f "${IMAGE_FILE}.mbr"

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
# Helper: Re-attach existing image for resumed builds
# =============================================================================
resume_from_image() {
    if [[ ! -f "${IMAGE_FILE}" ]]; then
        echo "ERROR: Cannot skip to phase ${SKIP_TO_PHASE} - image file not found: ${IMAGE_FILE}"
        echo "Run a full build first, or skip to an earlier phase."
        exit 1
    fi
    echo "  Re-attaching existing image for phase ${SKIP_TO_PHASE} ..."
    LOOP_DEV=$(losetup --show -fP "${IMAGE_FILE}")
    sleep 1
    partprobe "${LOOP_DEV}" 2>/dev/null || true
    sleep 1
    mkdir -p "${ROOTFS_DIR}"
    mount "${LOOP_DEV}p3" "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}/boot/efi"
    mount "${LOOP_DEV}p2" "${ROOTFS_DIR}/boot/efi"
    mount_chroot_fs
}
