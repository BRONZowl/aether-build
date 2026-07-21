#!/usr/bin/env bash
# check-apache-compliance.sh — Apache-2.0 + redistributions hygiene for Aether.
# Exit 0 if required files and SPDX coverage are OK; non-zero on failure.
#
# Copyright 2023-2026 SpaceXAI
# SPDX-License-Identifier: Apache-2.0
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
need "SECURITY.md"

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

# README License section
if [[ -f "$ROOT/README.md" ]]; then
  if ! grep -q 'Apache License, Version 2.0' "$ROOT/README.md" && ! grep -q 'Apache License 2.0' "$ROOT/README.md"; then
    echo "FAIL: README.md missing Apache License section" >&2
    ok=0
  fi
  if ! grep -q 'NOTICE' "$ROOT/README.md"; then
    echo "FAIL: README.md should point at NOTICE" >&2
    ok=0
  fi
fi

# Brand art files present (derivative works documented in NOTICE)
need "assets/logo/logo05.txt"
need "assets/logo/logo07.txt"
need "core/brand.odin"

# Dist recipe should pack LICENSE+NOTICE
if [[ -f "$ROOT/Makefile" ]]; then
  if ! grep -q 'NOTICE' "$ROOT/Makefile"; then
    echo "FAIL: Makefile dist path should include NOTICE" >&2
    ok=0
  fi
fi

# Every first-party .odin file must carry SPDX Apache-2.0 (skip .tools)
missing=0
total=0
while IFS= read -r -d '' f; do
  total=$((total + 1))
  if ! head -n 30 "$f" | grep -q 'SPDX-License-Identifier: Apache-2.0'; then
    echo "MISSING SPDX: ${f#"$ROOT"/}" >&2
    missing=$((missing + 1))
    ok=0
  fi
done < <(find "$ROOT" -name '*.odin' \
  -not -path '*/.tools/*' \
  -not -path '*/.git/*' \
  -not -path '*/.grok/*' \
  -print0)

echo "SPDX coverage: $((total - missing))/$total first-party .odin files"

if [[ "$missing" -gt 0 ]]; then
  echo "FAIL: $missing file(s) missing SPDX-License-Identifier: Apache-2.0 in the first 30 lines" >&2
fi

# Discourage accidental non-Apache SPDX in first-party .odin
if grep -RIn --include='*.odin' --exclude-dir=.tools --exclude-dir=.git \
  -e 'SPDX-License-Identifier: GPL' \
  -e 'SPDX-License-Identifier: AGPL' \
  "$ROOT" 2>/dev/null | head -5 | grep -q .; then
  echo "FAIL: non-Apache SPDX identifier found in first-party .odin" >&2
  ok=0
fi

if [[ "$ok" -ne 1 ]]; then
  echo "Apache-2.0 compliance check FAILED" >&2
  exit 1
fi
echo "Apache-2.0 compliance check PASSED"
exit 0
