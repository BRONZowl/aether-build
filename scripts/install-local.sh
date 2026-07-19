#!/usr/bin/env bash
# Install Aether wrappers into a user bin dir and optional bash completion.
# Dual branding: aether-grok-odin, grok-odin, and optionally aether.
# Does NOT install as `grok` — that name is the Rust product binary.
#
# Install dest (first writable wins unless AETHER_INSTALL_BIN is set):
#   1. $AETHER_INSTALL_BIN
#   2. ~/.local/bin
#   3. ~/.grok/bin  (often already on PATH via grok installer)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$AETHER_DIR/bin/aether"
BIN="${AETHER_ODIN_BIN:-${AETHER_OUT:-$AETHER_DIR/out/aether}}"
COMP_SRC="$AETHER_DIR/completions/aether.bash"
COMP_DIR="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}"

# Primary names — never clobber Rust `grok`.
NAMES=(aether-grok-odin aether-grok grok-odin)

pick_dest() {
  if [[ -n "${AETHER_INSTALL_BIN:-}" ]]; then
    echo "$AETHER_INSTALL_BIN"
    return
  fi
  local d
  for d in "$HOME/.local/bin" "$HOME/.grok/bin"; do
    if mkdir -p "$d" 2>/dev/null && [[ -w "$d" ]]; then
      # Confirm we can create a symlink here
      if ln -sfn /dev/null "$d/.aether-install-write-test" 2>/dev/null; then
        rm -f "$d/.aether-install-write-test"
        echo "$d"
        return
      fi
    fi
  done
  echo "$HOME/.local/bin"
}

DEST_DIR="$(pick_dest)"

if [[ ! -x "$BIN" ]]; then
  echo "Binary not found at $BIN — building..." >&2
  if command -v odin >/dev/null 2>&1 || [[ -x "${AETHER_TOOLS_DIR:-}/bin/odin" ]] || \
     [[ -x "$AETHER_DIR/.tools/bin/odin" ]] || [[ -x "$AETHER_DIR/../.tools/bin/odin" ]]; then
    make -C "$AETHER_DIR" build
  else
    echo "error: no binary at $BIN and odin not on PATH." >&2
    echo "  Build first:  make -C \"$AETHER_DIR\" bootstrap-odin build" >&2
    echo "  Or set:       AETHER_OUT=/path/to/built/aether" >&2
    exit 1
  fi
fi

if [[ ! -x "$BIN" ]]; then
  echo "error: binary still missing at $BIN after build" >&2
  exit 1
fi

if [[ ! -x "$WRAPPER" ]]; then
  echo "error: wrapper missing: $WRAPPER" >&2
  exit 1
fi

if ! mkdir -p "$DEST_DIR" 2>/dev/null || [[ ! -w "$DEST_DIR" ]]; then
  echo "error: cannot write install dir: $DEST_DIR" >&2
  echo "  Set AETHER_INSTALL_BIN to a writable directory on your PATH." >&2
  exit 1
fi

for name in "${NAMES[@]}"; do
  ln -sfn "$WRAPPER" "$DEST_DIR/$name"
  echo "Installed: $DEST_DIR/$name -> $WRAPPER"
done

# Optional short name `aether` — skip if it would shadow a non-Aether system binary
# (e.g. Arch package "aether" desktop theme generator at /usr/bin/aether).
install_short_aether=1
if [[ "${AETHER_INSTALL_SHORT_NAME:-auto}" == "0" || "${AETHER_INSTALL_SHORT_NAME:-auto}" == "no" ]]; then
  install_short_aether=0
elif [[ "${AETHER_INSTALL_SHORT_NAME:-auto}" == "1" || "${AETHER_INSTALL_SHORT_NAME:-auto}" == "yes" ]]; then
  install_short_aether=1
else
  # auto: refuse if `aether` on PATH is not our product and not missing
  if command -v aether >/dev/null 2>&1; then
    _sys="$(command -v aether)"
    _ver="$("$_sys" --version 2>/dev/null | head -1 || true)"
    case "$_ver" in
      aether-grok*|Aether-Grok*) ;;
      *)
        if [[ "$_sys" != "$DEST_DIR/aether" ]]; then
          echo "Note: skipping short name 'aether' — already on PATH as $_sys ($_ver)"
          echo "  Use aether-grok-odin / grok-odin, or force: AETHER_INSTALL_SHORT_NAME=1"
          install_short_aether=0
        fi
        ;;
    esac
    unset _sys _ver
  fi
fi

if [[ "$install_short_aether" -eq 1 ]]; then
  ln -sfn "$WRAPPER" "$DEST_DIR/aether"
  echo "Installed: $DEST_DIR/aether -> $WRAPPER"
  NAMES+=(aether)
fi

if [[ -f "$COMP_SRC" ]]; then
  if mkdir -p "$COMP_DIR" 2>/dev/null && [[ -w "$COMP_DIR" ]]; then
    for name in "${NAMES[@]}"; do
      cp "$COMP_SRC" "$COMP_DIR/$name" 2>/dev/null || true
    done
    if [[ -f "$COMP_DIR/aether-grok-odin" || -f "$COMP_DIR/aether" ]]; then
      echo "Installed bash completions into $COMP_DIR"
    else
      echo "Note: could not write bash completions under $COMP_DIR (permissions?)"
      echo "  Source manually: source $COMP_SRC"
    fi
  else
    echo "Note: could not create/write $COMP_DIR — skip completions"
    echo "  Source manually: source $COMP_SRC"
  fi
fi

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    echo
    echo "Note: $DEST_DIR is not on your PATH. Add:"
    echo "  export PATH=\"$DEST_DIR:\$PATH\""
    ;;
esac

echo
echo "Dependencies (runtime): libcurl, ripgrep (rg). Optional: pdftotext, unzip."
echo "Auth: export XAI_API_KEY=...  or: aether-grok-odin login  (device-code, M7)"
echo "      Optional legacy: aether-grok-odin login --host  (requires Rust grok on PATH)"
echo
echo "Try: aether-grok-odin --version"
echo "     aether-grok-odin -p \"say hi\""
echo "     aether-grok-odin tui"
echo "     grok-odin --version   # same binary; does not clobber Rust grok"
echo
echo "Tip: remove any stale alias like:"
echo "  alias aether-grok-odin=...   # prefer the PATH install above"
