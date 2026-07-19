# Aether standalone tree (S4)

This directory is a **standalone export** of the Aether (Odin) product.

- **Source of truth in monorepo:** `aether/` under the dual-product repo (Grok Build).
- **This extract** does **not** remove or replace the monorepo copy.
- **Build independence:** no Cargo, `crates/`, or Rust `grok` binary required.

## Quick start

```bash
make bootstrap-odin   # Odin → ./.tools (or set AETHER_TOOLS_DIR)
make build test smoke-tui
./bin/aether --version
./out/aether -p "say hi"
export XAI_API_KEY=...   # R0-A auth
make install             # ~/.local/bin: aether, grok-odin, aether-grok-odin
```

## How this tree was produced

```bash
# From monorepo root (default: snapshot, no history rewrite):
bash aether/scripts/export-standalone.sh --dest /path/to/this-tree
# Optional: preserve aether/ git history
bash aether/scripts/export-standalone.sh --dest /path/to/this-tree --git-history
```

Export mode used for **this** tree: **snapshot**

## Docs

- [README.md](./README.md) — product overview
- [PORTING.md](./PORTING.md) — parity / separation ledger
- LICENSE — Apache-2.0 (copied from monorepo when present)

## Monorepo-only helpers

`make inventory-rust` / `scripts/inventory-rust-tree.sh` list sibling Rust
paths when this tree still sits next to `crates/`. In a pure standalone clone
they exit cleanly with a monorepo-only notice.
