# bash completion for aether / aether-grok-odin
# Install: source this file, or copy to bash-completion completions dir.

_aether_grok_odin() {
  local cur prev words cword
  if declare -F _init_completion >/dev/null 2>&1; then
    _init_completion || return
  else
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
  fi

  local cmds="chat repl tui whoami help version"
  local opts="
    -p --print --single
    -m --model
    --max-turns
    --cwd
    -q --quiet
    --verbose
    --permission-mode
    --yolo --always-approve
    --read-only
    --session
    -c --continue
    --no-autosave
    --no-mcp
    --sessions-dir
    -h --help
    -v -V --version
  "

  case "$prev" in
    --permission-mode)
      COMPREPLY=( $(compgen -W "always-approve read-only ask" -- "$cur") )
      return
      ;;
    -m|--model)
      COMPREPLY=( $(compgen -W "grok-4.5 grok-build" -- "$cur") )
      return
      ;;
    --cwd|--sessions-dir)
      COMPREPLY=( $(compgen -d -- "$cur") )
      return
      ;;
    --session)
      local sess_dir="${AETHER_SESSIONS_DIR:-$HOME/.grok/aether/sessions}"
      if [[ -d "$sess_dir" ]]; then
        local ids
        ids=$(basename -a "$sess_dir"/*.json 2>/dev/null | sed 's/\.json$//' || true)
        COMPREPLY=( $(compgen -W "$ids" -- "$cur") )
      else
        COMPREPLY=( $(compgen -f -- "$cur") )
      fi
      return
      ;;
    -p|--print|--single|--max-turns)
      # freeform
      return
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return
  fi

  COMPREPLY=( $(compgen -W "$cmds $opts" -- "$cur") )
}

complete -F _aether_grok_odin aether-grok-odin
complete -F _aether_grok_odin aether
complete -F _aether_grok_odin grok-odin
