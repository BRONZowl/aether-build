#!/usr/bin/env bash
# check-apache-compliance.sh — quick Apache-2.0 hygiene for Aether redistributions.
# Exit 0 if required files are present; non-zero on missing compliance artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok=1

need() {
  local p="$1"
  if [[ ! -f "$ROOT/$p" ]]; then
    echo "MISSING: $p" >&2
    ok=0
  else
    echo "ok: $p"
  fi
}

need "LICENSE"
need "NOTICE"
need "assets/logo/NOTICE"
need "README.md"

# LICENSE should identify Apache 2.0
if [[ -f "$ROOT/LICENSE" ]]; then
  if ! grep -q 'Apache License' "$ROOT/LICENSE"; then
    echo "FAIL: LICENSE does not mention Apache License" >&2
    ok=0
  fi
  if ! grep -qi 'Copyright' "$ROOT/LICENSE"; then
    echo "FAIL: LICENSE missing Copyright line" >&2
    ok=0
  fi
fi

# NOTICE should mention provenance
if [[ -f "$ROOT/NOTICE" ]]; then
  if ! grep -qi 'Grok Build\|SpaceXAI\|Apache' "$ROOT/NOTICE"; then
    echo "FAIL: NOTICE missing expected attribution content" >&2
    ok=0
  fi
fi

# Brand art files present (derivative works documented in NOTICE)
need "assets/logo/logo05.txt"
need "assets/logo/logo07.txt"
need "core/brand.odin"

# brand.odin should carry SPDX / Apache pointer
if [[ -f "$ROOT/core/brand.odin" ]]; then
  if ! grep -q 'SPDX-License-Identifier: Apache-2.0' "$ROOT/core/brand.odin"; then
    echo "WARN: core/brand.odin missing SPDX-License-Identifier (recommended)" >&2
  fi
  if ! grep -qi 'NOTICE' "$ROOT/core/brand.odin"; then
    echo "WARN: core/brand.odin missing NOTICE pointer (recommended)" >&2
  fi
fi

# Dist recipe should pack LICENSE+NOTICE
if [[ -f "$ROOT/Makefile" ]]; then
  if ! grep -q 'NOTICE' "$ROOT/Makefile"; then
    echo "FAIL: Makefile dist path should include NOTICE" >&2
    ok=0
  fi
fi

if [[ "$ok" -ne 1 ]]; then
  echo "Apache-2.0 compliance check FAILED" >&2
  exit 1
fi
echo "Apache-2.0 compliance check PASSED"
exit 0
