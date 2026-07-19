# Aether-Grok

High-performance **Odin** coding agent — peer product to Rust [Grok Build](https://x.ai/cli) in this monorepo.

> **Dual product:** **Aether** (`aether/`, Odin) and **Grok** (`crates/`, Rust) are **independent**. Neither build requires the other; **nothing is deleted**. Parity and separation: **[PORTING.md](./PORTING.md)**.
>
> **Ship mode R0-A (locked):** primary auth is **`XAI_API_KEY`** (plus existing `~/.grok/auth.json` if present). Browser `grok login` is optional interop if a Rust `grok` binary is installed — not a source-tree dependency.

**Program goal:** full product capabilities in Odin — agent core (L1), shell product (L2), pager-class UI (L3). Status tags: **[PORTING.md](./PORTING.md)**.

**Today:** daily-usable **headless** agent, multi-turn **REPL**, and fullscreen **TUI** (`aether tui`) — progressive SSE, core tools, **MCP**, **skills**, **hooks**, **subagents**, **plan mode**, **scheduler**, **media**, **memory**, slash builtins, config merge, sessions, permission modes (incl. **auto**), soft bash safety, PDF/PPTX read, TUI themes/vim/mouse/paste. Phases **A**/**B**/**C1–C2** Complete. Separation **S0–S4** landed (self-contained layout + dual-product charter + standalone export).

### Standalone export (S4)

Export this product as a **standalone source tree** without removing monorepo `aether/`:

```bash
bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone
# or: make -C aether extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'
```

Optional `--git-history` preserves `aether/` git history via `git subtree split`.  
`make dist` is a **binary** tarball only; S4 is **source** + standalone CI. See `STANDALONE.md` inside the extract. No remote push by default.

## Quick start

### Dependencies

| Kind | Packages |
|------|----------|
| **Build** | Odin (LLVM 17–22), `clang`/`c++`, `make` |
| **Runtime (required)** | **libcurl**, **ripgrep** (`rg`) |
| **Runtime (optional)** | `pdftotext` (PDF), `unzip` (PPTX), ImageMagick (media helpers) |
| **Auth** | **`XAI_API_KEY`** (recommended). Existing `~/.grok/auth.json` also works. |

No Cargo / Rust source tree is required. No installed Rust `grok` binary is required for normal use (R0-A). Shared `~/.grok` files are optional **interop** with an existing Grok install.

```bash
# from this tree (standalone) — or monorepo: make -C aether …
make bootstrap-odin                 # Odin → ./.tools (or monorepo ../.tools)
make build test smoke-tui
./bin/aether --version              # or: ./out/aether
./bin/aether -p "say hi in three words"
./bin/aether                        # multi-turn REPL
./bin/aether tui                    # fullscreen chat (TTY)
make install                        # PATH: aether-grok-odin, grok-odin (+ aether if free)
make smoke                          # live -p check (skips without auth)
```

Useful make targets: `build`, `debug`, `vet`, `test`, `run ARGS='-p hi'`, `smoke`, `smoke-tui`, `install`, `bootstrap-odin`, `dist`, `extract` (S4), `inventory-rust`, `clean`.

**CI:** `.github/workflows/aether.yml` — Odin-only (no Cargo).

```bash
source ./shell-aliases.sh           # aether-grok-odin / grok-odin (+ aether if free) + PATH
```

Install names all point at the same wrapper and **do not** clobber Rust `grok`.
Dest defaults to the first writable of `~/.local/bin` or `~/.grok/bin` (override: `AETHER_INSTALL_BIN`).

| Command | Meaning |
|---------|---------|
| `aether-grok-odin` | Preferred explicit name (always installed) |
| `grok-odin` | Explicit Odin product name |
| `aether` | Short name **only if** it would not shadow a foreign binary (e.g. Arch theme `aether`) |

On hosts where `/usr/bin/aether` is already something else, use `aether-grok-odin` / `grok-odin`. Force short name: `AETHER_INSTALL_SHORT_NAME=1 make install`.
### Manual build (without make)

```bash
# tools from bootstrap (./.tools or monorepo ../.tools)
export PATH="$PWD/.tools/bin:${PATH}"
export ODIN_ROOT="${ODIN_ROOT:-$PWD/.tools/odin}"
odin build . -collection:aether=. -out:out/aether -o:speed
```

### Auth (R0-A)

1. **Recommended:** set **`XAI_API_KEY`** for API-key mode.
2. Or use an existing **`~/.grok/auth.json`** / `$GROK_HOME/auth.json` session (e.g. from a previous `grok login`).
3. **Optional interop:** `aether login` / `/login` shells out to an installed **`grok login`** if on PATH (`AETHER_GROK_BIN` / `GROK_BIN`). Not required; does not need the monorepo `crates/` tree.
4. **`aether whoami`** — identity only (no secrets).

## CLI

| Flag / command | Meaning |
|----------------|---------|
| *(no args)* / `chat` | Multi-turn interactive REPL (startup tip: `/about · /help · /keys · /exit`) |
| `tui` | Fullscreen chat UI (TTY required) |
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
| `login [args]` | Browser sign-in via host `grok login` (A5.2) |
| `whoami` | Show signed-in identity (no secrets) |
| `--help` / `--version` | Meta |

Config merge (low→high): defaults → `~/.grok/config.toml` → project `aether.toml` (`AETHER_CONFIG`) → CLI. Product keys (A5.1/C2): `[models].default`, `[ui].permission_mode` / `yolo` / `auto_compact` / `auto_compact_pct` / **`theme`** / **`vim_mode`**, `[compact].*`, `[agent].max_turns`, `[permission].allow` / `deny`, `[memory].enabled` / `auto_dream`, `[memory.initial_injection].enabled`, `[subagents].enabled`. Themes: `dark` (default), `light`, `tokyonight`, `rosepine`, `oscura` — `/theme`. Vim scrollback: `[ui] vim_mode = true` or `/vim-mode` (`j`/`k`/`g`/`G`/`H`/`L`/`J`/`K`/`i` — H/L user turns, J/K assistant). Simple mode: **Shift+←/→** jump prev/next user turn. Mouse: wheel scrolls; left-click selects a scrollback block or focuses the compose prompt; **middle-click** pastes PRIMARY selection (Wayland/X11; clipboard fallback; `pbpaste` on macOS). **Ctrl+V** / middle-paste: clipboard **image** or image **path**/`file://`/`data:image` attaches as `[Image #N]` (vision on send; tools resolve the same token). Terminal **bracketed paste** (ESC`[200~`…`201~`) inserts multi-line text in one shot (with the same image-path rewrite). Opt out vision expand: `AETHER_NO_MULTIMODAL=1`. `NO_COLOR` / `AETHER_NO_COLOR=1` disables color. Env kill-switches (`AETHER_NO_*`, `AETHER_AUTO_COMPACT_PCT`) still win over TOML.

REPL slash commands: **`/help [filter]`** (B65 sectioned catalog), **`/about`** (B50 product blurb), **`/aliases`** (B53 alias table), **`/keys`** (B41 TUI shortcuts; `/bindings`), **`/tools`** (B45 model tool catalog), **`/soft-bash`** (B47–B48 soft-bash safety; B80 `check <cmd>` dry-run), **`/permissions`** (B61 mode dashboard; `/perm`), **`/env`** (B62 product env / AETHER_* catalog), **`/paths`** (B63 data path dashboard; `/where`), **`/features`** (B68 feature flags; `/flags`), `/status`, **`/config`** (B34 effective settings; aliases `/settings` `/prefs`), **`/doctor`** (B30/B39 health check + optional host tools), `/session`, `/sessions`, `/resume`, `/save`, `/load`, `/rename`, `/fork`, `/export`, `/import`, **`/rewind [N]`**, **`/undo-file`**, **`/copy [N]`**, **`/history`**, **`/model`**, **`/effort`**, **`/auto`**, **`/compact-mode`** (`/cm`), **`/timestamps`** (B37 HH:MM on transcript), `/new`, `/clear`, `/whoami`, `/login`, `/mcp`, `/skills`, `/skill`, `/plan`, **`/view-plan`**, **`/remember`**, `/todos`, `/goal`, `/loop`, `/imagine`, `/imagine-video`, `/theme`, `/vim-mode`, `/exit` (plus bare `/skill-name` when discovered).

**Compact mode (B8):** `/compact-mode` densifies TUI header/status/tool chrome (more content rows on small screens). Config: `[ui] compact_mode = true` in `~/.grok/config.toml` or `aether.toml`.

**Persist UI prefs (B9 / B15 / B17 / B37):** `/theme`, `/vim-mode`, `/compact-mode`, **`/timestamps`**, **permission mode** (`/auto`, `/always-approve`, Shift+Tab, Ctrl+O yolo), **`/model`** → `[models] default`, and **`/effort`** → `[models] default_reasoning_effort` write into `~/.grok/config.toml` so settings survive restarts (opt out: `AETHER_NO_UI_PERSIST=1`).

**Project rules (B4–B5):** injected into the system prompt from:

| Source | Paths |
|--------|--------|
| Global | `~/.grok/{AGENTS,AGENT,CLAUDE}.md`, `~/.grok/rules/*.md` |
| Claude home | `~/.claude/` named + `rules/*.md` (unless `AETHER_NO_CLAUDE_RULES=1`) |
| Cursor home | `~/.cursor/` named + `rules/*.md` (unless `AETHER_NO_CURSOR_RULES=1`) |
| Repo chain | root→cwd: named files, `.grok/rules/`, `.claude/CLAUDE.md` + `.claude/rules/`, `.cursor/rules/` |

Opt out all: `AETHER_NO_PROJECT_RULES=1`. Deeper paths override earlier ones.
**Plan mode lifecycle (Grok-shaped):** states `Inactive` → user `/plan` or Shift+Tab → `Pending` → next turn injects reminder → `Active` (edit gate: only `<cwd>/.grok/plan.md`). Model `enter_plan_mode` requires user approval (decline → Grok prose). `exit_plan_mode` outcomes: **approve** / **revise** (optional feedback) / **abandon**. Mid-turn toggle-off uses `Exit_Pending` until the turn ends. Session JSON stores the full snapshot; header chips: `plan` / `plan…` / `plan↓`. Opt out: `AETHER_NO_PLAN_MODE=1`.

Sessions are stored under `~/.grok/aether/sessions/` (override with `AETHER_SESSIONS_DIR` or `--sessions-dir`). Autosave runs after each agent turn that may have mutated history (success, max-turns, cancel, error) unless `--no-autosave`; failures surface in the TUI notice bar or REPL stderr. Empty titles are set from the **first user prompt** on save (`/save [title]` still overrides). `/load` accepts id, path, case-insensitive title, or a unique title/id substring. **Lifecycle (B2.1–3):** `/rename`·`/title`, `/fork`, `/sessions delete`, **`/export [json|md] [path]`** (markdown default; **json** = full session dump, B27), **`/import <path.json>`** (import dump as **new** session, B29), `/resume`, **`/rewind [N]`** drops the last N user turns (Grok-shaped conversation rewind), **`/undo-file`** undoes the last `write` / `search_replace` / `delete_file` (process-local stack, max 40; opt out `AETHER_NO_FILE_REWIND=1`). **`/model`**, **`/effort`**, **`/auto`**, **`/copy`** match Grok shell UX.

**Exit codes:** `0` ok · `1` usage/auth · `2` max turns · `3` model/HTTP error · `4` cancelled (TUI cooperative cancel)

Tool failures (`error:…` results) show as **fail:** in the status bar and as `· fail ·` on collapsed TUI tool cards (auto-expanded when first shown).

## TUI (`aether tui`)

Fullscreen raw-terminal chat aligned with **Grok Build** muscle memory where practical. Requires a TTY. Mid-turn: live token stream, tool cards as results land, status for sampling/tools/errors, and an **ask-mode** modal (`y`/`n`) for write/shell tools when permission is `ask`.

### Compose

| Key | Action |
|-----|--------|
| Enter | Send (or newline in multiline mode) |
| Shift+Enter / Alt+Enter | Newline (or send in multiline mode) |
| `\` then Enter | Newline (portable fallback) |
| Ctrl+M (prompt focused) | Toggle multiline mode |
| Left/Right/Home/End | Move cursor |
| Esc Esc (within 800ms) | Clear non-empty prompt |
| Ctrl+C | Clear draft; mid-turn cancel (aborts in-flight HTTP); idle empty → hint (use Ctrl+Q to quit) |
| ↑ / ↓ (empty prompt) | Prompt history (session + **durable** `~/.grok/aether/prompt-history.jsonl`, B23; **REPL also appends**, B28; opt out `AETHER_NO_PROMPT_HISTORY=1`) |

### Session & mode

| Key | Action |
|-----|--------|
| Ctrl+S or `/resume` | Session picker (↑↓ · Enter load · filter · Esc) |
| Ctrl+N (×2 within 1s) | New session (autosaves current) |
| Ctrl+O or `/yolo` | Toggle always-approve (YOLO); applies mid-turn to **later tools** |
| Shift+Tab | Cycle mode: **ask → plan → auto → always-approve → read-only** (mid-turn too; **auto** = accept file edits, ask for shell; plan gates edits to `.grok/plan.md`) |
| y / Enter · n / Esc · a · d (ask modal) | Allow once / deny once / always-allow session / never-allow session; first once-allow covers rest of **this turn** |
| 1–9 · Other freeform (question modal) | `ask_user_question`: digit selects option; multi_select = digit toggle + Enter; **Other** → freeform (Enter submit, Esc = Other, Ctrl+C cancel) |
| Ctrl+M (scrollback) or `/model` [id] | Model picker / set model |
| Ctrl+Q / Ctrl+D (×2 within 1s) | Quit |

### Scrollback

| Key | Action |
|-----|--------|
| Tab | Slash complete (`/cmd…`, B20) or **`@path` / path** complete (B22–B24: dir list + workspace `rg --files`); else toggle prompt ↔ scrollback |
| Space (scrollback) | Focus prompt |
| ↑ / ↓ | Select block |
| ← / → (tool) | Collapse / expand |
| `e` | Toggle tool fold (last tool on empty prompt; selected in scrollback) |
| `y` / `Y` | Copy block / tool metadata (native clipboard → OSC 52 → `/tmp` file) |
| PgUp/PgDn · Ctrl+J/K · Ctrl+U | Scroll |
| **Ctrl+F** or `/find [text]` | Search transcript (case-insensitive); `n`/`N` next/prev match; Esc close |

Slash commands in the TUI match the REPL (`/help`, `/session`, `/sessions`, `/save`, `/load`, `/new`, `/clear`, `/whoami`, `/exit`, plus `/multiline`, `/resume`, `/model`, `/yolo`, `/find`).

## Auth

Resolution order:

1. `XAI_API_KEY` / `GROK_CODE_XAI_API_KEY` (API-key mode)
2. `GROK_AUTH` inline JSON (rare)
3. `$GROK_HOME/auth.json` or `~/.grok/auth.json` (prefer OIDC session from `grok login`)

Session path defaults to `https://cli-chat-proxy.grok.com/v1` with Bearer + `X-XAI-Token-Auth: xai-grok-cli` and proxy headers. Expired OIDC tokens are refreshed via the issuer’s token endpoint and written back to `auth.json`.

## Tools

| Name | Notes |
|------|--------|
| `run_terminal_cmd` | `sh -c`; FG timeout default 120s max 300s; `is_background` → task_id + `terminal/bash-*.log`; **soft bash:** hard-deny catastrophic cmds (`rm -rf /`, pipe-to-shell, …) even under yolo; auto-allow read-only shell (`ls`/`eza`/`fd`/`dust`, `git status`, `aws s3 ls` / `sts get-caller-identity`, `gcloud … list`, `az … show`, `podman ps`, `brew list`/`info`, `apt list`/`search`, `dnf info`, `pacman -Q`/`-Ss`, `flatpak list`, `snap info`, `apk search`, `pipx list`, `gem search`, `composer show`, `bundle list`/`show`, `rake -T`, `mvn dependency:tree`, `gradle tasks`, `sbt tasks`/`about`, `bazel query`/`info`, `pulumi stack ls`, `ansible --list-hosts`, `ansible-playbook --syntax-check`, `vagrant status`/`box list`, `packer validate`/`inspect`, `consul members`/`kv get`, `nomad status`/`job plan`, `vault status`/`secrets list` (not secret read), `argocd app list`/`diff`, `flux get`/`check`, `istioctl proxy-status`/`analyze`, `kustomize build`, `skaffold diagnose`/`render`, `kind get clusters`, `minikube status`, `k3d cluster list`, `tilt describe`, `crane digest`/`skopeo inspect`/`dive`, `syft`/`grype`/`trivy` scan, `cosign verify`/`oras discover`/`regctl image digest`, `buildah images`/`nerdctl ps`/`ctr images ls`, `helmfile list`/`stern`/`kubeconform`, `tflint`/`terraform-docs`/`terragrunt plan`, `checkov`/`tfsec`/`infracost breakdown`, `kubectx`/`kubens` list, `curl -I`, `nix flake show`, `http`/`xh` GET, `gh pr list`, …) including in read-only mode. Opt out: `AETHER_NO_BASH_SOFT=1` or `/soft-bash off`. OS sandbox/persistent shell N/A |
| `read_file` | Line-numbered text (`offset`/`limit`, negative offset from end); images → metadata + optional small data URL; **PDF** → `pdftotext`; **PPTX** → slide text via `unzip` + `a:t` scrape; `pages` for PDF/PPTX (e.g. `1-5`, max 20/call); other binary rejected |
| `search_replace` | Exact replace (unique or `replace_all`); empty `old_string` creates/overwrites; plan-mode gate; hashline/notebook N/A |
| `write` | Full-file create/overwrite (`file_path` + `content`); parents created; Edit permission |
| `delete_file` | Delete one file (`target_file` or `file_path`); not directories; Edit permission |
| `grep` | ripgrep: `pattern`, `path`, `glob`, `type`, `-i`, `-A`/`-B`/`-C`, `multiline`, `head_limit` (total lines, default 200) |
| `list_dir` | Tree listing; hide dots; `.gitignore` via rg; char budget; fat-dir extension summary |
| `glob` | File paths matching a glob (`pattern`, optional `path`); `rg --files`; mtime-newest first; cap 100; Read permission |
| `web_search` | Responses API hosted search; optional `allowed_domains`; session or `XAI_API_KEY`; opt out `AETHER_NO_WEB_SEARCH=1` |
| `web_fetch` | GET URL → markdown/text; allowlist + SSRF; HTTP→HTTPS; long pages → preview + `web_fetch/` artifact; binary rejected; process cache (TTL 300s). Opt out: `AETHER_NO_WEB_FETCH=1`. Allowlist: `AETHER_WEB_FETCH_DOMAINS`. Dev: `AETHER_WEB_FETCH_ALLOW_ALL=1`. Cache off: `AETHER_WEB_FETCH_NO_CACHE=1` |
| `todo_write` | Task list (merge default true; statuses pending/in_progress/completed/cancelled). **Session-durable** in session JSON; `/todos` list/clear; cleared on `/new`. Opt out: `AETHER_NO_TODO_WRITE=1` |
| `update_goal` | Goal progress via `/goal` + tool (`message` / `completed` / `blocked_reason`). **Session-durable**. TUI chip. Cleared on `/new`. Opt out: `AETHER_NO_GOAL=1` |
| `image_gen` | Imagine generate; saves under sessions `images/`; returns **`Image #N`** for later tools. `XAI_API_KEY`. `/imagine`. Opt out: `AETHER_NO_IMAGE_GEN=1` |
| `image_edit` | Imagine edits; `image[]` = paths, data URLs, or **`[Image #N]`**. Magick compress ladder. Opt out: `AETHER_NO_IMAGE_GEN=1` |
| `image_to_video` | Animate one image (path/data/`[Image #N]`/https). Saves under `videos/`. ZDR/tier N/A. Opt out: `AETHER_NO_VIDEO_GEN=1` |
| `reference_to_video` | Multi-image (2–7) video; same refs as edit. Opt out: `AETHER_NO_VIDEO_GEN=1` |
| `ask_user_question` | Multiple-choice (auto **Other** + freeform); optional option `preview` lines; multi_select. Full pager modal N/A. Opt out: `AETHER_NO_ASK_USER=1` |
| `lsp` | Code intelligence (`goToDefinition`, `findReferences`, `hover`, `goToImplementation`, `documentSymbol`, `workspaceSymbol`). Hover language fences; location/symbol caps; workspace-relative paths. Config: `~/.grok/lsp.json` + project. Opt out: `AETHER_NO_LSP=1` |
| `monitor` | Background shell streaming **stdout lines** as system-reminders. Args: `command`, `description`, `timeout_ms` (default 10h), `persistent`. Rate-limited; log under `…/terminal/monitor-{id}.log`; stop with `kill_task`. Opt out: `AETHER_NO_MONITOR=1` |
| `scheduler_*` | Scheduled prompts; durable file; fire inject; list shows **relative next_fire** + **missed=true** for overdue one-shots. `/loop` host UX. Multi-client N/A. Opt out: `AETHER_NO_SCHEDULER=1` |
| `memory_search` / `memory_get` | File memory; writers `/flush`/`/dream`; first-turn inject; auto-dream on exit/new |
| `search_tool` / `use_tool` | MCP discovery + call (when servers connect) |
| `skill` | Load discovered SKILL.md by name; marketplace N/A |
| `spawn_subagent` / `task` | Child agent: explore/plan/gp; bg + resume + worktree; **`task` alias**; personas N/A |
| `get_task_output` / `kill_task` | Poll / stop background tasks (subagents or shell); `timeout_ms`>0 waits |
| `wait_tasks` / `wait_commands_or_subagents` | Multi-id wait-all (default) or wait_any; default timeout 30s; max 20 ids; Read |
| `enter_plan_mode` / `exit_plan_mode` | Plan-first workflow; only `.grok/plan.md` is writable while active |

Writes outside `--cwd` are denied.

### Background shell

`run_terminal_cmd` with **`is_background: true`** starts `sh -c` on a worker thread and returns a **`bash-{pid}-{n}`** task id immediately (after the usual bash permission check). Poll with **`get_task_output`**; stop with **`kill_task`** (process kill, not cooperative-only).

- Shared cap with background subagents: **2** concurrent background tasks.
- Background `timeout`: **0 or omitted** means no wall-clock limit; a positive `timeout` kills the process when exceeded.
- Foreground path (default) still blocks and applies the usual 120s default timeout.
- **Desktop notify:** when a **background shell/subagent** finishes, or a **parent agent turn** completes (B19), Aether best-effort pings the desktop (`notify-send` if available). Opt out all: `AETHER_NO_DESKTOP_NOTIFY=1` or `AETHER_NOTIFY=0`. Turn-only off: `AETHER_NOTIFY_TURNS=0`. Method: `AETHER_NOTIFY_METHOD=auto|notify-send|osc9|osc777|bel|none`. Custom: `AETHER_NOTIFY_COMMAND='notify-send "$AETHER_NOTIFY_TITLE" "$AETHER_NOTIFY_BODY"'`.

## Memory

File-backed read tools over the same layout Grok Build writes:

```
~/.grok/memory/
  MEMORY.md                 # global
  {workspace-slug}/
    MEMORY.md
    sessions/*.md
```

| Tool / slash | Role |
|------|------|
| **`memory_search`** | Keyword rank over markdown chunks; returns path, line range, snippet, source |
| **`memory_get`** | Read a memory file (`path`, optional 0-based `from` + `lines`); 1-based `N→` lines |
| **`/flush`** | Persist session notes into `{slug}/sessions/YYYY-MM-DD.md` (model when creds; else heuristic; `/flush heuristic` forces offline) |
| **`/remember`** | Append a free-form **user note** to today's session log (no model call; B32) |
| **`/dream`** | Consolidate session logs into workspace `MEMORY.md` (model when creds; `/dream heuristic` offline; lock + recency-safe cleanup; slash bypasses auto gates) |
| **`/memory`** | Status / `path` / `help`; **`on`|`off`** process-local toggle (B15; env `AETHER_NO_MEMORY` still wins) |
| **First-turn inject** | Workspace + global `MEMORY.md` into system message once (opt-out `AETHER_NO_MEMORY_INJECT=1`) |
| **Auto-dream** | Gated consolidate on `/exit`/`/new`/EOF (opt-out `AETHER_NO_AUTO_DREAM=1`) |

- Prefer the current workspace dir when `MEMORY.md` mentions `--cwd` or the dirname matches the project basename; still search other workspaces at lower weight.
- Root: `AETHER_MEMORY_DIR`, else `$GROK_HOME/memory`, else `~/.grok/memory`.
- Opt out: `AETHER_NO_MEMORY=1`.
- **N/A / later:** SQLite/FTS/embeddings, post-compact re-inject, exact blake3 workspace hash.

## Plan mode

For ambiguous or multi-step work, the model (or you via **`/plan`**) can enter **plan mode**:

- Only **`<cwd>/.grok/plan.md`** may be edited via `search_replace` (other writes rejected).
- Shell / read / search / MCP stay available for research.
- The model finishes with **`exit_plan_mode`** (reads the plan file; auto-approves for v1).
- User: `/plan` on, `/plan off` (or `exit`) off, `/plan status`; **`/view-plan`** (aliases `/show-plan`, `/plan view`) dumps plan.md (B32).
- TUI: **Shift+Tab** enters plan on the first press from ask (`ask → plan → auto → always-approve → read-only`); header shows a **`plan`** chip. `/plan` / `/plan off` still work.
- **Exit ask:** model `exit_plan_mode` prompts y/n (TUI modal; REPL stdin). Deny keeps plan active. Headless non-TTY auto-approves (set `AETHER_PLAN_EXIT_ASK=1` to force deny without TTY).
- **Persist:** session JSON stores `plan_mode`; resume restores the chip/edit gate and injects a one-shot plan reminder.
- User toggle injects a `<system-reminder>` on the **next** agent turn so the model knows plan is on (or off after Shift+Tab leave).
- Opt out of plan (and of plan in the Shift+Tab ring): `AETHER_NO_PLAN_MODE=1`.

**Residual N/A:** remote Auto-mode classifier (local **auto**/accept-edits is in the Shift+Tab ring). Plan lifecycle (`Inactive` → `Pending` → `Active` → `Exit_Pending`) is implemented.

## Subagents

The parent model can call **`spawn_subagent`** with a `prompt` and optional `subagent_type`:

| Type | Behavior |
|------|----------|
| `explore` | Research with read/search/shell; **no file edits** |
| `plan` | Same tools as explore; returns an implementation plan |
| `general-purpose` | Full tools except nested spawn; may edit |

**Sync (default):** blocks until the child finishes; status shows `subagent: …` / `[sub] …`. Every run gets a **`sub-*`** id and a resume footer in the result.

**Background:** pass `background: true` on `spawn_subagent` → returns `subagent_id` immediately. Poll with **`get_task_output`** (`task_ids`, optional `timeout_ms`); cancel with **`kill_task`**. Max **2** concurrent background **tasks** shared with background shell. Background children use Always_Approve (no TUI ask modal) and still respect explore/plan edit denials. Cooperative cancel only.

**Resume:** pass **`resume_from`** with a prior `subagent_id` (same process). Continues the stored transcript: system prompt is refreshed, `prompt` is appended as the next user message. `subagent_type` must match the source when set (otherwise inherited). Works for sync and background. Transcripts are process-local (soft cap **32** archived subagent transcripts); not durable across process restarts.

**Auto-wake:** when a background subagent or shell task finishes, Aether delivers a `<system-reminder>` with the result (capped ~4KB) so the parent need not poll. **Mid-turn:** injected before the next model sample. **Idle:** REPL (before the next `> `) and TUI (empty compose, no modals; ~500ms poll) start a synthetic parent turn. Each completion is delivered once. Opt out: `AETHER_NO_AUTO_WAKE=1`. `get_task_output` still works for full output. Completions also fire a **desktop notify** (see Background shell) so unfocused terminals are easier to notice.

**Worktree isolation:** pass **`isolation: "worktree"`** (requires a git workspace). Creates a detached linked worktree under `~/.grok/aether/worktrees/<repo>-<sub-id>/` (override base with `AETHER_WORKTREE_DIR`) via `git worktree add --detach`. Child tools use that path as the workspace so edits do not touch the parent tree. The worktree is **preserved** after completion; the result includes `worktree_path` (merge/cherry-pick manually). **`resume_from`** reuses the source worktree when present. Untracked parent files are not copied (git worktree limitation). Opt out: `AETHER_NO_WORKTREE=1`. Cleanup orphans with `git worktree list` / `git worktree remove`.

Depth max 1 (children cannot spawn). Opt out: `AETHER_NO_SUBAGENTS=1` or `GROK_SUBAGENTS=0`.

**Not yet:** personas.

## Skills

Discovers `SKILL.md` packages from (low→high priority; same name: higher wins):

- `~/.grok/bundled/skills/`, `~/.claude/skills/`, `~/.grok/skills/`
- Walk cwd → parents: `.claude/skills/`, `.grok/skills/`, `.agents/skills/`

Also loads **flat commands**: `~/.grok/commands/*.md` and parents `.grok/commands/*.md` (plus `~/.claude/commands` / project `.claude/commands` unless `AETHER_NO_CLAUDE_SKILLS=1`). Skill packages win name collisions over command files.

Frontmatter `name` + `description`; body is the procedure. Catalog is injected into the **system prompt** on new sessions (disabled skills omitted). The model loads full text via the **`skill` tool**; users can `/skills`, `/skill <name>`, or `/name` for a short dump (works even when a skill is disabled).

**Config** (`~/.grok/config.toml` or project `aether.toml`):

```toml
[skills]
paths = ["~/extra-skills"]          # extra dirs or SKILL.md files
ignore = ["~/old-skills"]           # path-prefix hide (not listed/invocable)
disabled = ["dangerous-skill"]      # listed as (disabled); model skill tool denied; user slash OK
```

Env: `AETHER_SKILLS_DISABLED=a,b` appends disabled names; `AETHER_NO_CLAUDE_SKILLS=1` skips `.claude` roots; `AETHER_NO_SKILLS=1` disables all.

**Not yet:** plugin marketplace skills, `/create-skill`, Cursor-only roots, full gitignore-style ignore globs.

## MCP (stdio)

Configured under `[mcp_servers.<name>]` in `~/.grok/config.toml` (and project `aether.toml`):

```toml
[mcp_servers.filesystem]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
enabled = true
startup_timeout_sec = 60
```

Aether starts enabled MCP servers at process launch, lists **tools** (required), and best-effort **resources** + **prompts**. Model tools: Grok-shaped **`search_tool`** + **`use_tool`** (qualified `server__tool`), plus **`list_mcp_resources`** / **`read_mcp_resource`** and **`list_mcp_prompts`** / **`get_mcp_prompt`**. Catalog is a connect-time snapshot (no list_changed refresh). `/mcp` shows connection status and counts. Opt out: `--no-mcp` or `AETHER_NO_MCP=1`.

**Transports**

| Config | Transport |
|--------|-----------|
| `command` (+ optional `args` / `env`) | **stdio** (Content-Length JSON-RPC) |
| `url` (+ optional `headers`) | **Streamable HTTP** — POST JSON-RPC; `Accept: application/json, text/event-stream`; tracks `Mcp-Session-Id` |

```toml
[mcp_servers.remote]
url = "https://mcp.example.com/mcp"
# Prefer env for secrets:
bearer_token_env_var = "MY_MCP_TOKEN"
# Or expand env in header values:
# headers = { "Authorization" = "Bearer ${MY_MCP_TOKEN}" }
enabled = true
```

**Auth resolution (HTTP, first match wins):**

1. Explicit `headers` with a non-empty `Authorization` after `${ENV}` / `$ENV` expansion  
2. `bearer_token_env_var` → `Authorization: Bearer <env>`  
3. **`~/.grok/mcp_credentials.json`** (Grok-compatible) key `"{server}:{url}"` → use `token_response.access_token`  
   - Enroll OAuth with the Rust CLI (`grok`), or write tokens via **`/mcp set-token <name> <token>`** then **`/mcp reconnect`**
   - Aether can **write/merge** this file (A3.1); full browser OAuth still host-side

`/mcp` subcommands: `status` (default), `reconnect`, `auth`, `set-token`, **`doctor`** (in-process health; no host `grok`), `list-config`, optional legacy `host-doctor`, `help`. Auth sources show as `headers|env|credentials|none` (never prints tokens). Tokens via `set-token` or `~/.grok/mcp_credentials.json`.

**Not yet:** browser OAuth / DCR / callback, automatic refresh_token IdP grants, legacy dual-endpoint SSE-only servers, plugin-owned servers, resources/list_changed live refresh.

`use_tool` follows permission modes like shell (denied in read-only; ask in ask mode).

## Layout

| Path | Role |
|------|------|
| `main.odin` | Entry |
| `core/` | Version, paths, config, permissions |
| `cli/` | Flags |
| `agent/` | Auth, HTTP, chat, tool loop, sessions, slash |
| `mcp/` | MCP client (stdio + HTTP) + search_tool/use_tool |
| `skills/` | SKILL.md discovery + skill tool |
| `tools/` | Local tools |
| `tui/` | Fullscreen chat UI (raw terminal) |
| `scripts/` | `smoke.sh`, `tui-smoke.sh`, install helper |
| `harness/`, `telemetry/` | Placeholders |

## Tests

```bash
# from this tree (standalone) or monorepo root via make -C aether …
make build test smoke-tui

# or manually
export PATH="$PWD/.tools/bin:$PATH"
export ODIN_ROOT="$PWD/.tools/odin"
odin test agent -collection:aether=.
odin test tools -collection:aether=.
odin test core -collection:aether=.
```

Chat completions stream tokens to **stdout** as they arrive (SSE). Set `AETHER_NO_STREAM=1` to force non-streaming. Tool/progress lines stay on **stderr**. In the **TUI**, stream + tool cards update mid-turn; errors/cancel show in the status bar and notice lines (not only stderr).

**HTTP:** connect timeout 15s; total timeout 120s (non-stream) / 300s (SSE). Transient transport failures and HTTP 429/502/503/504 retry up to twice (before any stream payload). Mid-request **Ctrl+C** in the TUI aborts the in-flight curl transfer (xferinfo + key poll), exit code **4**.

**Permissions mid-turn:** Ctrl+O and Shift+Tab update the live mode for **subsequent tools** in the same turn (not tools already running). In `ask` mode:

| Key | Meaning |
|-----|---------|
| **y** / Enter | Allow once; also auto-allows later write/shell tools for the rest of the turn |
| **n** / Esc | Deny once |
| **a** | **Always allow** for this process (session grant): e.g. `Bash(git status *)` or `Edit` |
| **d** | **Never allow** for this process (session deny grant): same rule shape; deny wins over YOLO |

Session allow/deny grants are in-memory only (not written to config). Cleared on `/new`. Opt out both: `AETHER_NO_SESSION_ALLOW=1`.

`make smoke` needs auth. `make smoke-tui` does not (scripted keys via `script(1)`).

## Non-goals (for now)

ACP multi-client UI, persona subagents, full permission allow-list UI, full mermaid layout engine (fences are labeled), plan-mode free-text deny feedback, remote Auto-mode classifier.

## License

Same tree as Grok Build — see repository root `LICENSE`.
