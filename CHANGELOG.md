# Changelog

All notable product milestones for **Aether** (Odin). Version remains `0.1.0-dev` until an explicit tag.

## Unreleased

### Wave 0–1 surface parity (skip billing)

- **Overlay kit** (`tui/overlay.odin`): `Overlay_Kind`, list-nav helpers, shared focus checks
- **Prompt queue**: mid-turn type + Enter enqueues; empty Enter force-sends #1 (cancel + drain); `/queue` pane; auto-drain after turn
- **Rewind picker**: bare `/rewind` lists user turns; Enter rewinds
- **Settings modal**: bare `/settings` browse/toggle (vim/compact/timestamps/multiline); **no billing** (`/usage` N/A)
- See `docs/COMMAND_PARITY.md`

### Transcript / tool output (Grok-shaped)

- User lines use `❯` (Grok prompt arrow) instead of `>`
- Tool cards: human titles (`Read path`, `$ cmd`, `Edited path`, …) — no `▸ [tool] name · (N lines)`
- Expanded tools show result body only (hide raw `args:…---` dump in the card)
- Tool cards stay **collapsed** by default (press expand for detail)
- **Slash menu dedupe:** `/session` → alias of `/session-info`; `/sessions` → alias of `/resume`; discover dumps (`/env`, `/paths`, `/doctor`, …) stay in `/help` but off bare-`/` list
- **Prefix matches:** at most one dropdown row per command (primary preferred over alias; no `/session` + `/session-info` twin rows)
- **Grok behavior align:** `/clear` = `/new`; `/usage`/`/cost` honest billing-N/A + context fallback; TUI bare `/sessions` opens session picker like `/resume`; catalog descs honest for non-modal cmds — see `docs/COMMAND_PARITY.md`
- **Remaining Grok slash commands** (text/TUI equivalents; honest N/A where blocked):
  - `/docs` (`/howto`), `/home` (`/welcome`), `/cd`, `/transcript` (`/log` + `$PAGER`), `/expand`, `/tasks`, `/queue`
  - `/release-notes` (`/changelog`), `/privacy`, `/terminal-setup`, `/toggle-mouse-reporting`
  - `/logout`, `/recap`, `/dashboard`, `/marketplace`, `/config-agents` (`/agents`), `/import-claude`, `/share`, `/voice`
  - Catalog order tracks Grok `builtin_commands()` for shared names
- **Output cleanup (Grok-shaped):**
  - **TUI:** blank gap between blocks; tool cards `│ Read path` / `│ $ cmd`; assistant markdown always styled (bold/code/headings) even with `NO_COLOR`
  - **Headless `-p`:** print **final answer only** (no mid-tool chatter, no auth banner); `AETHER_STREAM_STDOUT=1` for live tokens
  - stderr quiet unless `--verbose` or real errors


### Displayed slash commands (Grok-facing primaries)

- Single catalog `core/slash_catalog.odin` drives `/help`, `/aliases`, and the bare-`/` menu
- Primaries aligned with Grok Build where implemented: **`/quit`**, **`/settings`**, **`/mcps`**, **`/context`**, plus the rest of the Grok shared set (old names remain aliases)
- Bare `/` menu lists primaries only; typing an alias prefix still completes (e.g. `/ex` → `/exit`)
- **Startup banners** share `BRAND_STARTUP_SLASH_TIPS` (`/about · /help · /keys · /quit`): welcome tip, REPL no-art line, resume notice, CLI help uses `/quit`
- **Slash dropdown** matches Grok Build layout: top rule + count, `❯ /name` + description column, bottom rule; Grok-facing descriptions for shared commands
- **Bare-`/` menu order** follows Grok `builtin_commands()` for shared cmds (`/quit`, `/help`, `/docs`, `/home`, `/new`, …); Aether-only cmds after

### TUI chrome (Grok-shaped)

- Top bar: git branch + `~/cwd` (left) · plan/goal/todos/ctx/mode/model chips (right)
- Composer: blank pad + boxed prompt; session title on top rail; `model · mode` right-aligned on bottom rail; stronger border when prompt focused
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
