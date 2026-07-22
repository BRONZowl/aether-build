<h1 align="center">Aether</h1>


**Aether** is a high-performance coding agent written in **Odin**: headless one-shots, multi-turn REPL, and a fullscreen terminal UI.

It is a **peer** to [Grok Build](https://x.ai/cli) (the Rust `grok` CLI)—same problem space and optional `~/.grok` interop, but a **separate codebase and binary**. Neither product requires the other.

| | |
|--|--|
| **License** | [Apache-2.0](./LICENSE) · [NOTICE](./NOTICE) |
| **Security** | [SECURITY.md](./SECURITY.md) (HackerOne) |
| **Contributing** | [CONTRIBUTING.md](./CONTRIBUTING.md) |
| **Parity / history** | [PORTING.md](./PORTING.md) · [CHANGELOG.md](./CHANGELOG.md) |

<h2 align="center">Highlights</h2>


- **Agent loop** — streaming chat (SSE), tools, multi-turn sessions  
- **TUI + REPL** — fullscreen chat or line mode  
- **Local tools** — shell, filesystem, search, web, LSP, media, memory  
- **Extensions** — MCP, skills, hooks, subagents + personas  
- **Safety** — permission modes, soft bash policy, optional OS sandbox  
- **No product telemetry** — privacy preference is local and **opt-in**

<h2 align="center">Install</h2>


Primary command: **`aether-grok`**. Does not replace or install Rust `grok`.

### Package managers

| Manager | Command |
|---------|---------|
| **Arch (local AUR recipe)** | `cd packaging/aur/aether-grok-git && makepkg -si` |
| **Homebrew (from tree)** | `brew install --build-from-source ./packaging/homebrew/aether-grok.rb` |

After AUR/tap publish: `yay -S aether-grok-git` or `brew tap … && brew install aether-grok`.  
Details: [packaging/README.md](./packaging/README.md).

### From source

**Dependencies**

| Kind | Packages |
|------|----------|
| **Build** | Odin (LLVM 17–22), `clang`/`c++`, `make` |
| **Runtime** | **libcurl**, **mbedTLS**, **ripgrep** (`rg`) |
| **Optional** | `pdftotext`, `unzip`, ImageMagick |
| **Auth** | **`XAI_API_KEY`** (recommended), or `~/.grok/auth.json` |

Debian/Ubuntu: `libcurl4-openssl-dev`, `libmbedtls-dev`, `ripgrep`, `build-essential`, `clang`, `llvm`.

```bash
make bootstrap-odin          # Odin → ./.tools
make build test
make install                 # → ~/.local/bin or ~/.grok/bin
aether-grok --version
```

Local wrappers without install: `./bin/aether` (same binary as `out/aether`).

| Name | Notes |
|------|--------|
| **`aether-grok`** | Day-to-day name (always installed) |
| `aether-grok-odin` / `grok-odin` | Explicit dual-product names |
| `aether` | Only if free (skipped when it would hide Arch’s unrelated theme app) |

Override install dir: `AETHER_INSTALL_BIN=… make install`.  
System/package builds: `make DESTDIR=… PREFIX=/usr install-prefix`.

### Authentication

1. **`export XAI_API_KEY=…`** (recommended)  
2. Or existing **`~/.grok/auth.json`** session  
3. **`aether-grok login`** / **`/login`** — in-process device-code sign-in  
4. **`aether-grok whoami`** — identity only (never prints secrets)

<h2 align="center">Usage</h2>


```bash
aether-grok                         # TUI on a TTY; else line REPL
aether-grok tui                     # force fullscreen UI
aether-grok chat                    # multi-turn line REPL
aether-grok -p "say hi in three words"
aether-grok -m grok-4.5 --cwd .
```

| Flag / command | Meaning |
|----------------|---------|
| *(no args)* | TUI if TTY, else REPL |
| `tui` / `chat` / `repl` | Force UI mode |
| `-p` / `--print` TEXT | One-shot headless agent |
| `-m` / `--model` | Model override |
| `--cwd` DIR | Workspace for tools |
| `--permission-mode` | `always-approve` · `auto` · `read-only` · `ask` |
| `--yolo` / `--read-only` | Permission shortcuts |
| `--session` / `-c` | Resume a saved session |
| `login` / `whoami` | Auth helpers |
| `--help` / `--version` | Meta |

**Exit codes:** `0` ok · `1` usage/auth · `2` max turns · `3` model/HTTP · `4` cancelled  

Config merges: defaults → `~/.grok/config.toml` → project `aether.toml` → CLI.  
UI prefs (theme, vim, permission, model, …) can persist to config (`AETHER_NO_UI_PERSIST=1` to opt out).  
In-session help: **`/help`**, **`/keys`**, **`/settings`**, **`/doctor`**.

Sessions live under `~/.grok/aether/sessions/`. Project rules load from `AGENTS.md` / `.grok/rules` (and optional Claude/Cursor roots); opt out with `AETHER_NO_PROJECT_RULES=1`.

<h2 align="center">Features</h2>


| Area | Notes |
|------|--------|
| **Tools** | Shell, files, grep/glob, web, LSP, todos/goals, Imagine media, plan mode, MCP, skills, subagents, memory, scheduler |
| **Plan mode** | `/plan` or Shift+Tab — edits limited to `.grok/plan.md` until exit |
| **Subagents** | `explore` / `plan` / `general-purpose`; optional personas, worktree isolation |
| **Skills & MCP** | Discover skills; configure `[mcp_servers.*]` in config.toml; `/mcp`, `/skills` |
| **Memory** | File-backed under `~/.grok/memory/`; `/flush`, `/dream`, `/remember` |
| **Safety** | Soft bash inspect auto-allow + hard-deny; optional `AETHER_OS_SANDBOX` |

Full tool names and flags: in-product **`/tools`**, or the tool registry under `tools/`.

### TUI (quick)

| Key | Action |
|-----|--------|
| Enter | Send (or newline in multiline) |
| Ctrl+M | Toggle multiline (when prompt focused) |
| Ctrl+S | Session picker |
| Shift+Tab | Cycle permission / plan modes |
| Ctrl+O | Toggle always-approve |
| Tab | Complete / focus scrollback |
| Ctrl+F | Find in transcript |
| Ctrl+Q (×2) | Quit |

More bindings: **`/keys`**. Welcome art: opt out with `AETHER_NO_ASCII_ART=1`.

<h2 align="center">Development</h2>


```bash
make bootstrap-odin
make build vet test smoke-tui
make smoke                  # live -p (needs auth)
make check-license          # Apache-2.0 / SPDX (CI)
make dist                   # binary tarball + LICENSE/NOTICE
```

| Path | Role |
|------|------|
| `main.odin` | Entry |
| `core/` | Config, permissions, soft bash, brand |
| `cli/` | Flags |
| `agent/` | Auth, HTTP, loop, sessions, slash |
| `tools/` · `mcp/` · `skills/` · `hooks/` | Capabilities |
| `tui/` | Fullscreen UI |
| `scripts/` · `packaging/` | Bootstrap, install, AUR/Homebrew |

Standalone source export: [STANDALONE.md](./STANDALONE.md). CI: `.github/workflows/aether.yml`.

<h2 align="center">Non-goals</h2>


Out of scope for this tree (see [PORTING.md](./PORTING.md)): ACP multi-client UI, remote marketplace, product analytics, voice, self-update, mermaid PNG/SVG, full MCP browser OAuth DCR, SQLite embeddings memory, and related enterprise surfaces.

<h2 align="center">License</h2>


First-party code is **Apache License 2.0** — [LICENSE](./LICENSE).  
Copyright **2023–2026 SpaceXAI**. Attribution: [NOTICE](./NOTICE), [assets/logo/NOTICE](./assets/logo/NOTICE).

Redistributions must include `LICENSE` and `NOTICE` (Apache §4).  
Security: [SECURITY.md](./SECURITY.md). Contributing: [CONTRIBUTING.md](./CONTRIBUTING.md).

**Trademarks:** Apache-2.0 does not grant trademark rights. “Grok”, “xAI”, “SpaceXAI”, and “Aether” remain marks of their owners; names appear for identification and interoperability only.

**Privacy:** no product telemetry. `/privacy` only stores a local `coding_data_share` preference (default **off**).
