# Changelog

All notable product milestones for **Aether** (Odin). Version remains `0.1.0-dev` until an explicit tag.

## Unreleased

### TUI chrome (Grok-shaped)

- Top bar: git branch + `~/cwd` (left) · plan/goal/todos/ctx/mode/model chips (right)
- Composer: `❯` prefix, empty placeholder, dim `model · mode` info line under input
- `core/git_info`: cached branch from `.git/HEAD` + home-collapse cwd display

### Cleanup (E1–E3 + emit/json)

- Soft-bash: unify `bash_sub_in` → `bash_token_in`; table-drive matchers across pkg/tools/cloud/container
- Shared helpers: `bash_nested_allow`; slash `emit_line`/`emit_lines`; `slash_ui_bool` for UI prefs
- `core.json_string_escape` shared by agent/hooks/mcp/tools (thin package aliases)
- `new_session` sessions_dir own-once; test suites free `fmt.aprintf` / temp dir path strings

### Launcher / defaults

- Primary install name **`aether-grok`** (always); short `aether` only when it won’t shadow foreign binaries (e.g. Arch theme package at `/usr/bin/aether`)
- Bare invoke (no args) starts **TUI** on a TTY; otherwise line REPL; use `chat`/`repl` for explicit REPL

### Ship readiness (final polish)

- Docs truth-up: README auth/login (device-code M7), slash list, non-goals, standalone-first paths
- `scripts/parity-inventory.py`: hashline pack labeled **OPTIN Full** (not bare N/A)
- `/doctor` reports brand ASCII art on/off
- Empty TUI: avoid duplicate tip notice when brand welcome tips already show
- Install script auth hint matches M7

### Visual parity (V1)

- Grok Build–parity welcome layout; Braille mark = Grok shell with “A” in the center
- Empty TUI welcome, REPL startup banner, `/about` art
- `AETHER_NO_ASCII_ART` / `AETHER_ASCII_ART`; `/features` row `ascii-art`

### Ship-hardening max (Phase M)

| Epic | Summary |
|------|---------|
| **M1** | Folder trust + `/hooks trust\|untrust` |
| **M2** | `/goal --budget` + token pause |
| **M3** | MCP enroll / set-token polish (DCR still host-assisted) |
| **M4** | Local `/plugins` list/add/remove/reload |
| **M5** | Opt-in `AETHER_TOOL_PACK=hashline` |
| **M6** | `AETHER_OS_SANDBOX=soft\|bwrap` shell isolation |
| **M7** | In-process device-code login |
| **M8** | Mermaid Unicode flowchart/sequence layout |
| **M9** | Subagent `persona=` from `~/.grok/personas` |
| **M10** | `/create-skill` scaffold |

### Prior ship path (summary)

Phases **A** (tools), **B** (shell/slash/TUI chrome), **C1–C2** (pager), **S0–S4** (dual-product separation / standalone export), **R0–R4** (Odin-only charter) — see [PORTING.md](./PORTING.md).

## Intentional residuals (not bugs)

ACP multi-client, remote marketplace, Mixpanel/voice/self-update, mermaid PNG/SVG, in-process Landlock, full MCP browser OAuth DCR, SQLite memory, remote Auto classifier — documented N/A in PORTING.

## Known test hygiene (non-blocking)

Full `odin test agent` suite occasionally SIGSEGV in `test_slash_help_and_unknown` / `test_slash_new_session_changed` when run after heavy tests (heap/leak noise). Same tests pass in isolation; pre-existed final polish. `tools` / `core` / `tui` / `smoke-tui` green.
