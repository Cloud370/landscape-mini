# =============================================================================
# Landscape Mini - Local Development & Debugging Makefile
# =============================================================================
#
# Builds a minimal x86 UEFI image for the Landscape Router using debootstrap.
# The main build script (build.sh) requires root/sudo.
#
# Usage:
#   make              - Show all available targets
#   make build        - Full build (without Docker)
#   make test         - Boot image in QEMU (headless, serial console)
#   make test-gui     - Boot image in QEMU (with VGA display)
#
# Default credentials:  root / landscape  |  ld / landscape
# =============================================================================

.PHONY: help deps build build-docker test test-gui ssh clean distclean status

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

IMAGE       := output/landscape-mini-x86.img
OVMF        := /usr/share/ovmf/OVMF.fd
SSH_PORT    := 2222
WEB_PORT    := 9800
QEMU_MEM    := 1024
QEMU_SMP    := 2

# --------------------------------------------------------------------------
# Default target
# --------------------------------------------------------------------------

help: ## Show all available targets with descriptions
	@echo ""
	@echo "Landscape Mini - Development Makefile"
	@echo "======================================"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Image:   $(IMAGE)"
	@echo "SSH:     ssh -p $(SSH_PORT) root@localhost"
	@echo "Web UI:  http://localhost:$(WEB_PORT)"
	@echo ""

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------

deps: ## Install all host dependencies needed for building
	sudo apt-get update
	sudo apt-get install -y debootstrap parted dosfstools e2fsprogs \
		grub-efi-amd64-bin grub-pc-bin qemu-utils qemu-system-x86 ovmf \
		rsync curl gdisk unzip

# --------------------------------------------------------------------------
# Build targets
# --------------------------------------------------------------------------

build: ## Full build without Docker (requires sudo)
	sudo ./build.sh

build-docker: ## Full build with Docker included (requires sudo)
	sudo ./build.sh --with-docker

# --------------------------------------------------------------------------
# QEMU test targets
# --------------------------------------------------------------------------

test: $(IMAGE) ## Boot image in QEMU (headless, serial console on stdio)
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios $(OVMF) \
		-drive file=$(IMAGE),format=raw,if=virtio \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=wan,hostfwd=tcp::$(SSH_PORT)-:22,hostfwd=tcp::$(WEB_PORT)-:9800 \
		-device virtio-net-pci,netdev=lan \
		-netdev user,id=lan \
		-display none \
		-serial mon:stdio

test-gui: $(IMAGE) ## Boot image in QEMU (with VGA display window)
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios $(OVMF) \
		-drive file=$(IMAGE),format=raw,if=virtio \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=wan,hostfwd=tcp::$(SSH_PORT)-:22,hostfwd=tcp::$(WEB_PORT)-:9800 \
		-device virtio-net-pci,netdev=lan \
		-netdev user,id=lan

# --------------------------------------------------------------------------
# Remote access
# --------------------------------------------------------------------------

ssh: ## SSH into the running QEMU instance
	ssh -o StrictHostKeyChecking=no -p $(SSH_PORT) root@localhost

# --------------------------------------------------------------------------
# Cleanup targets
# --------------------------------------------------------------------------

clean: ## Remove work/ directory (requires sudo)
	sudo rm -rf work/

distclean: ## Remove work/ and output/ directories (requires sudo)
	sudo rm -rf work/ output/

# --------------------------------------------------------------------------
# Status / Info
# --------------------------------------------------------------------------

status: ## Show disk usage of work/ and output/ directories
	@echo ""
	@echo "Landscape Mini - Build Status"
	@echo "=============================="
	@echo ""
	@if [ -d work ]; then \
		echo "work/ directory:"; \
		du -sh work/ 2>/dev/null || echo "  (empty)"; \
		echo ""; \
	else \
		echo "work/ directory:  does not exist"; \
		echo ""; \
	fi
	@if [ -d output ]; then \
		echo "output/ directory:"; \
		du -sh output/ 2>/dev/null || echo "  (empty)"; \
		echo ""; \
		echo "Output files:"; \
		ls -lh output/ 2>/dev/null || echo "  (none)"; \
	else \
		echo "output/ directory: does not exist"; \
	fi
	@echo ""
