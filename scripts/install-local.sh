#!/usr/bin/env bash
# Install Aether wrappers into ~/.local/bin and optional bash completion.
# Dual branding: aether-grok-odin, aether, grok-odin.
# Does NOT install as `grok` — that name is the Rust product binary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$AETHER_DIR/bin/aether"
BIN="${AETHER_ODIN_BIN:-${AETHER_OUT:-$AETHER_DIR/out/aether}}"
DEST_DIR="${AETHER_INSTALL_BIN:-$HOME/.local/bin}"
COMP_SRC="$AETHER_DIR/completions/aether.bash"
COMP_DIR="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}"

NAMES=(aether-grok-odin aether grok-odin)

if [[ ! -x "$BIN" ]]; then
  echo "Binary not found at $BIN — building..." >&2
  make -C "$AETHER_DIR" build
fi

if [[ ! -x "$WRAPPER" ]]; then
  echo "error: wrapper missing: $WRAPPER" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
for name in "${NAMES[@]}"; do
  ln -sfn "$WRAPPER" "$DEST_DIR/$name"
  echo "Installed: $DEST_DIR/$name -> $WRAPPER"
done

if [[ -f "$COMP_SRC" ]]; then
  if mkdir -p "$COMP_DIR" 2>/dev/null; then
    for name in "${NAMES[@]}"; do
      cp "$COMP_SRC" "$COMP_DIR/$name" 2>/dev/null || true
    done
    if [[ -f "$COMP_DIR/aether" ]]; then
      echo "Installed bash completions into $COMP_DIR"
    else
      echo "Note: could not write bash completions under $COMP_DIR (permissions?)"
      echo "  Source manually: source $COMP_SRC"
    fi
  else
    echo "Note: could not create $COMP_DIR — skip completions"
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
echo "Auth: export XAI_API_KEY=...  (optional: installed Rust grok for browser login only)"
echo
echo "Try: aether --version"
echo "     aether -p \"say hi\""
echo "     aether tui"
echo "     grok-odin --version   # same binary; does not clobber Rust grok"
