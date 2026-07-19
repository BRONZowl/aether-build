#!/usr/bin/env python3
"""Product-contract parity inventory: Grok Build (Rust) vs Aether (Odin).

Usage (from aether tree or with paths):
  python3 scripts/parity-inventory.py
  GROK_BUILD=/path/to/grok-build python3 scripts/parity-inventory.py

Compares default GrokBuild model tools and shell builtin slash commands.
Default pack tools must HIT. Opt-in packs (hashline) are OPTIN Full.
True N/A (deploy_app, codex/opencode) stay N/A. Dropped L4 is out of inventory.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

AETHER_DIR = Path(__file__).resolve().parent.parent
DEFAULT_GROK = AETHER_DIR.parent / "grok-build"
GROK = Path(os.environ.get("GROK_BUILD", DEFAULT_GROK))

# Default GrokBuild ship tools (canonical names exposed to the model).
SHIP_TOOLS = [
    "run_terminal_cmd",
    "read_file",
    "search_replace",
    "grep",
    "list_dir",
    "web_fetch",
    "web_search",
    "todo_write",
    "ask_user_question",
    "enter_plan_mode",
    "exit_plan_mode",
    "lsp",
    "monitor",
    "scheduler_create",
    "scheduler_list",
    "scheduler_delete",
    "update_goal",
    "image_gen",
    "image_edit",
    "image_to_video",
    "reference_to_video",
    "spawn_subagent",  # Rust: task
    "task",
    "get_task_output",
    "kill_task",
    "wait_tasks",
    "skill",
    "search_tool",
    "use_tool",
    "memory_search",
    "memory_get",
    # MCP metas (when servers connect)
    "list_mcp_resources",
    "read_mcp_resource",
    "list_mcp_prompts",
    "get_mcp_prompt",
]

# Aether super-set (not required for GrokBuild default pack)
AETHER_EXTRA = ["write", "glob", "delete_file", "wait_commands_or_subagents"]

# Explicit N/A product tools (not ship-path defaults)
NA_TOOLS = {
    "deploy_app": "Grok stub / app-builder service; keep N/A",
}

# Opt-in Full (implemented; not in default GrokBuild pack)
OPTIN_TOOLS = {
    "hashline_read": "M5 AETHER_TOOL_PACK=hashline (mutual exclusion)",
    "hashline_edit": "M5 AETHER_TOOL_PACK=hashline (mutual exclusion)",
    "hashline_grep": "M5 AETHER_TOOL_PACK=hashline (mutual exclusion)",
}

# Grok shell BUILTIN_COMMANDS + PROMPT_COMMANDS → Aether mapping
SLASH_MAP = [
    ("compact", ["/compact"], "Full"),
    ("always-approve", ["/always-approve", "/yolo"], "Full"),
    ("flush", ["/flush"], "Full"),
    ("dream", ["/dream"], "Full"),
    ("memory", ["/memory"], "Full"),
    ("context", ["/context", "/usage", "/cost"], "Full"),
    ("hooks-list", ["/hooks"], "Full"),
    ("hooks-add", ["/hooks"], "Full"),
    ("hooks-remove", ["/hooks"], "Full"),
    ("hooks-trust", ["/hooks"], "Full — /hooks trust (M1)"),
    ("hooks-untrust", ["/hooks"], "Full — /hooks untrust (M1)"),
    ("plugins", ["/plugins"], "Full (M4 MVP local)"),
    ("reload-plugins", ["/plugins"], "Full — /plugins reload"),
    ("session-info", ["/session", "/session-info", "/status"], "Full"),
    ("feedback", ["/feedback"], "Full — local JSONL; remote API N/A"),
    ("goal", ["/goal"], "Full — --budget N + pause (M2)"),
    ("loop", ["/loop"], "Full"),
]


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="ignore") if p.exists() else ""


def aether_tools() -> set[str]:
    text = read(AETHER_DIR / "tools" / "tools.odin")
    names = set(re.findall(r'"name":"([a-zA-Z0-9_]+)"', text))
    loop = read(AETHER_DIR / "agent" / "loop.odin")
    names |= set(re.findall(r'name == "([a-zA-Z0-9_]+)"', loop))
    names |= set(re.findall(r'case "([a-zA-Z0-9_]+)":', text))
    meta = read(AETHER_DIR / "mcp" / "tools_meta.odin")
    names |= set(re.findall(r'case "([a-zA-Z0-9_]+)":', meta))
    names -= {"FOO", "X"}
    return names


def aether_slash() -> set[str]:
    text = read(AETHER_DIR / "agent" / "slash.odin")
    return set(re.findall(r'"(/[a-zA-Z0-9_-]+)"', text))


def rust_tool_ids() -> set[str]:
    imp = GROK / "crates/codegen/xai-grok-tools/src/implementations"
    ids: set[str] = set()
    if not imp.exists():
        return ids
    for p in imp.rglob("*.rs"):
        t = read(p)
        ids |= set(re.findall(r'ToolId::new\("([a-zA-Z0-9_]+)"\)', t))
    return ids


def rust_slash() -> list[str]:
    p = GROK / "crates/codegen/xai-grok-shell/src/session/slash_commands.rs"
    t = read(p).split("#[cfg(test)]")[0]
    return re.findall(r'name:\s*"([a-zA-Z0-9_-]+)"', t)


def git_rev() -> str:
    if not (GROK / ".git").exists() and not (GROK / ".git").is_file():
        # may be worktree
        pass
    try:
        return subprocess.check_output(
            ["git", "-C", str(GROK), "rev-parse", "--short", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return "unknown"


def main() -> int:
    if not GROK.is_dir():
        print(f"error: grok-build not found at {GROK}", file=sys.stderr)
        print("set GROK_BUILD=/path/to/grok-build", file=sys.stderr)
        return 1

    ae = aether_tools()
    ae_slash = aether_slash()
    rust_ids = rust_tool_ids()
    rev = git_rev()

    print(f"# Product-contract parity inventory")
    print(f"aether: {AETHER_DIR}")
    print(f"grok-build: {GROK} @ {rev}")
    print()

    print("## Model tools (default GrokBuild pack)")
    miss = 0
    for t in SHIP_TOOLS:
        ok = t in ae or (t == "spawn_subagent" and "task" in ae)
        rust_hint = "rust+" if t in rust_ids or t == "spawn_subagent" else "rust?"
        # task is rust name for spawn
        if t == "spawn_subagent":
            rust_hint = "rust+" if "task" in rust_ids or "spawn_subagent" in rust_ids else rust_hint
        status = "HIT" if ok else "MISS"
        if not ok:
            miss += 1
        print(f"  {status:4}  {t:28}  aether={'yes' if ok else 'NO'}  ({rust_hint})")
    for t, reason in NA_TOOLS.items():
        print(f"  N/A   {t:28}  {reason}")
    for t, reason in OPTIN_TOOLS.items():
        ok = t in ae
        status = "OPTIN" if ok else "MISS"
        if not ok:
            miss += 1
        print(f"  {status:5} {t:28}  {reason}")
    print("  Aether extras (super-set):", ", ".join(AETHER_EXTRA))
    print()

    print("## Slash builtins (Grok shell BUILTIN + PROMPT)")
    for name, aliases, note in SLASH_MAP:
        present = any(a in ae_slash for a in aliases) if aliases else False
        if note.startswith("N/A"):
            print(f"  N/A   /{name:20}  {note}")
        elif present:
            print(f"  HIT   /{name:20}  {note}  → {aliases[0]}")
        else:
            miss += 1
            print(f"  MISS  /{name:20}  expected one of {aliases}")
    print()

    print("## Summary")
    if miss:
        print(f"MISSING ship-path items: {miss}")
        return 2
    print(
        "OK: all default GrokBuild tools present; opt-in packs Full; "
        "slash builtins Full or intentional N/A"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
