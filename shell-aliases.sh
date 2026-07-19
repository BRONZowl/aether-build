# Source this file to put Aether on PATH for this shell:
#   source /path/to/aether/shell-aliases.sh
#
# Distinct from Rust `grok` / `aether-grok` (xai-grok-pager).

_AETHER_ALIAS_SRC="${BASH_SOURCE[0]:-$0}"
while [ -L "$_AETHER_ALIAS_SRC" ]; do
  _AETHER_ALIAS_DIR="$(cd -P "$(dirname "$_AETHER_ALIAS_SRC")" && pwd)"
  _AETHER_ALIAS_SRC="$(readlink "$_AETHER_ALIAS_SRC")"
  case "$_AETHER_ALIAS_SRC" in
    /*) ;;
    *) _AETHER_ALIAS_SRC="$_AETHER_ALIAS_DIR/$_AETHER_ALIAS_SRC" ;;
  esac
done
_AETHER_DIR="$(cd -P "$(dirname "$_AETHER_ALIAS_SRC")" && pwd)"
_AETHER_REPO_ROOT="$(cd -P "$_AETHER_DIR/.." && pwd)"
unset _AETHER_ALIAS_SRC _AETHER_ALIAS_DIR

# Prefer aether-local wrapper (S1); fall back to monorepo compat shim.
if [ -x "$_AETHER_DIR/bin/aether" ]; then
  _AETHER_WRAP="$_AETHER_DIR/bin/aether"
else
  _AETHER_WRAP="$_AETHER_REPO_ROOT/bin/aether-grok-odin"
fi

alias aether-grok-odin="$_AETHER_WRAP"
alias aether="$_AETHER_WRAP"
alias grok-odin="$_AETHER_WRAP"

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

case ":$PATH:" in
  *":$_AETHER_DIR/bin:"*) ;;
  *) export PATH="$_AETHER_DIR/bin:$PATH" ;;
esac

unset _AETHER_DIR _AETHER_REPO_ROOT _AETHER_WRAP _td
