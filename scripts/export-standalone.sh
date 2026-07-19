#!/usr/bin/env bash
# S4 — Export Aether as a standalone product tree (source).
# Does NOT remove or alter monorepo aether/; does not push remotes.
#
# Usage:
#   bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone
#   bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone --verify
#   bash aether/scripts/export-standalone.sh --dest /tmp/aether-hist --git-history
#   make -C aether extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'
#
# Modes:
#   --snapshot (default)  rsync product sources into DEST
#   --git-history         git subtree split --prefix=aether into DEST
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AETHER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MONOREPO_ROOT="$(cd "$AETHER_DIR/.." && pwd)"

DEST=""
MODE="snapshot"
FORCE=0
INIT_GIT=0
VERIFY=0
SPLIT_BRANCH="aether-s4-split-$$"
GIT_HISTORY_BRANCH=""

log() { printf 'export-standalone: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

usage() {
  cat <<'EOF'
Export Aether (aether/) as a standalone source tree (S4).

  --dest DIR          Destination directory (required)
  --snapshot          Copy sources with rsync (default)
  --git-history       Preserve aether/ git history via subtree split
  --force             Allow non-empty DEST (clears contents carefully)
  --init-git          After snapshot: git init + initial commit in DEST
  --verify            Run make build vet test smoke-tui in DEST
  -h, --help          This help

Examples:
  bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone
  bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone --verify
  make -C aether extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'

Does not delete monorepo aether/ or crates/. Does not push remotes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || die "--dest requires a path"
      DEST="$2"
      shift 2
      ;;
    --dest=*)
      DEST="${1#--dest=}"
      shift
      ;;
    --snapshot)
      MODE="snapshot"
      shift
      ;;
    --git-history)
      MODE="git-history"
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --init-git)
      INIT_GIT=1
      shift
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (try --help)"
      ;;
  esac
done

[[ -n "$DEST" ]] || die "required: --dest DIR"
[[ -d "$AETHER_DIR" ]] || die "aether dir missing: $AETHER_DIR"
[[ -f "$AETHER_DIR/Makefile" ]] || die "not an aether product tree: $AETHER_DIR"

# Resolve DEST absolute (may not exist yet)
DEST="$(mkdir -p "$(dirname "$DEST")" 2>/dev/null; cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"

if [[ -e "$DEST" ]]; then
  if [[ -n "$(ls -A "$DEST" 2>/dev/null || true)" ]]; then
    if [[ "$FORCE" != "1" ]]; then
      die "DEST is non-empty: $DEST (pass --force to replace contents)"
    fi
    log "DEST non-empty; --force: removing contents under $DEST"
    if [[ "$DEST" == "$AETHER_DIR" || "$DEST" == "$MONOREPO_ROOT" ]]; then
      die "refusing to wipe monorepo path: $DEST"
    fi
    find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
else
  mkdir -p "$DEST"
fi

write_standalone_ci() {
  local wf_dir="$DEST/.github/workflows"
  mkdir -p "$wf_dir"
  cat >"$wf_dir/aether.yml" <<'YAML'
# Standalone Aether CI (S4 extract). Odin only — no Cargo/Rust.
name: Aether (Odin)

on:
  push:
    branches: [aether, main, master]
  pull_request:
  workflow_dispatch:

concurrency:
  group: aether-odin-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-test:
    name: build · vet · test · smoke-tui
    runs-on: ubuntu-latest
    timeout-minutes: 60

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            build-essential \
            clang \
            llvm \
            llvm-dev \
            libcurl4-openssl-dev \
            ripgrep \
            bsdutils

      - name: Bootstrap Odin
        run: bash scripts/bootstrap-odin.sh

      - name: Build, vet, test, smoke-tui
        env:
          AETHER_NO_DESKTOP_NOTIFY: "1"
        run: |
          for d in "${GITHUB_WORKSPACE}/.tools"; do
            if [[ -x "$d/bin/odin" ]]; then
              export PATH="$d/bin:${PATH}"
              export ODIN_ROOT="$d/odin"
              break
            fi
          done
          make build vet test smoke-tui

      - name: Binary version
        run: ./out/aether --version
YAML
}

