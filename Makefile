# =============================================================================
# Landscape Mini - Local Development & Debugging Makefile
# =============================================================================
#
# Builds a minimal x86 UEFI image for the Landscape Router.
# Supports Debian and Alpine base systems, optional Docker, and multiple
# output formats.
# The main build script (build.sh) runs rootless by default (user namespaces)
# and also works as root.
#
# Usage:
#   make              - Show all available targets
#   make build        - Full build with current variables
#   make test         - Run automated readiness checks (non-interactive)
#   make test-serial  - Boot image in QEMU (interactive serial console)
#
# Example:
#   make build BASE_SYSTEM=alpine INCLUDE_DOCKER=true OUTPUT_FORMATS=img,ova
#
# Default credentials:  root / landscape  |  ld / landscape
# =============================================================================

.PHONY: help deps deps-test \
	build test test-dataplane test-serial test-gui ssh clean distclean cache-clean status

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

empty :=
space := $(empty) $(empty)
comma := ,
BUILD_ENV_VARS := BUILD_ENV_PROFILE BASE_SYSTEM INCLUDE_DOCKER OUTPUT_FORMATS LANDSCAPE_VERSION ROOT_PASSWORD LANDSCAPE_ADMIN_USER LANDSCAPE_ADMIN_PASS LANDSCAPE_LAN_SERVER_IP LANDSCAPE_LAN_RANGE_START LANDSCAPE_LAN_RANGE_END LANDSCAPE_LAN_NETMASK RUN_TEST EFFECTIVE_CONFIG_PATH EFFECTIVE_CONFIG_PROFILE EFFECTIVE_TOPOLOGY_SOURCE APT_MIRROR ALPINE_MIRROR DOCKER_APT_MIRROR DOCKER_APT_GPG_URL SOURCE_PROBE_TIMEOUT COMPRESS_OUTPUT LANDSCAPE_REPO IMAGE_SIZE_MB DEBIAN_RELEASE ALPINE_RELEASE TIMEZONE LOCALE EXTRA_LOCALES WORK_DIR OUTPUT_DIR CACHE_DIR BUILD_CHROOT_ENGINE LANDSCAPE_TEST_LOG_DIR SSH_PORT WEB_PORT LANDSCAPE_CONTROL_PORT QEMU_MEM QEMU_SMP MCAST_ADDR MCAST_PORT ROUTER_WAN_MAC ROUTER_LAN_MAC CLIENT_MAC
BUILD_PRESERVE_ENV := $(subst $(space),$(comma),$(strip $(BUILD_ENV_VARS)))
OVMF ?= $(shell ./tests/ovmf-path.sh 2>/dev/null || echo /usr/share/ovmf/OVMF.fd)
WORK_DIR ?= work
OUTPUT_DIR ?= output
CACHE_DIR ?= .cache
OUTPUT_METADATA_DIR := $(OUTPUT_DIR)/metadata
LANDSCAPE_CONTROL_PORT ?= 6443
QEMU_MEM ?= 1024
QEMU_SMP ?= 2

TEST_SERIAL_SSH_PORT ?= 2222
TEST_SERIAL_WEB_PORT ?= 9800
TEST_SERIAL_MCAST_ADDR ?= 230.0.0.1
TEST_SERIAL_MCAST_PORT ?= 1234
TEST_SERIAL_ROUTER_WAN_MAC ?= 52:54:00:12:34:01
TEST_SERIAL_ROUTER_LAN_MAC ?= 52:54:00:12:34:02
TEST_SERIAL_CLIENT_MAC ?= 52:54:00:12:34:10
TEST_SERIAL_ROUTER_NET_ENV = SSH_PORT="$(TEST_SERIAL_SSH_PORT)" WEB_PORT="$(TEST_SERIAL_WEB_PORT)"
TEST_SERIAL_DATAPLANE_ENV = $(TEST_SERIAL_ROUTER_NET_ENV) MCAST_ADDR="$(TEST_SERIAL_MCAST_ADDR)" MCAST_PORT="$(TEST_SERIAL_MCAST_PORT)" ROUTER_WAN_MAC="$(TEST_SERIAL_ROUTER_WAN_MAC)" ROUTER_LAN_MAC="$(TEST_SERIAL_ROUTER_LAN_MAC)" CLIENT_MAC="$(TEST_SERIAL_CLIENT_MAC)"

