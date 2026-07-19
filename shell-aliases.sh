# Source this file to put Aether on PATH for this shell:
#   source /path/to/aether-grok-build/shell-aliases.sh
#   # or monorepo: source aether/shell-aliases.sh
#
# Distinct from Rust `grok` / `aether-grok` (xai-grok-pager).
# Prefer PATH install (make install → aether-grok-odin / grok-odin) over aliases.
# Note: plain `aether` may already be Arch's theme generator (/usr/bin/aether).

# Use builtin cd — user shells often wrap `cd` (zoxide, etc.) which breaks path resolve.
_AETHER_ALIAS_SRC="${BASH_SOURCE[0]:-$0}"
while [ -L "$_AETHER_ALIAS_SRC" ]; do
  _AETHER_ALIAS_DIR="$(builtin cd -P "$(dirname "$_AETHER_ALIAS_SRC")" && pwd)"
  _AETHER_ALIAS_SRC="$(readlink "$_AETHER_ALIAS_SRC")"
  case "$_AETHER_ALIAS_SRC" in
    /*) ;;
    *) _AETHER_ALIAS_SRC="$_AETHER_ALIAS_DIR/$_AETHER_ALIAS_SRC" ;;
  esac
done
_AETHER_DIR="$(builtin cd -P "$(dirname "$_AETHER_ALIAS_SRC")" && pwd)"
_AETHER_REPO_ROOT="$(builtin cd -P "$_AETHER_DIR/.." && pwd)"
unset _AETHER_ALIAS_SRC _AETHER_ALIAS_DIR

# Prefer aether-local wrapper (S1); fall back to monorepo compat shim.
if [ -x "$_AETHER_DIR/bin/aether" ]; then
  _AETHER_WRAP="$_AETHER_DIR/bin/aether"
elif [ -x "$_AETHER_REPO_ROOT/bin/aether-grok-odin" ]; then
  _AETHER_WRAP="$_AETHER_REPO_ROOT/bin/aether-grok-odin"
else
  _AETHER_WRAP="$_AETHER_DIR/bin/aether"
fi

# Product names (safe; do not clobber Rust grok)
alias aether-grok-odin="$_AETHER_WRAP"
alias grok-odin="$_AETHER_WRAP"

# Short name only if it won't hide a foreign `aether` (e.g. Arch theme tool).
# Check the existing on-PATH binary (not our wrapper) before aliasing.
if ! command -v aether >/dev/null 2>&1; then
  alias aether="$_AETHER_WRAP"
else
  _aether_existing="$(command -v aether)"
  _aether_ver="$("$_aether_existing" --version 2>/dev/null | head -1 || true)"
  case "$_aether_ver" in
    aether-grok*|Aether-Grok*) alias aether="$_AETHER_WRAP" ;;
    *) ;; # leave system/foreign aether alone
  esac
  unset _aether_existing _aether_ver
fi

# Tools: aether/.tools then monorepo .tools
for _td in "$_AETHER_DIR/.tools" "$_AETHER_REPO_ROOT/.tools"; do
  if [ -d "$_td/bin" ]; then
    case ":$PATH:" in
      *":$_td/bin:"*) ;;
      *) export PATH="$_td/bin:$PATH" ;;
    esac
  fi
  if [ -d "$_td/odin" ]; then
    export ODIN_ROOT="${ODIN_ROOT:-$_td/odin}"
  fi
done

# Do not prepend $_AETHER_DIR/bin to PATH: that directory's `aether` launcher
# would shadow foreign tools also named aether (e.g. Arch theme generator).
# Aliases above point at the absolute wrapper path instead.

unset _AETHER_DIR _AETHER_REPO_ROOT _AETHER_WRAP _td
