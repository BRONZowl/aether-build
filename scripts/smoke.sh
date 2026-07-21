#!/usr/bin/env bash
# Copyright 2023-2026 SpaceXAI
# SPDX-License-Identifier: Apache-2.0

# Live smoke: one-shot completion. Skips (exit 0) without auth.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="${AETHER_ODIN_BIN:-${AETHER_OUT:-$AETHER_DIR/out/aether}}"
WRAPPER="$AETHER_DIR/bin/aether"

if [[ ! -x "$BIN" ]]; then
  echo "smoke: building binary..." >&2
  make -C "$AETHER_DIR" build
fi

RUN=("$BIN")
if [[ -x "$WRAPPER" ]]; then
  RUN=("$WRAPPER")
fi

has_auth=0
if [[ -n "${XAI_API_KEY:-}" || -n "${GROK_CODE_XAI_API_KEY:-}" ]]; then
  has_auth=1
fi
if [[ -f "${GROK_AUTH_PATH:-$HOME/.grok/auth.json}" ]]; then
  has_auth=1
fi

if [[ "$has_auth" -eq 0 ]]; then
  echo "smoke: skip (no XAI_API_KEY / auth.json) — offline only"
  exit 0
fi

echo "smoke: running one-shot completion..." >&2
out="$("${RUN[@]}" -q -p "Reply with exactly: smoke-ok" 2>/dev/null || true)"
if echo "$out" | grep -q "smoke-ok"; then
  echo "smoke: ok"
  exit 0
fi
echo "smoke: FAIL — unexpected output:" >&2
echo "$out" >&2
exit 1