TEST_RUNTIME_ENV = OUTPUT_DIR="$(OUTPUT_DIR)" WORK_DIR="$(WORK_DIR)" LANDSCAPE_CONTROL_PORT="$(LANDSCAPE_CONTROL_PORT)"
TEST_RUNTIME_ENV += $(if $(filter undefined,$(origin SSH_PORT)),,SSH_PORT="$(SSH_PORT)")
TEST_RUNTIME_ENV += $(if $(filter undefined,$(origin WEB_PORT)),,WEB_PORT="$(WEB_PORT)")
TEST_DATAPLANE_ENV = $(TEST_RUNTIME_ENV)
TEST_DATAPLANE_ENV += $(if $(filter undefined,$(origin MCAST_ADDR)),,MCAST_ADDR="$(MCAST_ADDR)")
TEST_DATAPLANE_ENV += $(if $(filter undefined,$(origin MCAST_PORT)),,MCAST_PORT="$(MCAST_PORT)")
TEST_DATAPLANE_ENV += $(if $(filter undefined,$(origin ROUTER_WAN_MAC)),,ROUTER_WAN_MAC="$(ROUTER_WAN_MAC)")
TEST_DATAPLANE_ENV += $(if $(filter undefined,$(origin ROUTER_LAN_MAC)),,ROUTER_LAN_MAC="$(ROUTER_LAN_MAC)")
TEST_DATAPLANE_ENV += $(if $(filter undefined,$(origin CLIENT_MAC)),,CLIENT_MAC="$(CLIENT_MAC)")

DISPLAY_SSH_PORT := $(if $(filter undefined,$(origin SSH_PORT)),auto,$(SSH_PORT))
DISPLAY_WEB_PORT := $(if $(filter undefined,$(origin WEB_PORT)),auto,$(WEB_PORT))
DISPLAY_MCAST_PORT := $(if $(filter undefined,$(origin MCAST_PORT)),auto,$(MCAST_PORT))
DISPLAY_MCAST_ADDR := $(if $(filter undefined,$(origin MCAST_ADDR)),auto,$(MCAST_ADDR))

IMAGE_BASENAME := landscape-mini-x86-$(if $(BASE_SYSTEM),$(BASE_SYSTEM),debian)$(if $(filter true,$(INCLUDE_DOCKER)),-docker,)
IMAGE := $(OUTPUT_DIR)/$(IMAGE_BASENAME).img

resolve_image_path = $${IMAGE_PATH:-$$( \
	if [ -f $(OUTPUT_METADATA_DIR)/build-metadata.txt ]; then \
		awk -F'=' -v output_dir='$(OUTPUT_DIR)' '/^image_file=/{print output_dir "/" $$2; exit}' $(OUTPUT_METADATA_DIR)/build-metadata.txt; \
	else \
		printf '%s' "$(IMAGE)"; \
	fi \
)}

$(foreach var,$(BUILD_ENV_VARS),$(if $(filter undefined,$(origin $(var))),,$(eval export $(var))))

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
	@echo "Current build identity:"
	@echo "  BASE_SYSTEM=$(if $(BASE_SYSTEM),$(BASE_SYSTEM),<from layered env files>)"
	@echo "  INCLUDE_DOCKER=$(if $(INCLUDE_DOCKER),$(INCLUDE_DOCKER),<from layered env files>)"
	@echo "  OUTPUT_FORMATS=$(if $(OUTPUT_FORMATS),$(OUTPUT_FORMATS),<from layered env files>)"
	@echo "  IMAGE=$(IMAGE)"
	@echo "  WORK_DIR=$(WORK_DIR)"
	@echo "  OUTPUT_DIR=$(OUTPUT_DIR)"
	@echo "  CACHE_DIR=$(CACHE_DIR) (survives make clean; make cache-clean to purge)"
	@echo "  test SSH port=$(DISPLAY_SSH_PORT)"
	@echo "  test Web port=$(DISPLAY_WEB_PORT)"
	@echo "  dataplane mcast=$(DISPLAY_MCAST_ADDR):$(DISPLAY_MCAST_PORT)"
	@echo "  serial SSH:  ssh -p $(TEST_SERIAL_SSH_PORT) root@localhost"
	@echo "  serial Web:  http://localhost:$(TEST_SERIAL_WEB_PORT)"
	@echo ""

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------

deps: ## Install all host dependencies needed for building
	sudo apt-get update
	sudo apt-get install -y debootstrap dosfstools e2fsprogs gdisk \
		grub-efi-amd64-bin grub-pc-bin mtools rsync wget \
		qemu-utils qemu-system-x86 ovmf \
		curl unzip xz-utils proot uidmap

