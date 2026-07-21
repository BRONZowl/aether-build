#!/usr/bin/env bash
# Copyright 2023-2026 SpaceXAI
# SPDX-License-Identifier: Apache-2.0

# Inventory monorepo Rust product paths (S0 — dual product / separation).
# Safe read-only. Never deletes.
#
# Usage: bash aether/scripts/inventory-rust-tree.sh
# Alias: make -C aether inventory-rust
#
# In a standalone S4 extract (no sibling crates/), prints a notice and exits 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$AETHER_DIR/.." && pwd)"

PATHS=(
  crates
  third_party
  prod
  Cargo.toml
  Cargo.lock
  rust-toolchain.toml
  rustfmt.toml
  clippy.toml
  bin/protoc
)

log() { printf 'inventory-rust: %s\n' "$*" >&2; }

# Standalone extract: parent is not a dual-product monorepo
if [[ ! -e "$ROOT/Cargo.toml" && ! -d "$ROOT/crates" ]]; then
  log "monorepo-only helper — no sibling crates/ or Cargo.toml above $AETHER_DIR"
  log "this looks like a standalone Aether tree (S4 extract); nothing to inventory"
  log "Done (read-only)."
  exit 0
fi

cd "$ROOT"

log "monorepo root: $ROOT"
log "policy: dual product — keep both Aether (Odin) and Rust; do not delete"
log ""
log "Rust-side paths (present sizes):"
for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    size=$(du -sh "$p" 2>/dev/null | awk '{print $1}')
    log "  $p  ($size)"
  else
    log "  $p  (absent)"
  fi
done
log ""
log "Odin product: aether/  (independent build: make -C aether build)"
log "Shared user data (~/.grok): interop only — not a source-tree dependency"
log "Done (read-only)."
