<h1 align="center">Aether</h1>


**Aether** is a high-performance coding agent written in **Odin**: headless one-shots, multi-turn REPL, and a fullscreen terminal UI.

It is a **peer product** to [Grok Build](https://x.ai/cli) (the Rust `grok` CLI): same problem space and compatible `~/.grok` interop where useful, but a **separate codebase and binary**. Neither product requires the other to build or run.

| | |
|--|--|
| **License** | [Apache License 2.0](./LICENSE) |
| **Copyright** | 2023–2026 SpaceXAI |
| **Security** | [SECURITY.md](./SECURITY.md) (HackerOne) |
| **Contributing** | [CONTRIBUTING.md](./CONTRIBUTING.md) |
| **Parity / residuals** | [PORTING.md](./PORTING.md) · [CHANGELOG.md](./CHANGELOG.md) |

---

<h2 align="center">Highlights</h2>


- **Agent loop** — streaming chat completions (SSE), tools, multi-turn sessions  
- **TUI + REPL** — fullscreen chat or line mode; Grok-compatible keys where practical  
- **Local tools** — shell, filesystem, grep/glob, web fetch/search, LSP, media, memory  
- **Extensions** — MCP (stdio + HTTP), skills, hooks + folder trust, subagents + personas  
- **Safety** — permission modes, soft bash policy, optional OS sandbox (`AETHER_OS_SANDBOX`)  
- **No product telemetry** — `telemetry/` is an inert stub; privacy preference is local and **opt-in**

Porting ledger and intentional non-goals live in **PORTING.md** (not repeated as internal ticket IDs here).

---

<h2 align="center">Quick start</h2>


### Dependencies

| Kind | Packages |
|------|----------|
| **Build** | Odin (LLVM 17–22), `clang`/`c++`, `make` |
| **Runtime (required)** | **libcurl**, **mbedTLS** (link deps for Odin’s curl vendor), **ripgrep** (`rg`) |
| **Runtime (optional)** | `pdftotext` (PDF), `unzip` (PPTX), ImageMagick (media helpers) |
| **Auth** | **`XAI_API_KEY`** (recommended), or `~/.grok/auth.json` |

Debian/Ubuntu packages: `libcurl4-openssl-dev`, `libmbedtls-dev`, `ripgrep`, `build-essential`, `clang`, `llvm`.

No Cargo/Rust tree and no installed Rust `grok` binary are required for normal use. Shared `~/.grok` files are optional **interop** with an existing Grok install.

```bash
# From this tree (standalone). Monorepo: make -C aether …
make bootstrap-odin                 # Odin → ./.tools (or monorepo ../.tools)
make build test smoke-tui
./bin/aether --version              # or: ./out/aether
./bin/aether                        # fullscreen TUI on a TTY (else line REPL)
./bin/aether chat                   # multi-turn line REPL
./bin/aether -p "say hi in three words"
make install                        # PATH: aether-grok (+ aether-grok-odin, grok-odin)
make smoke                          # live -p check (skips without auth)
make check-license                  # Apache-2.0 / SPDX hygiene
```

Useful targets: `build`, `debug`, `vet`, `test`, `run ARGS='-p hi'`, `smoke`, `smoke-tui`, `install`, `bootstrap-odin`, `dist`, `extract` (standalone export), `clean`.

**CI:** `.github/workflows/aether.yml` — Odin only (license check + build/test).

```bash
source ./shell-aliases.sh           # aether-grok / aether-grok-odin / grok-odin
```

Install names point at the same wrapper and **do not** replace Rust `grok`.  
Default install dir: first writable of `~/.local/bin` or `~/.grok/bin` (`AETHER_INSTALL_BIN` to override).

| Command | Meaning |
|---------|---------|
| **`aether-grok`** | Primary day-to-day name (always installed). No args → **TUI** on a TTY |
| `aether-grok-odin` | Explicit dual-product name |
| `grok-odin` | Explicit Odin peer name |
| `aether` | Short name **only if free** — not installed when `/usr/bin/aether` is Arch’s [desktop theme app](https://github.com/bjarneo/aether) |

On Arch Linux, prefer **`aether-grok`**. Force the short name only if intentional: `AETHER_INSTALL_SHORT_NAME=1 make install`.

### Manual build

```bash
export PATH="$PWD/.tools/bin:${PATH}"
export ODIN_ROOT="${ODIN_ROOT:-$PWD/.tools/odin}"
odin build . -collection:aether=. -out:out/aether -o:speed
```

### Authentication

1. **Recommended:** set **`XAI_API_KEY`** (API-key mode).  
2. Or use an existing **`~/.grok/auth.json`** / `$GROK_HOME/auth.json` session.  
3. **`aether login` / `/login`** — in-process **device-code** sign-in (no Rust binary required).  
4. **Optional:** `aether login --host` if a Rust `grok` is on `PATH` (`AETHER_GROK_BIN` / `GROK_BIN`).  
5. **`aether whoami`** — identity only (never prints secrets).

Resolution order: env API key → `GROK_AUTH` inline JSON (rare) → `auth.json` on disk.  
Session API base defaults to the Grok CLI chat proxy; OIDC tokens refresh when needed and are written back to `auth.json`.

---

<h2 align="center">Standalone export</h2>


Export a self-contained source tree without removing this copy:

```bash
# monorepo root:
bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone
# or: make -C aether extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'
```

See [STANDALONE.md](./STANDALONE.md). `make dist` builds a **binary** tarball (includes `LICENSE` + `NOTICE`).

---

<h2 align="center">CLI</h2>


| Flag / command | Meaning |
|----------------|---------|
| *(no args)* | **TUI** when stdin/stdout are a TTY; otherwise line REPL |
| `tui` | Fullscreen chat UI |
| `chat` / `repl` | Multi-turn line REPL |
| `-p` / `--print` / `--single TEXT` | One-shot headless agent |
| `-m` / `--model ID` | Model override |
| `--max-turns N` | Tool-loop cap per prompt (default 20) |
| `--cwd DIR` | Workspace for tools (default: process cwd) |
| `-q` / `--quiet` | Suppress progress on stderr |
| `--verbose` | Extra diagnostics (never prints tokens) |
| `--permission-mode MODE` | `always-approve` · `read-only` · `ask` |
| `--yolo` / `--always-approve` | Auto-approve write/shell |
| `--read-only` | Deny write/shell tools |
| `--session` / `-c` / `--continue` | Resume a saved session |
| `login [args]` | Device-code sign-in; `--host` → optional host `grok login` |
| `whoami` | Signed-in identity (no secrets) |
| `--help` / `--version` | Meta |

**Exit codes:** `0` ok · `1` usage/auth · `2` max turns · `3` model/HTTP error · `4` cancelled  

### Configuration

Merge order (low → high): defaults → `~/.grok/config.toml` → project `aether.toml` (`AETHER_CONFIG`) → CLI.

Common keys: `[models].default`, `[models].default_reasoning_effort`, `[ui].permission_mode` / `yolo` / `theme` / `vim_mode` / `compact_mode` / `auto_compact*`, `[agent].max_turns`, `[permission].allow` / `deny`, `[memory].*`, `[subagents].enabled`.

Themes: `dark` (default), `light`, `tokyonight`, `rosepine`, `oscura` (`/theme`).  
Env kill-switches (`AETHER_NO_*`, etc.) override TOML.  
`NO_COLOR` / `AETHER_NO_COLOR=1` disables color.

UI prefs such as theme, vim mode, compact mode, timestamps, permission mode, model, and effort can persist into `~/.grok/config.toml` (opt out: `AETHER_NO_UI_PERSIST=1`).

### Project rules

Injected into the system prompt from (deeper paths win):

| Source | Paths |
|--------|--------|
| Global | `~/.grok/{AGENTS,AGENT,CLAUDE}.md`, `~/.grok/rules/*.md` |
| Claude home | `~/.claude/` named + `rules/*.md` (unless `AETHER_NO_CLAUDE_RULES=1`) |
| Cursor home | `~/.cursor/` named + `rules/*.md` (unless `AETHER_NO_CURSOR_RULES=1`) |
| Repo chain | root→cwd: named files, `.grok/rules/`, `.claude/…`, `.cursor/rules/` |

Opt out all: `AETHER_NO_PROJECT_RULES=1`.

### Sessions

Stored under `~/.grok/aether/sessions/` (`AETHER_SESSIONS_DIR` / `--sessions-dir`). Autosave after agent turns unless `--no-autosave`.

Slash commands include `/session`, `/sessions`, `/save`, `/load`, `/rename`, `/fork`, `/export`, `/import`, `/rewind`, `/resume`, `/new`, `/clear`.  
`/undo-file` reverts the last local edit tool (process-local stack; opt out `AETHER_NO_FILE_REWIND=1`).

### REPL slash commands (summary)

`/help`, `/about`, `/status`, `/settings`, `/doctor`, `/whoami`, `/login`, `/model`, `/effort`, `/permissions`, `/theme`, `/vim-mode`, `/mcp`, `/skills`, `/plan`, `/memory` helpers (`/flush`, `/dream`, `/remember`), `/todos`, `/goal`, `/loop`, `/imagine`, `/quit`, and more — see `/help` and `core/slash_catalog.odin`.

---

<h2 align="center">TUI (`aether tui`)</h2>


Fullscreen raw-terminal chat. Requires a TTY. Mid-turn: live stream, tool cards, status, permission modals.

### Compose

| Key | Action |
|-----|--------|
| Enter | Send (or newline in multiline mode) |
| Shift+Enter / Alt+Enter | Newline (or send in multiline) |
| `\` then Enter | Newline (portable) |
| Ctrl+M (prompt focused) | Toggle multiline |
| Left/Right/Home/End | Move cursor |
| Esc Esc (within 800ms) | Clear non-empty prompt |
| Ctrl+C | Clear draft; mid-turn cancel; idle empty → use Ctrl+Q to quit |
| ↑ / ↓ (empty prompt) | Prompt history (`~/.grok/aether/prompt-history.jsonl`; opt out `AETHER_NO_PROMPT_HISTORY=1`) |

### Session & mode

| Key | Action |
|-----|--------|
| Ctrl+S or `/resume` | Session picker |
| Ctrl+N (×2 within 1s) | New session |
| Ctrl+O or `/yolo` | Toggle always-approve (later tools in the turn) |
| Shift+Tab | Cycle: **ask → plan → auto → always-approve → read-only** |
| y / n / a / d (ask modal) | Allow once / deny / session always / session never |
| Ctrl+M (scrollback) or `/model` | Model picker |
| Ctrl+Q / Ctrl+D (×2) | Quit |

### Scrollback

| Key | Action |
|-----|--------|
| Tab | Slash / path complete, or toggle prompt ↔ scrollback |
| ↑ / ↓ | Select block |
| ← / → (tool) | Collapse / expand |
| `y` / `Y` | Copy block / tool metadata |
| PgUp/PgDn · Ctrl+J/K · Ctrl+U | Scroll |
| Ctrl+F or `/find` | Search transcript |

Empty sessions can show welcome art (opt out: `AETHER_NO_ASCII_ART=1`). Brand art provenance is documented in [NOTICE](./NOTICE) and [assets/logo/NOTICE](./assets/logo/NOTICE).

---

<h2 align="center">Tools</h2>


| Name | Notes |
|------|--------|
| `run_terminal_cmd` | `sh -c`; FG timeout default 120s (max 300s); `is_background` → task id + log. Soft bash policy; optional `AETHER_OS_SANDBOX=soft\|bwrap` |
| `read_file` | Line-numbered text; images metadata; PDF/PPTX when tools available |
| `search_replace` / `write` / `delete_file` | Edit tools; plan-mode gates non-plan writes |
| `grep` / `list_dir` / `glob` | Search and listing (`rg`) |
| `web_search` / `web_fetch` | Hosted search; HTTP fetch with SSRF guards (opt-out env vars available) |
| `todo_write` / `update_goal` | Session-durable task list and goal progress |
| `image_gen` / `image_edit` | Imagine API (needs `XAI_API_KEY`) |
| `image_to_video` / `reference_to_video` | Video generation |
| `ask_user_question` | Multiple-choice (+ Other) |
| `lsp` | Language-server helpers |
| `monitor` | Background shell → system-reminder stream |
| `scheduler_*` | Scheduled prompts |
| `memory_search` / `memory_get` | File-backed memory under `~/.grok/memory/` |
| `search_tool` / `use_tool` | MCP tools |
| `skill` | Load `SKILL.md` packages |
| `spawn_subagent` / `task` | Child agents (explore / plan / general-purpose; optional persona) |
| `get_task_output` / `kill_task` / `wait_tasks` | Background task control |
| `enter_plan_mode` / `exit_plan_mode` | Plan-first workflow (`.grok/plan.md`) |

Writes outside `--cwd` are denied.

**Background shell:** `is_background: true` returns a task id; poll with `get_task_output`, stop with `kill_task`. Shared concurrency with background subagents (2). Optional desktop notify when tasks or parent turns finish (`AETHER_NO_DESKTOP_NOTIFY=1` to disable).

**Streaming:** tokens to stdout by default for headless; `AETHER_NO_STREAM=1` forces non-stream. Tool progress on stderr. TUI updates mid-turn.  
**HTTP:** connect 15s; total 120s (non-stream) / 300s (SSE); stall abort and multi_poll cancel for mid-request Ctrl+C.

**Ask mode mid-turn:** `y` allow once (+ rest of turn) · `n` deny · `a` session always · `d` session never. Session grants are in-memory only; cleared on `/new`.

---

<h2 align="center">Plan mode</h2>


Enter via `/plan` or Shift+Tab: research freely, but file edits are limited to **`<cwd>/.grok/plan.md`**. Exit via `exit_plan_mode` / `/plan off` (TUI may prompt to approve). Opt out: `AETHER_NO_PLAN_MODE=1`.

---

<h2 align="center">Subagents</h2>


| Type | Behavior |
|------|----------|
| `explore` | Research; no file edits |
| `plan` | Implementation plan |
| `general-purpose` | Full tools except nested spawn |

Supports background spawn, resume, worktree isolation, and optional **personas**. Opt out: `AETHER_NO_SUBAGENTS=1`.

---

<h2 align="center">Skills & MCP</h2>


**Skills:** discovers `SKILL.md` under `~/.grok/skills`, project `.grok/skills`, Claude-compatible roots, etc. Model uses the `skill` tool; users use `/skills`, `/skill`, `/create-skill`. Opt out: `AETHER_NO_SKILLS=1`.

**MCP:** configure `[mcp_servers.<name>]` in `~/.grok/config.toml` or project `aether.toml` (stdio `command` or HTTP `url`). Tokens via env or `~/.grok/mcp_credentials.json` (never printed). `/mcp` for status, reconnect, set-token, doctor. Opt out: `--no-mcp` / `AETHER_NO_MCP=1`.

---

<h2 align="center">Memory</h2>


File-backed layout compatible with Grok Build under `~/.grok/memory/` (override `AETHER_MEMORY_DIR`). Tools: `memory_search`, `memory_get`. Slash: `/flush`, `/dream`, `/remember`, `/memory`. Opt out: `AETHER_NO_MEMORY=1`.

---

<h2 align="center">Layout</h2>


| Path | Role |
|------|------|
| `main.odin` | Entry |
| `core/` | Version, paths, config, permissions, brand |
| `cli/` | Flags |
| `agent/` | Auth, HTTP, chat, loop, sessions, slash |
| `mcp/` | MCP client |
| `skills/` | Skill discovery |
| `hooks/` | Lifecycle hooks |
| `tools/` | Local tools |
| `tui/` | Fullscreen UI |
| `scripts/` | Bootstrap, smoke, license check, export |
| `telemetry/` | Inert placeholder (no network) |

---

<h2 align="center">Tests</h2>


```bash
make build test smoke-tui
# or:
export PATH="$PWD/.tools/bin:$PATH"
export ODIN_ROOT="$PWD/.tools/odin"
odin test agent -collection:aether=.
odin test tools -collection:aether=.
odin test core -collection:aether=.
odin test tui -collection:aether=.
```

`make smoke` needs auth. `make smoke-tui` does not.

---

<h2 align="center">Non-goals</h2>


Documented in detail in [PORTING.md](./PORTING.md). In short: ACP multi-client UI, remote marketplace, product analytics/Mixpanel, voice, self-update, mermaid PNG/SVG (Unicode layout ships), full MCP browser OAuth DCR, SQLite embeddings memory, and related enterprise surfaces are **out of scope** for this tree.

---

<h2 align="center">License</h2>


First-party code and assets in this repository are licensed under the
**Apache License, Version 2.0** — see [LICENSE](./LICENSE).

Copyright **2023–2026 SpaceXAI**.

Attribution and provenance (including Grok Build lineage and modified welcome
art) are in [NOTICE](./NOTICE) and [assets/logo/NOTICE](./assets/logo/NOTICE).

Redistributions of source or binary form **must** include `LICENSE` and
`NOTICE` (Apache License §4).

**Security:** report vulnerabilities privately via [SECURITY.md](./SECURITY.md)
(HackerOne). Do not open public issues for security reports.

**Contributing:** [CONTRIBUTING.md](./CONTRIBUTING.md). Contributions are under
the same Apache-2.0 terms.

**Trademarks:** Apache-2.0 does **not** grant trademark rights. “Grok”, “xAI”,
“SpaceXAI”, and “Aether” remain marks of their respective owners. Names appear
here for product identification and interoperability only.

**Privacy & telemetry:** no product telemetry is shipped. `/privacy` only
persists a **local** `coding_data_share` preference (default **off**).

**Third-party runtime** (libcurl, ripgrep, optional PDF/PPTX tools, Odin under
`.tools/`) is not redistributed as first-party source and keeps upstream licenses.

```bash
make check-license    # LICENSE, NOTICE, SPDX coverage (also in CI)
```
