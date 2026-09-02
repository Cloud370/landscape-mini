#!/usr/bin/env bash
# Build environment self-check: reports which chroot engine the rootless
# build would pick on this machine and why, so you can tell a full-capable
# developer box from a confined sandbox before starting a build.
#
# Safe to run anywhere: read-only probes only, no packages, no builds.
# Exit codes: 0 = both Alpine and Debian are buildable rootless here
#            1 = at least one base system has no usable engine
set -u

line() { printf '  %-26s %s\n' "$1:" "$2"; }

echo "Build environment self-check / 构建环境自检"
echo "============================================================"

# --- Facts ---------------------------------------------------------------
os=$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
kernel=$(uname -r 2>/dev/null)
if [[ ${EUID} -eq 0 ]]; then
    priv="root (privileged)"
else
    priv="unprivileged user (uid=$(id -u))"
fi
line "OS" "${os:-unknown}"
line "Kernel" "${kernel:-unknown}"
line "Privileges" "${priv}"

nnp=$(awk '/^NoNewPrivs:/{print $2}' /proc/self/status 2>/dev/null)
if [[ "${nnp}" == "1" ]]; then
    line "NoNewPrivs" "1  (confined: setuid helpers such as newuidmap cannot elevate — sandbox-like environment)"
else
    line "NoNewPrivs" "0  (not confined)"
fi

# --- Probes (mirror lib/common.sh detection) ------------------------------
echo ""
echo "Probes / 探测:"

userns_basic=ok
if command -v unshare >/dev/null 2>&1 \
    && unshare --user --map-root-user --mount --pid --fork --propagation private true >/dev/null 2>&1; then
    line "user namespace" "OK (unshare --map-root-user)"
else
    userns_basic=missing
    line "user namespace" "UNAVAILABLE"
fi

userns_full=no
if [[ ${EUID} -eq 0 ]]; then
    userns_full=root
    line "subid-mapped namespace" "n/a as root (plain chroot is used)"
elif [[ "${userns_basic}" == "ok" ]] \
    && command -v newuidmap >/dev/null 2>&1 \
    && command -v newgidmap >/dev/null 2>&1 \
    && unshare --user --map-root-user --map-auto -- true >/dev/null 2>&1; then
    userns_full=yes
    line "subid-mapped namespace" "OK (uidmap + subid delegation — native-speed Debian chroot)"
else
    reason="delegation probe failed"
    if [[ "${nnp}" == "1" ]]; then
        reason="delegation probe failed (NoNewPrivs=1 blocks the setuid helper — confined environment)"
    fi
    if [[ "${userns_basic}" != "ok" ]]; then
        reason="no user namespaces"
    elif ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
        reason="newuidmap/newgidmap missing (sudo apt-get install uidmap)"
    elif ! grep -q "^$(id -un):" /etc/subgid 2>/dev/null && ! grep -q "^$(id -u):" /etc/subgid 2>/dev/null; then
        reason="no /etc/subgid entry for this user"
    fi
    line "subid-mapped namespace" "UNAVAILABLE (${reason})"
fi

proot_state=missing
if command -v proot >/dev/null 2>&1; then
    proot_state=installed
    line "proot" "installed (fallback engine; package phases run slower)"
else
    line "proot" "not installed"
fi

apparmor_restrict=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)
if [[ "${apparmor_restrict}" == "1" ]]; then
    line "apparmor userns policy" "restricted (Ubuntu 24.04+ default) — see hint below"
fi

# --- Engine verdict / 引擎判定 --------------------------------------------
echo ""
echo "Engine verdict for ./build.sh / 引擎判定:"

if [[ ${EUID} -eq 0 ]]; then
    echo "  root build: chroot (native)"
else
    if [[ "${userns_basic}" == "ok" ]]; then
        alpine_engine="unshare (native speed)"
    elif [[ "${proot_state}" == "installed" ]]; then
        alpine_engine="proot (slower)"
    else
        alpine_engine="NONE"
    fi
    if [[ "${userns_full}" == "yes" ]]; then
        debian_engine="unshare, subid-mapped (native speed)"
    elif [[ "${proot_state}" == "installed" ]]; then
        debian_engine="proot (slower; needs a working proot on this kernel)"
    else
        debian_engine="NONE"
    fi
    line "Alpine rootless" "${alpine_engine}"
    line "Debian rootless" "${debian_engine}"
fi

kvm=""
if [[ -w /dev/kvm ]]; then
    kvm=" /dev/kvm writable (fast e2e boots)"
else
    kvm=" no usable /dev/kvm (e2e boots use TCG emulation — slower)"
fi
line "QEMU acceleration" "${kvm# }"

# --- Hints / 提示 ----------------------------------------------------------
echo ""
echo "Hints / 提示:"
if [[ "${apparmor_restrict}" == "1" && "${userns_basic}" != "ok" ]]; then
    echo "  • Ubuntu 24.04+ confines unprivileged user namespaces behind AppArmor:"
    echo "      sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0"
fi
if [[ "${userns_full}" == "no" && "${userns_basic}" == "ok" ]]; then
    echo "  • For native-speed rootless Debian builds:"
    echo "      sudo apt-get install uidmap   # and a /etc/subgid line for your user"
    echo "    (Debian/Ubuntu grant human users a range by default; service accounts may lack it)"
fi
if [[ "${debian_engine:-}" == "NONE" || "${alpine_engine:-}" == "NONE" ]]; then
    echo "  • No usable rootless engine: install proot (fallback), enable user"
    echo "    namespaces, or run the build as root."
    exit 1
fi
echo "  • This check is read-only; run ./build.sh (or make build) to build for real."
exit 0
