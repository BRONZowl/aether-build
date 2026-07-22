#!/usr/bin/env bash
# Copyright 2023-2026 SpaceXAI
# SPDX-License-Identifier: Apache-2.0
#
# Install Aether into a FHS-style prefix for package managers (AUR, Homebrew, etc.).
# Copies the real binary (not a source-tree wrapper).
#
# Env:
#   DESTDIR  staging root (default empty)
#   PREFIX   install prefix (default /usr)
#   AETHER_OUT / AETHER_ODIN_BIN  built binary path
#
# Installs:
#   $PREFIX/bin/aether-grok          (primary)
#   $PREFIX/bin/aether-grok-odin     (symlink)
#   $PREFIX/bin/grok-odin            (symlink)
#   bash completion as aether-grok
#
# Does NOT install short name `aether` (Arch conflict with theme package).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="${AETHER_ODIN_BIN:-${AETHER_OUT:-$AETHER_DIR/out/aether}}"
PREFIX="${PREFIX:-/usr}"
DESTDIR="${DESTDIR:-}"
COMP_SRC="$AETHER_DIR/completions/aether.bash"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN — run: make build" >&2
  exit 1
fi

BINDIR="${DESTDIR}${PREFIX}/bin"
COMPDIR="${DESTDIR}${PREFIX}/share/bash-completion/completions"
DOCDIR="${DESTDIR}${PREFIX}/share/doc/aether-grok"
LICENSEDIR="${DESTDIR}${PREFIX}/share/licenses/aether-grok"

install -d "$BINDIR"
install -Dm755 "$BIN" "$BINDIR/aether-grok"
ln -sfn aether-grok "$BINDIR/aether-grok-odin"
ln -sfn aether-grok "$BINDIR/grok-odin"

if [[ -f "$COMP_SRC" ]]; then
  install -d "$COMPDIR"
  install -Dm644 "$COMP_SRC" "$COMPDIR/aether-grok"
fi

if [[ -f "$AETHER_DIR/LICENSE" ]]; then
  install -d "$LICENSEDIR"
  install -Dm644 "$AETHER_DIR/LICENSE" "$LICENSEDIR/LICENSE"
fi
if [[ -f "$AETHER_DIR/NOTICE" ]]; then
  install -d "$LICENSEDIR"
  install -Dm644 "$AETHER_DIR/NOTICE" "$LICENSEDIR/NOTICE"
fi
if [[ -f "$AETHER_DIR/README.md" ]]; then
  install -d "$DOCDIR"
  install -Dm644 "$AETHER_DIR/README.md" "$DOCDIR/README.md"
fi

echo "Installed under ${DESTDIR}${PREFIX}:"
echo "  bin/aether-grok  bin/aether-grok-odin  bin/grok-odin"
echo "Run: aether-grok --version"
