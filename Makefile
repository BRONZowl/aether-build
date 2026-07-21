# Aether (Odin) — self-contained product build (S1 dual-product separation).
# Usage: cd aether && make build
#    or: make -C aether build
#
# Does not require crates/, Cargo, or a Rust grok binary.
# Monorepo convenience: will use ../.tools if aether/.tools is absent.

AETHER_DIR := $(abspath .)
REPO_ROOT := $(abspath ..)

# Tools search: AETHER_TOOLS_DIR → aether/.tools → monorepo .tools
ifdef AETHER_TOOLS_DIR
  TOOLS_DIR := $(AETHER_TOOLS_DIR)
else ifneq ($(wildcard $(AETHER_DIR)/.tools/odin/odin),)
  TOOLS_DIR := $(AETHER_DIR)/.tools
else ifneq ($(wildcard $(REPO_ROOT)/.tools/odin/odin),)
  TOOLS_DIR := $(REPO_ROOT)/.tools
else
  TOOLS_DIR := $(AETHER_DIR)/.tools
endif

TOOLS_BIN := $(TOOLS_DIR)/bin
TOOLS_ODIN := $(TOOLS_DIR)/odin

ifneq ($(wildcard $(TOOLS_BIN)/odin),)
  ODIN ?= $(TOOLS_BIN)/odin
else
  ODIN ?= odin
endif

ifneq ($(wildcard $(TOOLS_ODIN)/base),)
  export ODIN_ROOT ?= $(TOOLS_ODIN)
endif

export PATH := $(TOOLS_BIN):$(PATH)

# Output under aether/ (portable). Override: AETHER_OUT=/path/to/bin
OUT ?= $(if $(AETHER_OUT),$(AETHER_OUT),$(AETHER_DIR)/out/aether)
OUT_DIR := $(dir $(OUT))
FLAGS := -collection:aether=. -out:$(OUT)

.PHONY: all build debug vet test run clean smoke smoke-tui help install \
	bootstrap-odin dist inventory-rust r5-dry-run extract export-standalone \
	check-license

all: build

AETHER_VERSION ?= 0.1.0-dev
DIST_DIR := $(AETHER_DIR)/out/dist
DIST_NAME := aether-$(AETHER_VERSION)-$(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
WRAPPER := $(AETHER_DIR)/bin/aether
# S4: make extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'
EXTRACT_ARGS ?=

help:
	@echo "Aether (Odin product) — independent of crates/ / Cargo"
	@echo "  make build          release binary -> $(OUT)"
	@echo "  make debug          debug binary"
	@echo "  make vet            build with -vet"
	@echo "  make test           unit tests"
	@echo "  make run ARGS='-p hi'"
	@echo "  make smoke          live -p check (skips without auth)"
	@echo "  make smoke-tui      scripted TUI smoke (no network)"
	@echo "  make install        symlink aether-grok (+ odin names) into ~/.local/bin"
	@echo "  make bootstrap-odin Odin toolchain -> .tools/"
	@echo "  make dist           binary tarball under out/dist/"
	@echo "  make extract        S4 standalone source export (EXTRACT_ARGS=...)"
	@echo "  make inventory-rust list monorepo Rust paths (read-only)"
	@echo "  make check-license  Apache-2.0 + SPDX hygiene"
	@echo "  make clean          remove out/"
	@echo "ODIN=$(ODIN)"
	@echo "ODIN_ROOT=$(ODIN_ROOT)"
	@echo "TOOLS_DIR=$(TOOLS_DIR)"

build:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build . $(FLAGS) -o:speed

debug:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build . $(FLAGS) -debug

vet:
	@mkdir -p $(OUT_DIR)
	$(ODIN) build . $(FLAGS) -o:speed -vet

test:
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test agent -collection:aether=. -define:ODIN_TEST_THREADS=1
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test tools -collection:aether=. -define:ODIN_TEST_THREADS=1
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test core -collection:aether=. -define:ODIN_TEST_THREADS=1
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test mcp -collection:aether=.
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test skills -collection:aether=.
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test hooks -collection:aether=. -define:ODIN_TEST_THREADS=1
	AETHER_NO_DESKTOP_NOTIFY=1 $(ODIN) test tui -collection:aether=.

# Apache-2.0 LICENSE/NOTICE + first-party SPDX coverage
check-license:
	@bash scripts/check-apache-compliance.sh

run: build
	$(OUT) $(ARGS)

smoke: build
	@bash scripts/smoke.sh

smoke-tui: build
	@bash scripts/tui-smoke.sh

# Install wrappers; rebuild only if out binary is missing (odin not required when already built).
install:
	@if [[ ! -x "$(OUT)" ]]; then $(MAKE) build; fi
	@bash scripts/install-local.sh

bootstrap-odin:
	@bash scripts/bootstrap-odin.sh

inventory-rust:
	@bash scripts/inventory-rust-tree.sh

# Parked alias — inventory only (never deletes).
r5-dry-run: inventory-rust

# S4: export standalone source tree (does not remove monorepo aether/).
# Example: make extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'
extract export-standalone:
	@bash scripts/export-standalone.sh $(EXTRACT_ARGS)

dist: build
	@mkdir -p $(DIST_DIR)/$(DIST_NAME)
	cp -f $(OUT) $(DIST_DIR)/$(DIST_NAME)/aether
	@if [ -x $(WRAPPER) ]; then cp -f $(WRAPPER) $(DIST_DIR)/$(DIST_NAME)/aether-wrapper; fi
	@# Apache-2.0 §4: binary redistributions must include LICENSE + NOTICE
	cp -f $(AETHER_DIR)/LICENSE $(DIST_DIR)/$(DIST_NAME)/LICENSE
	cp -f $(AETHER_DIR)/NOTICE $(DIST_DIR)/$(DIST_NAME)/NOTICE
	@if [ -f $(AETHER_DIR)/assets/logo/NOTICE ]; then \
		mkdir -p $(DIST_DIR)/$(DIST_NAME)/assets/logo; \
		cp -f $(AETHER_DIR)/assets/logo/NOTICE $(DIST_DIR)/$(DIST_NAME)/assets/logo/NOTICE; \
	fi
	@printf '%s\n' \
		'# Aether $(AETHER_VERSION)' \
		'' \
		'License: Apache-2.0 — see LICENSE and NOTICE in this directory.' \
		'' \
		'Binary: ./aether' \
		'Auth:   export XAI_API_KEY=...' \
		'Deps:   libcurl, ripgrep (rg); optional pdftotext, unzip' \
		'Does not require Cargo or a Rust grok binary.' \
		'' \
		'Quick:' \
		'  chmod +x aether' \
		'  ./aether --version' \
		'  ./aether -p "say hi"' \
		'  ./aether tui' \
		> $(DIST_DIR)/$(DIST_NAME)/README.txt
	@tar -C $(DIST_DIR) -czf $(DIST_DIR)/$(DIST_NAME).tar.gz $(DIST_NAME)
	@rm -rf $(DIST_DIR)/$(DIST_NAME)
	@echo "dist: $(DIST_DIR)/$(DIST_NAME).tar.gz"

clean:
	rm -rf $(AETHER_DIR)/out
