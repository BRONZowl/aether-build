#!/usr/bin/env bash
# Bootstrap the Odin compiler into aether/.tools or monorepo .tools (S1).
# Does not require Cargo/Rust.
#
# Search / default tools dir:
#   AETHER_TOOLS_DIR if set
#   else aether/.tools if already present
#   else monorepo ../.tools if present
#   else create aether/.tools (portable)
#
# Usage:
#   bash aether/scripts/bootstrap-odin.sh
#   AETHER_ODIN_FORCE=1 bash aether/scripts/bootstrap-odin.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$AETHER_DIR/.." && pwd)"

if [[ -n "${AETHER_TOOLS_DIR:-}" ]]; then
  TOOLS_DIR="$AETHER_TOOLS_DIR"
elif [[ -d "$AETHER_DIR/.tools/odin" || -x "$AETHER_DIR/.tools/odin/odin" ]]; then
  TOOLS_DIR="$AETHER_DIR/.tools"
elif [[ -d "$ROOT/.tools/odin" || -x "$ROOT/.tools/odin/odin" ]]; then
  TOOLS_DIR="$ROOT/.tools"
else
  TOOLS_DIR="$AETHER_DIR/.tools"
fi

ODIN_DIR="${AETHER_ODIN_DIR:-$TOOLS_DIR/odin}"
BIN_DIR="${AETHER_TOOLS_BIN:-$TOOLS_DIR/bin}"
ODIN_REPO="${AETHER_ODIN_REPO:-https://github.com/odin-lang/Odin.git}"
ODIN_REF="${AETHER_ODIN_REF:-master}"
FORCE="${AETHER_ODIN_FORCE:-0}"

log() { printf 'bootstrap-odin: %s\n' "$*" >&2; }

if [[ -x "$ODIN_DIR/odin" && "$FORCE" != "1" ]]; then
  log "odin already at $ODIN_DIR/odin — skip (set AETHER_ODIN_FORCE=1 to rebuild)"
  mkdir -p "$BIN_DIR"
  ln -sfn "$ODIN_DIR/odin" "$BIN_DIR/odin"
  log "export PATH=\"$BIN_DIR:\$PATH\" ODIN_ROOT=\"$ODIN_DIR\""
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  log "error: git is required"
  exit 1
fi
if ! command -v clang >/dev/null 2>&1 && ! command -v c++ >/dev/null 2>&1; then
  log "error: clang or c++ is required to build Odin"
  exit 1
fi

if ! command -v llvm-config >/dev/null 2>&1; then
  found=
  for v in 22 21 20 19 18 17; do
    if command -v "llvm-config-$v" >/dev/null 2>&1; then
      export LLVM_CONFIG="llvm-config-$v"
      found=1
      log "using LLVM_CONFIG=$LLVM_CONFIG"
      break
    fi
  done
  if [[ -z "$found" ]]; then
    log "error: llvm-config (LLVM 17–22) is required"
    log "  Debian/Ubuntu: sudo apt-get install -y llvm clang build-essential"
    log "  Arch:          sudo pacman -S llvm clang"
    exit 1
  fi
fi

mkdir -p "$TOOLS_DIR" "$BIN_DIR"

if [[ -d "$ODIN_DIR/.git" ]]; then
  log "updating existing clone at $ODIN_DIR (ref $ODIN_REF)"
  git -C "$ODIN_DIR" fetch --depth 1 origin "$ODIN_REF"
  git -C "$ODIN_DIR" checkout -f FETCH_HEAD
else
  if [[ -e "$ODIN_DIR" && ! -d "$ODIN_DIR/.git" ]]; then
    log "removing incomplete/non-git tree at $ODIN_DIR"
    rm -rf "$ODIN_DIR"
  fi
  log "cloning $ODIN_REPO ($ODIN_REF) → $ODIN_DIR"
  if ! git clone --depth 1 --branch "$ODIN_REF" "$ODIN_REPO" "$ODIN_DIR" 2>/dev/null; then
    git clone --depth 1 "$ODIN_REPO" "$ODIN_DIR"
  fi
fi

log "building Odin (release) in $ODIN_DIR …"
(
  cd "$ODIN_DIR"
  # shellcheck disable=SC2086
  ./build_odin.sh ${AETHER_ODIN_BUILD_ARGS:-release}
)

if [[ ! -x "$ODIN_DIR/odin" ]]; then
  log "error: build finished but $ODIN_DIR/odin is missing"
  exit 1
fi

ln -sfn "$ODIN_DIR/odin" "$BIN_DIR/odin"
log "ok: $($ODIN_DIR/odin version 2>/dev/null || echo odin)"
log "TOOLS_DIR=$TOOLS_DIR"
log "export PATH=\"$BIN_DIR:\$PATH\""
log "export ODIN_ROOT=\"$ODIN_DIR\""
log "then: make -C aether build test smoke-tui"
