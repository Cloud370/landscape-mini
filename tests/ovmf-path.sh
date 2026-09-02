#!/bin/sh
# Locate an OVMF/UEFI firmware image across distro layouts.
# Prints the first existing path; falls back to the classic Debian location.
# Used by the Makefile QEMU targets (tests/common.sh has its own copy).

for path in \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
    /usr/share/qemu/OVMF.fd \
    /usr/share/qemu/ovmf-x86_64.bin; do
    if [ -f "$path" ]; then
        printf '%s\n' "$path"
        exit 0
    fi
done

printf '%s\n' /usr/share/ovmf/OVMF.fd