write_standalone_md() {
  cat >"$DEST/STANDALONE.md" <<EOF
# Aether standalone tree (S4)

This directory is a **standalone export** of the Aether (Odin) product.

- **Source of truth in monorepo:** \`aether/\` under the dual-product repo (Grok Build).
- **This extract** does **not** remove or replace the monorepo copy.
- **Build independence:** no Cargo, \`crates/\`, or Rust \`grok\` binary required.

## Quick start

\`\`\`bash
make bootstrap-odin   # Odin → ./.tools (or set AETHER_TOOLS_DIR)
make build test smoke-tui
./bin/aether --version
./out/aether -p "say hi"
export XAI_API_KEY=...   # R0-A auth
make install             # ~/.local/bin: aether, grok-odin, aether-grok-odin
\`\`\`

## How this tree was produced

\`\`\`bash
# From monorepo root (default: snapshot, no history rewrite):
bash aether/scripts/export-standalone.sh --dest /path/to/this-tree
# Optional: preserve aether/ git history
bash aether/scripts/export-standalone.sh --dest /path/to/this-tree --git-history
\`\`\`

Export mode used for **this** tree: **${MODE}**

## Docs

- [README.md](./README.md) — product overview
- [PORTING.md](./PORTING.md) — parity / separation ledger
- LICENSE — Apache-2.0 (copied from monorepo when present)

## Monorepo-only helpers

\`make inventory-rust\` / \`scripts/inventory-rust-tree.sh\` list sibling Rust
paths when this tree still sits next to \`crates/\`. In a pure standalone clone
they exit cleanly with a monorepo-only notice.
EOF
}

copy_license() {
  if [[ -f "$MONOREPO_ROOT/LICENSE" ]]; then
    cp -f "$MONOREPO_ROOT/LICENSE" "$DEST/LICENSE"
    log "copied LICENSE from monorepo root"
  elif [[ -f "$AETHER_DIR/LICENSE" ]]; then
    cp -f "$AETHER_DIR/LICENSE" "$DEST/LICENSE"
  else
    log "warning: no LICENSE found to copy"
  fi
}

export_snapshot() {
  log "snapshot export: $AETHER_DIR -> $DEST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a \
      --exclude '.tools/' \
      --exclude 'out/' \
      --exclude '.git/' \
      --exclude '*.o' \
      --exclude '.DS_Store' \
      "$AETHER_DIR"/ "$DEST"/
  else
    # portable fallback
    (
      cd "$AETHER_DIR"
      tar \
        --exclude='.tools' \
        --exclude='out' \
        --exclude='.git' \
        --exclude='.DS_Store' \
        -cf - .
    ) | (cd "$DEST" && tar -xf -)
  fi
}

export_git_history() {
  command -v git >/dev/null 2>&1 || die "git required for --git-history"
  [[ -d "$MONOREPO_ROOT/.git" ]] || die "monorepo is not a git checkout: $MONOREPO_ROOT"

  GIT_HISTORY_BRANCH="${SPLIT_BRANCH}"
  log "git subtree split --prefix=aether -> branch $GIT_HISTORY_BRANCH (may take a while)"
  (
    cd "$MONOREPO_ROOT"
    # Clean leftover branch name if any
    git branch -D "$GIT_HISTORY_BRANCH" 2>/dev/null || true
    git subtree split --prefix=aether -b "$GIT_HISTORY_BRANCH"
  )

  log "checking out split branch into $DEST"
  # git clone needs DEST absent or empty
  if [[ -d "$DEST" ]]; then
    rmdir "$DEST" 2>/dev/null || {
      find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      rmdir "$DEST" 2>/dev/null || true
    }
  fi
  git clone --branch "$GIT_HISTORY_BRANCH" --single-branch --local "$MONOREPO_ROOT" "$DEST"

  # Drop temporary split branch from monorepo (history remains in DEST/.git)
  (
    cd "$MONOREPO_ROOT"
    git branch -D "$GIT_HISTORY_BRANCH" 2>/dev/null || true
  )
  log "monorepo temporary split branch removed; history lives in DEST/.git"
}

post_process() {
  write_standalone_ci
  write_standalone_md
  copy_license
  # Ensure scripts executable
  if [[ -d "$DEST/scripts" ]]; then
    chmod +x "$DEST/scripts"/*.sh 2>/dev/null || true
  fi
  if [[ -x "$DEST/bin/aether" ]] || [[ -f "$DEST/bin/aether" ]]; then
    chmod +x "$DEST/bin/aether" 2>/dev/null || true
  fi
}

maybe_init_git() {
  if [[ "$INIT_GIT" != "1" ]]; then
    return 0
  fi
  if [[ "$MODE" == "git-history" ]]; then
    log "--init-git ignored with --git-history (DEST already has .git)"
    return 0
  fi
  if [[ -d "$DEST/.git" ]]; then
    log "DEST already has .git — skip --init-git"
    return 0
  fi
  command -v git >/dev/null 2>&1 || die "git required for --init-git"
  (
    cd "$DEST"
    git init
    git add -A
    git -c user.email="aether-export@localhost" -c user.name="Aether S4 Export" \
      commit -m "Initial import: Aether standalone extract (S4 snapshot)"
  )
  log "initialized git repo in DEST"
}

run_verify() {
  if [[ "$VERIFY" != "1" ]]; then
    return 0
  fi
  log "verify: make build vet test smoke-tui in $DEST"

  # Prefer monorepo/aether tools to avoid full Odin rebuild
  local tools=""
  if [[ -n "${AETHER_TOOLS_DIR:-}" && -x "${AETHER_TOOLS_DIR}/bin/odin" ]]; then
    tools="$AETHER_TOOLS_DIR"
  elif [[ -x "$AETHER_DIR/.tools/bin/odin" ]]; then
    tools="$AETHER_DIR/.tools"
  elif [[ -x "$MONOREPO_ROOT/.tools/bin/odin" ]]; then
    tools="$MONOREPO_ROOT/.tools"
  fi

  (
    cd "$DEST"
    if [[ -n "$tools" ]]; then
      export AETHER_TOOLS_DIR="$tools"
      export PATH="$tools/bin:${PATH}"
      export ODIN_ROOT="${ODIN_ROOT:-$tools/odin}"
      log "verify using AETHER_TOOLS_DIR=$tools"
    else
      log "no prebuilt tools found — running bootstrap-odin in DEST"
      make bootstrap-odin
      if [[ -x "$DEST/.tools/bin/odin" ]]; then
        export PATH="$DEST/.tools/bin:${PATH}"
        export ODIN_ROOT="$DEST/.tools/odin"
      fi
    fi
    export AETHER_NO_DESKTOP_NOTIFY=1
    make build vet test smoke-tui
    ./out/aether --version
  )
  log "verify: ok"
}

# --- main ---
case "$MODE" in
  snapshot) export_snapshot ;;
  git-history) export_git_history ;;
  *) die "internal: bad mode $MODE" ;;
esac

post_process
maybe_init_git
run_verify

log "done: standalone tree at $DEST"
log "monorepo aether/ unchanged at $AETHER_DIR"
echo "$DEST"