deps-test: ## Install test dependencies (sshpass, socat, curl, jq)
	sudo apt-get update
	sudo apt-get install -y sshpass socat curl jq qemu-system-x86 ovmf

# --------------------------------------------------------------------------
# Build and test targets
# --------------------------------------------------------------------------

build: ## Build image with layered env files plus explicit overrides
	./build.sh

test: ## Run readiness checks on the current raw image
	@image_path="$(resolve_image_path)"; \
	$(TEST_RUNTIME_ENV) ./tests/test-readiness.sh "$$image_path"

test-dataplane: ## Run dataplane checks on the current raw image
	@image_path="$(resolve_image_path)"; \
	$(TEST_DATAPLANE_ENV) ./tests/test-dataplane.sh "$$image_path"

# --------------------------------------------------------------------------
# Interactive QEMU targets
# --------------------------------------------------------------------------

test-serial: ## Boot current image in QEMU (interactive serial console)
	@image_path="$(resolve_image_path)"; \
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios $(OVMF) \
		-drive file="$$image_path",format=raw,if=virtio \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=wan,hostfwd=tcp::$(TEST_SERIAL_SSH_PORT)-:22,hostfwd=tcp::$(TEST_SERIAL_WEB_PORT)-:$(LANDSCAPE_CONTROL_PORT) \
		-device virtio-net-pci,netdev=lan \
		-netdev user,id=lan \
		-display none \
		-serial mon:stdio

test-gui: ## Boot current image in QEMU (with VGA display window)
	@image_path="$(resolve_image_path)"; \
	qemu-system-x86_64 \
		-enable-kvm \
		-m $(QEMU_MEM) \
		-smp $(QEMU_SMP) \
		-bios $(OVMF) \
		-drive file="$$image_path",format=raw,if=virtio \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=wan,hostfwd=tcp::$(TEST_SERIAL_SSH_PORT)-:22,hostfwd=tcp::$(TEST_SERIAL_WEB_PORT)-:$(LANDSCAPE_CONTROL_PORT) \
		-device virtio-net-pci,netdev=lan \
		-netdev user,id=lan

# --------------------------------------------------------------------------
# Remote access
# --------------------------------------------------------------------------

ssh: ## SSH into the running QEMU instance
	ssh -o StrictHostKeyChecking=no -p $(TEST_SERIAL_SSH_PORT) root@localhost

# --------------------------------------------------------------------------
# Cleanup targets
# --------------------------------------------------------------------------

clean: ## Remove work directory
	rm -rf $(WORK_DIR)/ 2>/dev/null || sudo rm -rf $(WORK_DIR)/

distclean: ## Remove work and output directories
	rm -rf $(WORK_DIR)/ $(OUTPUT_DIR)/ 2>/dev/null || sudo rm -rf $(WORK_DIR)/ $(OUTPUT_DIR)/

cache-clean: ## Remove the persistent download/package cache
	rm -rf $(CACHE_DIR)/ 2>/dev/null || sudo rm -rf $(CACHE_DIR)/

# --------------------------------------------------------------------------
# Status / Info
# --------------------------------------------------------------------------

status: ## Show disk usage of work and output directories
	@echo ""
	@echo "Landscape Mini - Build Status"
	@echo "=============================="
	@echo ""
	@if [ -d "$(WORK_DIR)" ]; then \
		echo "$(WORK_DIR)/ directory:"; \
		du -sh "$(WORK_DIR)" 2>/dev/null || echo "  (empty)"; \
		echo ""; \
	else \
		echo "$(WORK_DIR)/ directory: does not exist"; \
		echo ""; \
	fi
	@if [ -d "$(OUTPUT_DIR)" ]; then \
		echo "$(OUTPUT_DIR)/ directory:"; \
		du -sh "$(OUTPUT_DIR)" 2>/dev/null || echo "  (empty)"; \
		echo ""; \
		echo "Output files:"; \
		ls -lh "$(OUTPUT_DIR)" 2>/dev/null || echo "  (none)"; \
	else \
		echo "$(OUTPUT_DIR)/ directory: does not exist"; \
	fi
	@if [ -d "$(CACHE_DIR)" ]; then \
		echo ""; \
		echo "$(CACHE_DIR)/ directory (build cache):"; \
		du -sh "$(CACHE_DIR)" 2>/dev/null || echo "  (empty)"; \
	fi
	@echo ""
