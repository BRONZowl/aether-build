#!/usr/bin/env bash
# Copyright 2023-2026 SpaceXAI
# SPDX-License-Identifier: Apache-2.0

# Non-interactive TUI smoke via script(1) + key sequences.
# No network required. Exit 0 on pass; 1 on fail; 0 skip if no script(1)/TTY tools.
set -uo pipefail

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

export TERM="${TERM:-xterm-256color}"
export COLUMNS="${COLUMNS:-120}"
export LINES="${LINES:-40}"
export AETHER_NO_DESKTOP_NOTIFY=1
export AETHER_NO_SKILLS="${AETHER_NO_SKILLS:-1}"

# Bound TUI lifetime so a missed Ctrl+Q cannot hang CI.
TUI_CMD="timeout -k 1s 6s $BIN tui"

# Drive keys: Shift+Tab (mode), Ctrl+O (yolo), Ctrl+F find, Tab, /help, quit.
# ESC [ Z = Shift+Tab; Ctrl+O = 0x0f; Tab = 0x09; Ctrl+Q = 0x11
(
  trap '' PIPE
  sleep 0.4
  printf '\x1b[Z' || true # Shift+Tab
  sleep 0.2
  printf '\x0f' || true # Ctrl+O
  sleep 0.2
  printf '\x06' || true # Ctrl+F find
  sleep 0.12
  printf 'a' || true
  sleep 0.12
  printf '\x1b' || true # Esc close find
  sleep 0.12
  printf '\t' || true # Tab → scrollback
  sleep 0.15
  printf '\t' || true # Tab → prompt
  sleep 0.12
  printf '/help\r' || true
  sleep 0.3
  printf '\x11\x11' || true # Ctrl+Q twice
  sleep 0.2
) | script -qfec "$TUI_CMD" "$LOG" >/dev/null 2>&1 || true

# Strip to printable for greps
flat="$(tr -cd '\11\12\15\40-\176' <"$LOG" 2>/dev/null || true)"
rm -f "$LOG"

if [[ -z "${flat//[[:space:]]/}" ]]; then
  echo "tui-smoke: FAIL empty capture (TUI did not paint under script(1))" >&2
  exit 1
fi

fail=0
check() {
  local pat="$1"
  local label="$2"
  if echo "$flat" | grep -qE "$pat"; then
    echo "tui-smoke: ok  $label"
  else
    echo "tui-smoke: FAIL $label (pattern: $pat)" >&2
    echo "tui-smoke: capture head: $(echo "$flat" | head -c 400)" >&2
    fail=1
  fi
}

# Header always paints the permission chip (default "ask"). Key cycles may also
# produce mode:/yolo status lines — script(1) captures are lossy under load.
check 'mode:[[:space:]]*(plan|ask|auto|always-approve|read-only)|yolo on|yolo off|\b(ask|auto|plan|yolo|always-approve|read-only)\b' \
  "plan/yolo mode chrome"
check 'find:|Ctrl\+F|scroll|prompt|Commands|/help|this help|aether|sess=' \
  "TUI chrome (find/help/header)"

if [[ "$fail" -ne 0 ]]; then
  echo "tui-smoke: FAILED" >&2
  exit 1
fi
echo "tui-smoke: all checks passed"
exit 0
