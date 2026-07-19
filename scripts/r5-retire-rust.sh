#!/usr/bin/env bash
# PARKED (S0): R5 delete path cancelled under dual-product separation plan.
# This wrapper only runs a read-only inventory. It never deletes.
#
# Prefer: bash aether/scripts/inventory-rust-tree.sh
#         make -C aether inventory-rust
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "r5-retire-rust: PARKED — dual-product plan does not delete Rust sources." >&2
echo "r5-retire-rust: running read-only inventory instead." >&2
if [[ "${AETHER_R5_CONFIRM:-}" == "yes" ]]; then
  echo "r5-retire-rust: AETHER_R5_CONFIRM=yes ignored (delete disabled)." >&2
fi
exec bash "$SCRIPT_DIR/inventory-rust-tree.sh"
