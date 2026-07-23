# Changelog

All notable product milestones for **Aether** (Odin). Version remains `0.1.0-dev` until an explicit tag.

## Unreleased

### Plan mode (Grok parity)

- **Plan approval view** on `exit_plan_mode`: scrollable plan preview (or empty-plan placeholder), action bar **`a` approve · `s` request changes · `q` quit**, line comments (`c`/Enter), Tab preview↔feedback prompt
- REPL exit prompts use the same **a/s/q** letters (legacy y/n still accepted)
- **Shift+Tab** ring matches Grok: **Normal → Plan → Always-approve → Normal** (Auto/Read-only stay on settings/slash, not this ring)
- `/keys` documents plan-approval shortcuts
- **`/view-plan`** (TUI): scrollable read-only plan preview (`q`/Esc close); REPL still dumps text

### Fix: scroll + permission keys (Grok parity)

- Scroll: Ctrl+D half-page down (quit is Ctrl+Q only); mouse 1002 + wheel buttons 4/5; CSI-u PageUp/Down/arrows; status shows when detached from follow; Home/End jump in scrollback
- Mid-stream history expands on first scroll-up so older messages are reachable
- Permission prompts: Grok numbered radio list (`1 Allow once`, `2 Always allow on all sessions`, …) with **1-9 / j/k / Enter / Esc** — not y/n/a/d

### Fix: unable to scroll transcript

- Free wheel / PgUp / Ctrl+U no longer snaps back to the selected scrollback block every paint (ensure-visible only after selection moves)
- Mid-stream history tail expands when you scroll up so older messages are reachable before the turn ends

### TUI chrome (context + effort)

- Top bar: drop permission/model chips; show Grok-style context **`used / window`** (e.g. `12K / 131K`)
- Composer bottom rail: **`model · [effort] · mode`** so `/effort` updates live on the input frame
- Compact token formatting helper shared with context estimates
- **Fix `/clear`/`/new`:** abort sticky mid-turn streaming chrome, re-focus prompt, clamp selection, keep live session pointer for context bar
- Composer chrome: plan = golden border/`❯`; default border = neutral `prompt_border*`
- Bottom-rail **mode flags only** are distinctly colored: plan=gold, always-approve=yellow, auto=blue, ask=user, read-only=dim; caption shows `plan` while plan mode is active

### Fix: HTTP 400 “failed to parse as JSON” after tool results

- Memory snippets (and other truncations) no longer cut mid–UTF-8 multi-byte character
- `json_string_escape` replaces invalid UTF-8 with U+FFFD so chat request bodies stay valid JSON
- Root cause: `memory_search` capped snippets at 1200 **bytes**, splitting e.g. `—` (`e2 80 94`) and poisoning the next API request / session file

### Docs

- README streamlined: install-first, shorter feature/TUI sections; deep detail → `/help` and packaging docs

### Package-manager install (AUR + Homebrew)

- `make install-prefix` / `scripts/install-prefix.sh` — FHS install of `aether-grok` (+ odin name symlinks)
- AUR skeleton: `packaging/aur/aether-grok-git/` (`makepkg -si` or publish for `yay -S aether-grok-git`)
- Homebrew skeleton: `packaging/homebrew/aether-grok.rb` (`brew install --build-from-source ./…`)
- Docs: `packaging/README.md` + README quick-start table

### Maintainability (P0–P5)

- Shared env/feature helpers (`core/env_flag`); kill-switches route through `feature_killed` / `feature_enabled`
- Tool schema registry (`tools/registry.odin`) single SoT; `Tool_Spec.perm` aligned with `core.TOOL_PERM_TABLE` (P2.3)
- Slash table dispatch (`agent/slash_table.odin`) for emit-only commands; catalog coverage test
- Soft-bash: `Cli_Readonly_Spec` walker + data-driven allow/deny/value tables across tools/pkg/cloud/container
- Soft-bash golden matrix expanded (aws/gcloud/az, curl/wget, redis, pacman, poetry, just, …)
- Media path helpers + `Turn_Options` field groups (nested structs deferred)

### TUI loading spinner

- Braille spinner (`⠋⠙⠹…`) on the **status bar** for the whole agent turn
- Body placeholder **`Waiting for response…`** until the first streamed tokens
- Frames advance from mid-turn poll/status (~80ms); hidden during ask modals

### TUI chrome cleanup

