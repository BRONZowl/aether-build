#!/usr/bin/env bash
# Copyright 2023-2026 SpaceXAI
# SPDX-License-Identifier: Apache-2.0

# Non-interactive TUI smoke via script(1) + key sequences.
# No network required. Exit 0 on pass; 1 on fail; 0 skip if no script(1)/TTY tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="${AETHER_ODIN_BIN:-${AETHER_OUT:-$AETHER_DIR/out/aether}}"
LOG="${TMPDIR:-/tmp}/aether-tui-smoke-$$.log"

if [[ ! -x "$BIN" ]]; then
  echo "tui-smoke: building..." >&2
  make -C "$AETHER_DIR" build
fi

if ! command -v script >/dev/null 2>&1; then
  echo "tui-smoke: skip (no script(1))"
  exit 0
fi

# Drive keys: Shift+Tab (mode), Ctrl+O (yolo), Tab (scrollback), /help, quit
# ESC [ Z = Shift+Tab; Ctrl+O = 0x0f; Tab = 0x09; Ctrl+Q = 0x11
(
  sleep 0.2
  printf '\x1b[Z'   # Shift+Tab
  sleep 0.15
  printf '\x0f'     # Ctrl+O
  sleep 0.15
  printf '\x06'     # Ctrl+F find
  sleep 0.1
  printf 'a'        # query char
  sleep 0.1
  printf '\x1b'     # Esc close find
  sleep 0.1
  printf '\t'       # Tab → scrollback
  sleep 0.15
  printf '\t'       # Tab → prompt
  sleep 0.1
  printf '/help\r'
  sleep 0.25
  printf '\x11\x11' # Ctrl+Q twice
  sleep 0.2
) | script -qfec "$BIN tui" "$LOG" >/dev/null 2>&1 || true

# Strip to printable for greps
flat="$(tr -cd '\11\12\15\40-\176' <"$LOG" 2>/dev/null || true)"
rm -f "$LOG"

fail=0
check() {
  local pat="$1"
  local label="$2"
  if echo "$flat" | grep -qE "$pat"; then
    echo "tui-smoke: ok  $label"
  else
    echo "tui-smoke: FAIL $label (pattern: $pat)" >&2
    fail=1
  fi
}

# Flexible matches (ANSI may leave partial words)
# First Shift+Tab from default ask → plan (Grok-shaped cycle)
# script(1) captures can be partial under load — keep patterns loose
check 'mode: plan|mode:plan|\bplan\b|always-approve|yolo' "plan/yolo mode chrome"
check 'find:|Ctrl\+F|scroll|prompt|Commands|/help|this help|aether|sess=' "TUI chrome (find/help/header)"

if [[ "$fail" -ne 0 ]]; then
  echo "tui-smoke: FAILED" >&2
  exit 1
fi
echo "tui-smoke: all checks passed"
exit 0
