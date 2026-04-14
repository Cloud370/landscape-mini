# =============================================================================
# Landscape Mini - Local Development & Debugging Makefile
# =============================================================================
#
# Builds a minimal x86 UEFI image for the Landscape Router.
# Supports Debian (default) and Alpine Linux base systems.
# The main build script (build.sh) requires root/sudo.
#
# Usage:
#   make              - Show all available targets
#   make build        - Full build (Debian, without Docker)
#   make build-alpine - Full build (Alpine, without Docker)
#   make test         - Run automated readiness checks (non-interactive)
#   make test-serial  - Boot image in QEMU (interactive serial console)
#
# Default credentials:  root / landscape  |  ld / landscape
# =============================================================================

.PHONY: help deps deps-test \
	build build-docker build-alpine build-alpine-docker \
	test test-docker test-alpine test-alpine-docker \
	test-dataplane test-dataplane-alpine \
	test-serial test-gui ssh clean distclean status

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

IMAGE         := output/landscape-mini-x86.img
IMAGE_ALPINE  := output/landscape-mini-x86-alpine.img
OVMF          := /usr/share/ovmf/OVMF.fd
SSH_PORT      := 2222
WEB_PORT      := 9800
LANDSCAPE_CONTROL_PORT := 6443
QEMU_MEM      := 1024
QEMU_SMP      := 2

# --------------------------------------------------------------------------
# Default target
# --------------------------------------------------------------------------

help: ## Show all available targets with descriptions
	@echo ""
	@echo "Landscape Mini - Development Makefile"
	@echo "======================================"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Debian image: $(IMAGE)"
	@echo "Alpine image: $(IMAGE_ALPINE)"
	@echo "SSH:          ssh -p $(SSH_PORT) root@localhost"
	@echo "Web UI:       http://localhost:$(WEB_PORT)"
	@echo ""

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------

deps: ## Install all host dependencies needed for building
	sudo apt-get update
	sudo apt-get install -y debootstrap parted dosfstools e2fsprogs \
		grub-efi-amd64-bin grub-pc-bin qemu-utils qemu-system-x86 ovmf \
		rsync curl gdisk unzip

deps-test: ## Install test dependencies (sshpass, socat, curl, jq)
	sudo apt-get update
	sudo apt-get install -y sshpass socat curl jq qemu-system-x86 ovmf

# --------------------------------------------------------------------------
# Build targets — Debian
# --------------------------------------------------------------------------

build: ## Build Debian image without Docker (requires sudo)
	sudo ./build.sh

build-docker: ## Build Debian image with Docker (requires sudo)
	sudo ./build.sh --with-docker

# --------------------------------------------------------------------------
# Build targets — Alpine
# --------------------------------------------------------------------------

build-alpine: ## Build Alpine image without Docker (requires sudo)
	sudo ./build.sh --base alpine

build-alpine-docker: ## Build Alpine image with Docker (requires sudo)
	sudo ./build.sh --base alpine --with-docker

# --------------------------------------------------------------------------
# QEMU readiness test targets
# --------------------------------------------------------------------------

test: $(IMAGE) ## Run readiness checks on Debian image
	./tests/test-readiness.sh $(IMAGE)

test-docker: output/landscape-mini-x86-docker.img ## Run readiness checks on Debian Docker image
	./tests/test-readiness.sh output/landscape-mini-x86-docker.img

# --------------------------------------------------------------------------
# QEMU readiness test targets — Alpine
# --------------------------------------------------------------------------

test-alpine: $(IMAGE_ALPINE) ## Run readiness checks on Alpine image
	./tests/test-readiness.sh $(IMAGE_ALPINE)

test-alpine-docker: output/landscape-mini-x86-alpine-docker.img ## Run readiness checks on Alpine Docker image
	./tests/test-readiness.sh output/landscape-mini-x86-alpine-docker.img

# --------------------------------------------------------------------------
# Dataplane tests (Router VM + CirrOS client)
# --------------------------------------------------------------------------

test-dataplane: $(IMAGE) ## Run dataplane tests on Debian image (DHCP + LAN connectivity)
	./tests/test-dataplane.sh $(IMAGE)

test-dataplane-alpine: $(IMAGE_ALPINE) ## Run dataplane tests on Alpine image (DHCP + LAN connectivity)
	./tests/test-dataplane.sh $(IMAGE_ALPINE)

# --------------------------------------------------------------------------
# Interactive QEMU targets
# --------------------------------------------------------------------------

test-serial: $(IMAGE) ## Boot Debian image in QEMU (interactive serial console)
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios $(OVMF) \
		-drive file=$(IMAGE),format=raw,if=virtio \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=wan,hostfwd=tcp::$(SSH_PORT)-:22,hostfwd=tcp::$(WEB_PORT)-:$(LANDSCAPE_CONTROL_PORT) \
		-device virtio-net-pci,netdev=lan \
		-netdev user,id=lan \
		-display none \
		-serial mon:stdio

test-gui: $(IMAGE) ## Boot Debian image in QEMU (with VGA display window)
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios $(OVMF) \
		-drive file=$(IMAGE),format=raw,if=virtio \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=wan,hostfwd=tcp::$(SSH_PORT)-:22,hostfwd=tcp::$(WEB_PORT)-:$(LANDSCAPE_CONTROL_PORT) \
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