- Idle **`ready | Enter send · Ctrl+F…`** status row above the composer is **hidden**
- Status row still appears while generating, in modals/ask, scrollback, multiline, and slash menu

### Calmer assistant markdown

- Softer emphasis: bold without bright-white; inline code uses dim (not reverse video)
- Quieter headings/list bullets; monochrome/`NO_COLOR` paints plain text (markers stripped)
- Theme-aware bold/dim for inline spans; restore prose fg after truecolor dim
- Ordered lists (`1. `) paint with dim markers; unordered still dim `•`
- Code fence chrome quieted (`── lang ──`); header/footer **Dim**, body **Code**
- GFM tables: header Bold, separator Dim, body Assistant (not a full code block)
- Blank line before fences/tables when the previous line is non-empty

### Startup slash tips

- Tips set `/about · /help · /keys · /quit` only on **empty-session welcome** and **REPL no-art** banner
- No longer injected as a transcript notice when resuming a session

### Hang hardening (force-quit freezes)

- FG shell (`run_terminal_cmd`) honors **Ctrl+C cancel** and kills the process
- `wait_tasks` / task wait loops check cancel between polls
- Clipboard helpers use **2s** process wait + kill (no infinite hang on wl-copy/xclip)
- Queue auto-drains **at most one** follow-up per turn (notice if more remain)
- Optional `AETHER_DEBUG_HANG=1` → `~/.grok/aether/hang.log`; see `docs/HANGS.md`


### /fork worktree (Grok-shaped)

- `/fork [--worktree|--no-worktree] [title]` — peer session clone
- TUI bare `/fork` asks worktree vs same workspace every time
- `--worktree` creates detached git worktree under `~/.grok/aether/worktrees/` and sets session cwd
- Directive/title fills composer after fork (not auto-submitted)

### Remaining surfaces (except billing)

- **Command palette** (`/help`): searchable slash list; Enter inserts into composer
- **Docs picker** (`/docs`): local markdown + web Build docs + discover shortcuts
- **Personas/agents modal** (`/personas`, `/config-agents`): list types/personas, open in pager, `n` scaffold stub
- **Privacy persist**: `/privacy opt-in|opt-out` → `[privacy] coding_data_share` in config.toml
- **Import Claude apply**: `/import-claude apply` merges `mcpServers` into ~/.grok/config.toml
- **Share local**: `/share` exports transcript + copies path to clipboard
- **Settings**: cycle theme/permission, open model picker, privacy toggle (still no billing)
- Voice remains **N/A**; billing remains **N/A**

### Wave 4 — btw + recap

- `/btw <question>`: short side-agent completion (not appended to session history); offline → local note
- `/recap`: model "where was I" summary from recent turns; offline/error → local turn list

### Wave 3 — dashboard

- Interactive `/dashboard` (and bare `/tasks`): sessions (Enter load), background tasks (`k` kill), scheduled list
- `r` refresh · Esc close

### Wave 2 — extensions hub

- Tabbed TUI modal: **Hooks · Plugins · Skills · MCPs · Market** (`tui/extensions_hub.odin`)
- Bare `/hooks`, `/plugins`, `/skills`, `/mcps`, `/marketplace` open the hub (args still use text CLI handlers)
- `r` reload · `t` trust · ←/→ or Tab switch · 1–5 jump tabs

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
  - **TUI:** blank gap between blocks; tool cards `│ Read path` / `│ $ cmd`; assistant markdown uses soft emphasis (no reverse code / bright bold); monochrome strips markers plain
  - **Headless `-p`:** print **final answer only** (no mid-tool chatter, no auth banner); `AETHER_STREAM_STDOUT=1` for live tokens
  - stderr quiet unless `--verbose` or real errors


### Displayed slash commands (Grok-facing primaries)

- Single catalog `core/slash_catalog.odin` drives `/help`, `/aliases`, and the bare-`/` menu
- Primaries aligned with Grok Build where implemented: **`/quit`**, **`/settings`**, **`/mcps`**, **`/context`**, plus the rest of the Grok shared set (old names remain aliases)
- Bare `/` menu lists primaries only; typing an alias prefix still completes (e.g. `/ex` → `/exit`)
- **Startup banners** share `BRAND_STARTUP_SLASH_TIPS` (`/about · /help · /keys · /quit`): empty-session welcome tip + REPL no-art line only (not resume transcript notices)
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
