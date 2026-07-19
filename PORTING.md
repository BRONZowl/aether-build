# Aether full-port matrix

Living tracker for **Aether (Odin)** capability parity with **Grok Build (Rust)** and for **dual-product separation** in this monorepo.

**Program goal:** L1 agent core + L2 shell product + L3 full pager/UI at **Full** (or explicit **N/A**).  
**End state (separation):** two independent products — Aether under `aether/`, Rust under `crates/` — neither deletes the other; neither build requires the other.

**Not the goal:** bit-identical Rust crates, monorepo LOC match, deleting Rust, or every xAI-internal service.

Last updated: 2026-07-19 (S4 standalone extract). Tip: `aether` branch.

---

## Dual product / separation

| Product | Tree | Build | Binary names |
|---------|------|-------|--------------|
| **Aether** | `aether/` | `make -C aether build` (Odin) | `aether`, `grok-odin`, `aether-grok-odin` |
| **Grok Build** | `crates/` + Cargo root | `cargo … -p xai-grok-pager-bin` | `grok` / `xai-grok-pager` |

**Hard rule:** do **not** delete `crates/`, `third_party/`, `prod/`, or Cargo files. Shared `~/.grok` is **user-data interop**, not a source-tree dependency.

### Ship mode (locked)

| Mode | Choice | Meaning |
|------|--------|---------|
| **R0-A** | **Active** | Primary auth = **`XAI_API_KEY`** (and existing `~/.grok/auth.json` if present). Host `grok login` is **optional interop**, not required. |
| **R0-B** | Deferred | Full in-process browser OIDC in Odin (only if product later requires it). |

### Definition of done (separated)

1. **Runtime independence** — Aether needs no Rust `grok` binary (optional login bridge OK).
2. **Build independence** — Aether builds without Cargo / `crates/`; Rust builds without Odin / `aether/`.
3. **Self-contained layout** — outputs and wrappers live under `aether/` (`out/`, `bin/`).
4. **Parity ledger** — every subsystem row **Full** or **N/A** (this file).
5. **Dual docs** — peers, not “delete Rust endgame”.
6. **Optional extract** — export/subtree of `aether/` without removing monorepo copy (**S4 Done** — `scripts/export-standalone.sh` / `make extract`).

### Principles

1. Port by **product contract**, not crate filename.
2. Prefer **N/A** over fake ports for marketplace, multi-client ACP, Mixpanel twins, etc.
3. One vertical slice per cycle; `make -C aether build vet test smoke-tui`.
4. **Keep both products** — separation ≠ retirement delete.
5. Interop via `~/.grok` contracts and optional installed `grok`, never via compiling against `crates/`.

### Historical epics (R0–R4 complete; R5 cancelled)

| Epic | Title | State |
|------|--------|--------|
| **R0** | Odin-only charter + matrix + ship mode | **Complete (R0-A locked)** |
| **R1** | Ship-path polish + Odin CI + install story | **Complete** |
| **R2** | Kill hard host bridges (login optional; MCP doctor in-process) | **Complete** |
| **R3** | Finish-or-Drop remaining Partial/None rows | **Complete** |
| **R4** | Odin install/CI/dist polish | **Complete** |
| **R5** | Delete Rust product tree | **Cancelled** — dual-product plan keeps Rust |
| **S0–S3** | Dual-product separation (charter, layout, dual root) | **Active** |

### Capability matrix (Port / Bridge / Drop / Done)

| Capability | Rust home (examples) | Odin | Fate |
|------------|----------------------|------|------|
| Agent loop / tools / SSE | agent, tools, sampler | Strong | **Done** + residual polish |
| Auth session / API key | `xai-grok-auth` | Session + key | **Done** for R0-A; browser OIDC **Drop** unless R0-B |
| Host `grok login` | shell/auth | optional bridge | **R2a demoted** (optional legacy; API key primary) |
| Config product keys | config* | merge done | **Done**; remote/managed **Drop** |
| MCP runtime | mcp | Full | **Done**; **R2b doctor in-process** (`/mcp doctor`) |
| Skills + hooks | skills, hooks | Full | **Done**; OS sandbox **Drop** or later Port |
| Memory file-backed | memory | Full | **Done**; SQLite/embeddings **Drop** |
| Pager / TUI | pager* | C1–C2 | **Done**; full mermaid engine **Drop** |
| Sessions / slash | shell* | B2.1–2 | **Done**; multi-client ACP **Drop** (C3 N/A unless reopened) |
| Soft sandbox | sandbox | FS + soft bash | **Done** soft; Landlock **Drop** or later |
| Plugins / marketplace | marketplace | None | **Drop** |
| Telemetry / Mixpanel | telemetry, mixpanel | stub | **Drop** |
| Voice / update | voice, update | None | **Drop** |
| Multi-client ACP | acp-lib, shell ACP | None | **Drop** |

### Temporary bridges (R2)

| Bridge | Code | State |
|--------|------|--------|
| `aether login` → `grok login` | `agent/auth_host.odin` | **R2a done:** optional/legacy only; missing-host messages point at XAI_API_KEY |
| `/mcp doctor` / list-config | `agent/mcp_host.odin` | **R2b done:** in-process doctor; `host-doctor` optional legacy |
| Host required for daily use? | — | **No (R2c/R2d):** API key path + in-process MCP; uninstall Rust `grok` is fine |

### R1 deliverables (ship path)

| ID | Work | Status |
|----|------|--------|
| R1.1 | Close remaining Partial on ship path | **Deferred to R3** Finish-or-Drop (no ship-blocking waiver needed for API-key daily driver) |
| R1.2 | Install story + deps list | **Done** — `make install`, README deps table, `scripts/install-local.sh` |
| R1.3 | Odin-only CI | **Done** — `.github/workflows/aether.yml` + `scripts/bootstrap-odin.sh` |
| R1.4 | Dual branding without clobbering Rust `grok` | **Done** — `aether` / `grok-odin` / `aether-grok-odin` |

### R4 deliverables (default build)

| ID | Work | Status |
|----|------|--------|
| R4.1 | Root README primary path = Aether | **Done** |
| R4.2 | Root Makefile → `aether/` | **Done** — `make build test install dist` |
| R4.3 | Dist tarball | **Done** — `make dist` → `target/dist/aether-*.tar.gz` |
| R4.4 | Rename `aether` → `grok` | **Deferred** — dual names keep Rust `grok` free until R5 |
| R4.5 | Stop Rust in default CI | **N/A** — no product Cargo workflow; only Odin CI exists |

### R5 delete path (cancelled)

R5 physical removal of `crates/` is **cancelled**. Use inventory only:

```bash
make -C aether inventory-rust
# or: bash aether/scripts/inventory-rust-tree.sh
```

`scripts/r5-retire-rust.sh` is a parked wrapper that **only** runs inventory (never deletes).

### Separation deliverables (S0–S3)

| ID | Work | Status |
|----|------|--------|
| S0 | Dual-product charter; R5 cancelled | **Done** |
| S1 | Self-contained `aether/out`, `aether/bin`, tools search | **Done** |
| S2 | Runtime: optional host only; `~/.grok` interop docs | **Done** (prior R2 + docs) |
| S3 | Dual root Makefile + equal peer docs | **Done** |
| S4 | Optional standalone export / subtree | **Done** |

### S4 — Standalone export

Export **source** product tree without removing monorepo `aether/`:

```bash
# Snapshot (default) — fast, no monorepo git rewrite
bash aether/scripts/export-standalone.sh --dest /tmp/aether-standalone
make -C aether extract EXTRACT_ARGS='--dest /tmp/aether-standalone --verify'

# Optional: preserve aether/ commit history (subtree split)
bash aether/scripts/export-standalone.sh --dest /tmp/aether-hist --git-history
```

`make dist` remains a **binary** tarball (`out/dist/`). S4 is a **source** tree + standalone CI + `STANDALONE.md` + LICENSE. Does not push remotes.

### Verify (every phase)

```bash
make -C aether build vet test smoke-tui
```

---

## Status tags

| Tag | Meaning |
|-----|---------|
| **None** | Not started |
| **Thin** | Vertical slice / partial behavior only |
| **Partial** | Major paths work; gaps listed |
| **Full** | Product contract met (checklist or tests); residual gaps must be none or N/A |
| **N/A** | Permanent non-goal (reason required) |

---

## North star layers

| Layer | Scope | Target |
|-------|--------|--------|
| **L1** | Agent runtime: tools, loop, sessions, permissions, MCP, skills, subagents, plan, media, scheduler, memory | **Full** |
| **L2** | Shell product: auth (incl. browser login), config merge, slash builtins, hooks, plugins, sandbox, update | **Full** |
| **L3** | Fullscreen UI: pager-class TUI (markdown, scrollback, modals, themes, vim, find, tool chrome) | **Full** |
| **L4** | Platform extras: telemetry export, voice, marketplace, mermaid, multi-client ACP | **Full** or **N/A** per item |

**How we work:** advance **epics** (below). Prefer **Full** depth on listed surfaces over new thin tools. Update this file when status changes.

**Vanity metric:** Odin LOC vs `crates/codegen` (~2% today) is **not** the scoreboard. Track counts of Full / Partial / Thin / None rows.

---

## Permanent non-goals (N/A unless product needs reverse)

| Item | Why |
|------|-----|
| Exact Rust crate graph / filenames | Odin packages map by capability |
| xAI-internal-only APIs we cannot call | No public contract |
| Bit-identical telemetry / Mixpanel | Optional later; not product-blocking |
| Windows console as day-one | Linux/mac first; track separately |
| Line-for-line pager source copy | Capability parity OK; structure may be Odin-native |

---

## Subsystem matrix (crates → Aether)

| Grok / area | Primary crates | Aether | Status | Gaps / notes |
|-------------|----------------|--------|--------|--------------|
| Agent loop / sampling | `xai-grok-agent`, sampler | `agent/loop`, `chat`, `http`, `compact` | Full | Manual + auto-compact @ threshold; SSE stream + retry; rich multi-client stream events **N/A** |
| Auth | `xai-grok-auth` | `agent/auth*` | Full | R0-A: API key + session JSON + OIDC refresh read; host login optional legacy; in-process browser OIDC **N/A** (R0-B deferred) |
| Config | `xai-grok-config*` | `core` + `aether.toml` | Full | Product keys merge (A5.1); marketplace/remote/managed **N/A** |
| Tools runtime | `xai-grok-tools*` | `tools/`, `agent/*` | Full | See tool matrix (all Full or N/A) |
| Shell / session actor | `xai-grok-shell*` | `agent/session`, `slash`, `repl` | Full | B2.1–2 lifecycle + soft rewind; multi-client ACP **N/A** |
| Pager / TUI | `xai-grok-pager*` | `tui/` | Full | C1–C2 chrome; full mermaid layout engine **N/A** (fence labels ship) |
| Markdown render | `xai-grok-markdown*` | `tui/markdown` | Full | bold/italic/code/headers/lists; fences + lang; GFM tables; mermaid chrome only |
| MCP | `xai-grok-mcp` | `mcp/` | Full | stdio/HTTP + credentials + reconnect + in-process doctor; browser OAuth **N/A** |
| Skills | tools skills + shell | `skills/` | Full | Discovery + invoke + reload; marketplace **N/A** |
| Memory | `xai-grok-memory` | `tools/memory*`, flush/dream/inject | Full | file-backed + flush/dream/inject; SQLite/embeddings **N/A** |
| Hooks | `xai-grok-hooks` | `hooks/` | Full | Command + HTTP (A4.1–7); OS sandbox **N/A** |
| Plugins / marketplace | plugin crates | — | **N/A** | R3a Drop — not on Odin ship path; reopen as Port if product needs plugins |
| Sandbox | `xai-grok-sandbox` | workspace path gates | Full | Soft FS + soft bash ship; OS Landlock/Seatbelt **N/A** (R3c) |
| Workspace / worktree | `xai-grok-workspace*` | `worktree`, tools | Full | Linked worktrees for subagents; full remote workspace services **N/A** |
| Subagents | shell + tools task | `subagent`, `bg_task` | Full | explore/plan/gp, bg, resume, worktree; personas **N/A** |
| Plan mode | tools + shell tracker | `plan_mode` | Full | Lifecycle + gate; ACP reverse-request **N/A** |
| Scheduler | tools scheduler | `scheduler` | Full | Durable + fire; multi-client **N/A** |
| Media (image/video) | tools image/video | `image_*`, `video_gen` | Full | Magick + `[Image #N]` + paste/vision; ZDR/tier **N/A** |
| Telemetry | `xai-grok-telemetry` | stub dir | **N/A** | R3b Drop — not product-blocking; stub remains inert |
| Update | `xai-grok-update` | — | **N/A** | R3b Drop — manual install / rebuild; self-update later if needed |
| Voice | `xai-grok-voice` | — | **N/A** | R3b Drop — optional L4 |
| Secrets | `xai-grok-secrets` | env + files | Full | Env + credential files; OS keychain twin **N/A** |
| ACP multi-client | shell + acp-lib | — | **N/A** | R3d Drop — single-process TUI/REPL is the product (C3 closed) |

---

## Model tools matrix

| Tool | Status | Gaps |
|------|--------|------|
| `run_terminal_cmd` / bash | Full | BG + kill + terminal log; FG timeout clamp 300s; soft bash hard-deny + readonly auto-allow; **B13–B91** tool inspect surface; OS sandbox N/A; A1.10b |
| `read_file` | Full | Text + neg offset; binary reject; image metadata/inline; **PDF** (pdftotext) + **PPTX** (unzip a:t); `pages` max 20 |
| `search_replace` | Full | Exact/replace_all/create; **B6–B7** unique flexible match (case / newlines / whitespace-collapse); plan gate; hashline/notebook N/A; A1.7a |
| `write` | Full | Dedicated tool; plan-file gate; A1.2 |
| `delete_file` | Full | Dedicated tool; plan-file gate; A1.2 |
| `grep` | Full | -A/-B/-C, type, multiline; head_limit = output lines; A1.4a |
| `glob` | Full | `rg --files` + mtime sort + 100-cap; A1.1 |
| `list_dir` | Full | Tree + hide dots + gitignore via rg; char budget; fat-dir ext summary; A1.5 |
| `web_search` | Full | Responses hosted search + domains; auth session/API key; alt backends N/A; A1.12a |
| `web_fetch` | Full | Allowlist + SSRF + overflow artifact + cache + binary reject; proxy/htmd/media writers N/A; A1.6 |
| `todo_write` | Full | Merge/replace + session JSON durable; priority N/A; A1.8a |
| `ask_user_question` | Full | Multi/Other/freeform; TUI shows description + **preview** lines (B7); full pager chrome N/A; A1.11b |
| `enter_plan_mode` / `exit_plan_mode` | Full | Lifecycle + edit gate + approvals; ACP park N/A; A1.11d |
| `lsp` | Full | 7 ops incl. **diagnostics** (B10–B12: multi-file `paths[]`, `timeout_ms`, `errors_only`/`min_severity`, publishDiagnostics cache + pull); hover fence + caps + relative paths; A1.7b |
| `monitor` | Full | Lines + rate limit + persistent/timeout; session terminal log; sandbox N/A; A1.8b |
| `scheduler_*` | Full | Durable + fire inject; list missed/relative next_fire; multi-client N/A; A1.11a |
| `update_goal` | Full | Session-durable goal state; classifier/auto-pause N/A; A1.10a |
| `image_gen` / `image_edit` | Full | Compress + `[Image #N]` registry; path/clipboard paste + multimodal chat (M1); A1.9 |
| `image_to_video` / `reference_to_video` | Full | Token/path resolve via registry; ZDR/tier N/A; A1.9 |
| `spawn_subagent` / `task` | Full | explore/plan/gp + bg + resume + worktree; `task` alias; personas N/A; A1.11c |
| `get_task_output` / `kill_task` | Full | Multi-id + timeout_ms wait; cap 20 |
| `wait_tasks` / `wait_commands_or_subagents` | Full | Alias multi-wait; default 30s; wait_any; A1.3 |
| `skill` | Full | Discover + invoke + disabled gate; marketplace N/A; A1.12b |
| `search_tool` / `use_tool` | Full | Catalog + call; credentials write + `/mcp reconnect` (A3.1); browser OAuth N/A |
| MCP resource/prompt metas | Full | list/read resources + prompts; browser OAuth N/A |
| `memory_search` / `memory_get` | Full | File-backed; writers + inject + auto-dream (A2.1–3); SQLite/embeddings N/A |
| `deploy_app` | N/A | Grok stub; keep N/A unless product requires |

---

## Slash / host UX matrix

| Grok | Aether | Status |
|------|--------|--------|
| `/compact` | `/compact` | Full | manual + auto @% threshold (heuristic); model path on manual |
| `/always-approve` | `/always-approve` `/yolo` + Ctrl+O | Full | slash + mode cycle |
| `/flush` `/memory` | `/flush` `/memory` | Full | session log + status (inject/auto-dream flags) |
| `/remember` | `/remember` | Full | **B32** append user note to daily session log (no LLM rewrite modal) |
| `/dream` | `/dream` | Full | consolidate→MEMORY.md + lock; slash bypasses gates; gated auto on exit/new |
| `/view-plan` | `/view-plan` `/show-plan` `/plan view` | Full | **B32** dump `.grok/plan.md` |
| `/context` | `/context` | Full | est. tokens (chars/4) + usage bar + session stats |
| `/hooks-*` | `/hooks` | Full | status/list/reload/**paths/add/remove** (B18 hooks-paths); command + HTTP A4.1–7; trust N/A |
| `/plugins` `/reload-plugins` | — | **N/A** | R3a Drop with marketplace |
| `/session-info` | `/session-info` `/session` | Full | + context one-liner |
| `/settings` `/config` | `/config` `/settings` `/preferences` `/prefs` | Full | **B34** effective settings dump (no modal; no secrets) |
| `/feedback` | `/feedback` | Full | local JSONL; remote API N/A |
| `/btw` | `/btw` | Full | local notice only (not model) |
| `/goal` | `/goal` | Full | session-durable |
| `/loop` | `/loop` | Full | scheduler-backed |
| `/imagine` | `/imagine` | Full | image_gen |
| `/imagine-video` | `/imagine-video` | Full | image_to_video host; ref + optional prompt; C1.1 |
| `/plan` | `/plan` | Full | plan_mode lifecycle |
| `/todos` | `/todos` | Full | session-durable todos |
| Session load/save/new/rename/fork/delete/export | yes | Full | B2.1; **B14** `/sessions`; **B27** `/export json`; **B29** `/import` new session |
| `/rewind` conversation | yes | Full | **B3:** drop last N user turns; `/undo-file` for file stack (B2.2) |
| `/model` `/m` | yes | Full | **B3:** set/show model (TUI picker + slash/REPL) |
| `/effort` | yes | Full | **B3:** low\|medium\|high\|xhigh → `reasoning_effort` on chat body |
| `/auto` | yes | Full | **B3:** toggle accept-edits mode (also via `/always-approve auto`) |
| `/copy` | yes | Full | **B3:** Nth-latest assistant; **B40** TUI selected scrollback block when bare `/copy` |
| `/history` | yes | Full | **B4:** list/filter/show user prompts; TUI `/history N` fills composer |
| Project rules | AGENTS.md inject | Full | **B4–B5:** root→cwd + `~/.grok` + `.grok/rules` + `.claude`/`.cursor` (home + per-dir); opt out `AETHER_NO_PROJECT_RULES` / `AETHER_NO_CLAUDE_RULES` / `AETHER_NO_CURSOR_RULES` |
| `/mcp` | yes | Full | status/reconnect/set-token + **in-process doctor**/list-config; browser OAuth N/A |
| `/skills` `/skill` | yes | Full | list/invoke/reload; marketplace N/A |
| Browser `grok login` | `aether login` / `/login` | Full | Optional host bridge only (R0-A); `AETHER_GROK_BIN`; in-process OAuth N/A |

---

## Epic roadmap

### Phase A — L1 agent core → Full

| Epic | Title | Exit criteria | State |
|------|--------|---------------|--------|
| **A1** | **Tool surface Full** | Every product tool Full or N/A; backlog below closed | **Complete (A1.12)** |
| **A2** | Memory product Full | flush/dream/rewrite; search quality | **Complete (A2.1–3; SQLite/embeddings N/A)** |
| A3 | MCP Full | OAuth/credentials write path, reconnect, resource/prompt parity | **Complete (A3.1–2: credentials + reconnect + host doctor; in-process OAuth N/A)** |
| A4 | Skills + hooks + sandbox Full | Local hooks; sandbox contract; skills parity | **Complete (A4.1–7: command + HTTP hooks + skills Full; OS sandbox residual N/A)** |
| A5 | Config + auth Full | Full config merge; browser login or documented host bridge | **Complete (A5.1–2: product config + host login bridge; remote config N/A)** |

### Phase B — L2 shell product

| Epic | Title | Exit criteria | State |
|------|--------|---------------|--------|
| B1 | Slash builtins Full | compact, feedback, btw, memory, context, … | **Complete (B1.1–3; remote feedback API N/A)** |
| B2 | Session actor Full | lifecycle, notifications, single-process reverse-request where needed | **Complete (B2.1 lifecycle + B2.2 soft file rewind; multi-client ACP N/A → C3/D)** |
| **B3** | Slash parity depth | `/rewind` conversation, `/model`, `/effort`, `/auto`, `/copy` | **Complete** |
| **B4** | History + project rules | `/history` recall; AGENTS.md inject | **Complete** |
| **B5** | Vendor rules dirs | `.claude` / `.cursor` rules + home compat | **Complete** |
| **B6** | search_replace flexible match | case-insensitive + CRLF normalize unique spans | **Complete** |
| **B7** | WS-collapse match + ask_user previews | whitespace-collapsed unique span; TUI option preview | **Complete** |
| **B8** | `/compact-mode` TUI density | denser chrome; `[ui] compact_mode` | **Complete** |
| **B9** | Persist UI prefs | theme/vim/compact → `~/.grok/config.toml` | **Complete** |
| **B10** | LSP diagnostics | `operation: diagnostics` via publishDiagnostics cache | **Complete** |
| **B11** | Multi-file diagnostics | `paths[]` + `timeout_ms` settle wait | **Complete** |
| **B12** | Diagnostics severity filter | `errors_only` / `min_severity` | **Complete** |
| **B13** | Bash rule globs | multi-`*` / `?` / `[]` for `Bash(…)` allow/deny | **Complete** |
| **B14** | Sessions dashboard + git readonly | richer `/sessions` list; more git read-only cmds | **Complete** |
| **B15** | Persist permission + memory toggle | `[ui] permission_mode` on Shift+Tab/slash; `/memory on|off` process | **Complete** |
| **B16** | Soft-bash pkg-manager readonly | npm/pnpm/yarn/uv/rustup/pip/python/go + cargo inspect auto-allow | **Complete** |
| **B17** | Persist model + effort | `[models] default` + `default_reasoning_effort` on `/model` `/effort` | **Complete** |
| **B18** | Hooks paths management | `~/.grok/hooks-paths`; `/hooks add|remove|paths|list` (trust N/A) | **Complete** |
| **B19** | Turn notify + `/diff` | desktop notify on agent turn done; git status/diff slash | **Complete** |
| **B20** | TUI slash Tab complete | Tab completes/cycles `/` commands in compose (focus toggle otherwise) | **Complete** |
| **B21** | `/status` + `/version` | product dashboard slash; headless turn notify parity | **Complete** |
| **B22** | TUI `@path` Tab complete | Tab completes `@file` / path tokens (dir listing + cycle) | **Complete** |
| **B23** | Durable prompt history | `~/.grok/aether/prompt-history.jsonl`; Up/Down across sessions | **Complete** |
| **B24** | Workspace `@path` via rg | Tab `@query` searches tree with `rg --files` (fallback dir list) | **Complete** |
| **B25** | Build-tool soft-bash + `/usage` | make/odin/pytest inspect auto-allow; `/usage`·`/cost` → `/context` | **Complete** |
| **B26** | TUI live context chip | header `ctx:N%` from session + streaming draft (chars/4) | **Complete** |
| **B27** | `/export` JSON | `json` / `.json` path writes full session dump; md remains default | **Complete** |
| **B28** | REPL history + cmake soft-bash | REPL appends durable prompt history; cmake/ninja/meson inspect | **Complete** |
| **B29** | `/import` + headless history | import export JSON as new session; `-p` writes prompt-history | **Complete** |
| **B30** | `/doctor` health check | auth, host deps (rg/git/odin), paths, hooks/mcp/skills summary | **Complete** (+ **B39** optional tools) |
| **B31** | Stream follow + `just` soft-bash | stick-to-bottom only when at tail; mid-turn scroll keys; `just --list/--show` auto-allow | **Complete** |
| **B32** | `/remember` + `/view-plan` | user memory note → daily log; show `.grok/plan.md` | **Complete** |
| **B33** | Soft-bash `gh` inspect | pr/issue/repo list·view·status·diff; api GET; mutators ask | **Complete** |
| **B34** | `/config` effective dump | process-effective settings + paths + env overrides (secrets redacted) | **Complete** |
| **B35** | Soft-bash docker compose | `docker compose`/`docker-compose` ps·config·logs; up/build/run still ask | **Complete** |
| **B36** | Soft-bash terraform/helm + `/ml` | terraform plan/validate/state list; helm list/status/template; `/ml` multiline | **Complete** |
| **B37** | `/timestamps` | HH:MM transcript prefixes; `[ui] timestamps` persist; stamp survive rebuild | **Complete** |
| **B38** | Soft-bash bun/deno/poetry | pm ls / info / check / show inspect; install/run still ask | **Complete** |
| **B39** | `/doctor` host tools | optional curl/gh/docker/clipboard/notify-send (warn if missing) | **Complete** |
| **B40** | TUI `/copy` selected + zig soft-bash | bare `/copy` copies selected block; `zig version/env/ast-check` | **Complete** |
| **B41** | `/keys` shortcuts | TUI keyboard cheat sheet (`/bindings` `/shortcuts`) | **Complete** |
| **B42** | Soft-bash swift/dotnet + doctor zig | package describe / --info; build/run still ask; doctor optional zig | **Complete** |
| **B43** | Soft-bash sqlite3/redis-cli | .tables/SELECT / ping/info/get; DELETE/SET/FLUSH still ask | **Complete** |
| **B44** | Soft-bash psql/mysql | `-c SELECT` / `-e SHOW`; bare interactive + DML still ask | **Complete** |
| **B45** | `/tools` catalog | list model tools + short descriptions; optional filter | **Complete** |
| **B46** | Soft-bash curl/wget/ffprobe | GET/HEAD/spider/-O -; no POST/-o download; ffprobe always inspect | **Complete** |
| **B47** | `/soft-bash` status | explain hard-deny + readonly auto-allow families; opt-out env | **Complete** |
| **B48** | `/soft-bash on|off` | process-local toggle (env kill-switch still wins) | **Complete** |
| **B49** | Soft-bash fd/eza + `ffmpeg -i` | modern ls/find; ffmpeg probe without encode/output | **Complete** |
| **B50** | `/about` product blurb | version + discover tips (/keys /tools /doctor /soft-bash) | **Complete** |
| **B51** | Soft-bash http/xh + tips | HTTPie/xh GET/HEAD auto-allow; /status·/doctor tips → /about | **Complete** |
| **B52** | Soft-bash dust/duf/tokei/… | modern disk/process/LOC viewers + tip alignment | **Complete** |
| **B53** | `/aliases` | slash alias table (/m /yolo /cm /settings …) with filter | **Complete** |
| **B54** | Soft-bash `nix` inspect | flake show/metadata/search/doctor; build/run/shell still ask | **Complete** |
| **B55** | Startup discover tips | REPL banner + TUI notice → /about /keys /tools /help | **Complete** |
| **B56** | TUI clear notices + aws soft-bash | `/clear`/`/new` wipe notice bar; aws sts/s3 ls/describe inspect | **Complete** |
| **B57** | Soft-bash gcloud + az | gcloud list/describe/info; az list/show; create/delete still ask; doctor optional | **Complete** |
| **B58** | Soft-bash podman + brew | podman ps/images/logs (docker surface); brew list/info/search; install still ask | **Complete** |
| **B59** | Soft-bash apt/dnf/pacman | apt list/search/show; dnf/yum list/info; pacman -Q/-Ss/-Si; install still ask | **Complete** |
| **B60** | Soft-bash flatpak/snap/apk | list/info/search; install/run/add still ask; doctor optional | **Complete** |
| **B61** | `/permissions` dashboard | mode table + change tips; aliases `/perm`; Shift+Tab /yolo /auto | **Complete** |
| **B62** | `/env` product env catalog | AETHER_* kill-switches + set status; secrets redacted; filter/`set` | **Complete** |
| **B63** | `/paths` product path dashboard | GROK_HOME/config/sessions/memory/auth/history + exists marks | **Complete** |
| **B64** | Soft-bash pipx/gem/composer | list/show/search/outdated; install/require/run still ask | **Complete** |
| **B65** | Sectioned `/help` | Discover/Session/… sections; optional `/help filter` | **Complete** |
| **B66** | Soft-bash bundle + rake | bundle list/show/check; rake -T/--tasks; install/exec still ask | **Complete** |
| **B67** | Soft-bash mvn + gradle | dependency:tree/help; tasks/dependencies; package/build still ask | **Complete** |
| **B68** | `/features` flags dashboard | process-effective feature on/off + gates; aliases `/flags` | **Complete** |
| **B69** | Soft-bash sbt | tasks/about/dependencyTree/show; bare/compile/run still ask | **Complete** |
| **B70** | Soft-bash bazel/bazelisk | query/cquery/info/version; build/run/test still ask | **Complete** |
| **B71** | Soft-bash pulumi | stack ls/output, config get, about; up/destroy/preview still ask | **Complete** |
| **B72** | Soft-bash ansible family | list-hosts, playbook list/syntax, inventory, galaxy list; apply still ask | **Complete** |
| **B73** | Soft-bash vagrant | status/global-status/box list/validate; up/destroy/ssh still ask | **Complete** |
| **B74** | Soft-bash packer | validate/inspect/fmt -check; build/init still ask | **Complete** |
| **B75** | Soft-bash consul + nomad | members/catalog/kv get; job status/plan/alloc logs; put/run still ask | **Complete** |
| **B76** | Soft-bash vault | status/secrets list/auth list; no auto secret read/write | **Complete** |
| **B77** | Soft-bash argocd | app list/get/diff, cluster/repo list; sync/delete/login still ask | **Complete** |
| **B78** | Soft-bash flux | get/export/tree/logs/check; create/reconcile/bootstrap still ask | **Complete** |
| **B79** | Soft-bash istioctl | version/proxy-status/analyze/proxy-config; install/apply still ask | **Complete** |
| **B80** | `/soft-bash check` | dry-run hard-deny / auto-allow / ask for a shell string | **Complete** |
| **B81** | Soft-bash kustomize/kubectx/kubens | build/version; list/current; edit/switch still ask | **Complete** |
| **B82** | Soft-bash skaffold | diagnose/render/schema/version; run/dev/delete still ask | **Complete** |
| **B83** | Soft-bash kind + minikube | get clusters/status/profile list; create/start/delete still ask | **Complete** |
| **B84** | Soft-bash k3d + tilt | cluster list/get; describe/get/args; create/up/down still ask | **Complete** |
| **B85** | Soft-bash crane/skopeo/dive | manifest/digest/inspect/list-tags; push/copy/delete still ask | **Complete** |
| **B86** | Soft-bash syft/grype/trivy | SBOM/vuln scan to stdout; login/db update/server/file out still ask | **Complete** |
| **B87** | Soft-bash cosign/oras/regctl | verify/tree; manifest fetch/discover; digest/manifest/tag ls; sign/push/copy still ask | **Complete** |
| **B88** | Soft-bash buildah/nerdctl/ctr | images/containers/ps/logs/inspect list; bud/from/run/pull/push still ask | **Complete** |
| **B89** | Soft-bash helmfile/stern/kubeconform | list/status/template/diff; multi-pod logs; manifest validate; apply/sync still ask | **Complete** |
| **B90** | Soft-bash tflint/terraform-docs/terragrunt | lint; docs to stdout; plan/validate/show/state list; apply/init/output-file still ask | **Complete** |
| **B91** | Soft-bash checkov/tfsec/infracost | policy/security/cost scan to stdout; create-config/out-file/auth/comment still ask | **Complete** |

### Phase C — L3 pager / TUI

| Epic | Title | Exit criteria | State |
|------|--------|---------------|--------|
| C1 | Pager chrome Full | scrollback, md, tool cards, modals, find | **Complete (C1.1–3: fences + GFM tables + mermaid/lang labels; themes/vim under C2)** |
| C2 | Themes / vim / mouse | Grok key/theme parity | **Complete (C2.1–6: themes, vim, mouse, middle paste, bracketed paste)** |
| C3 | ACP UI bridge | if multi-client required | **N/A (R3d Drop)** |

### Phase D — L4 platform (optional)

Telemetry, update, voice, mermaid layout engine, marketplace — **N/A (R3 Drop)** unless reopened as Port.

### Phase R — Rust retirement

See **[Rust retirement](#rust-retirement-odin-only-endgame)** above (R0–R5).

### R3 Finish-or-Drop summary

| Batch | Items | Outcome |
|-------|--------|---------|
| R3a | Plugins / marketplace / `/plugins` | **N/A** |
| R3b | Telemetry / update / voice | **N/A** |
| R3c | OS Landlock/Seatbelt | **N/A** (soft sandbox Full) |
| R3d | C3 ACP multi-client | **N/A** |
| R3e | Mermaid layout engine | **N/A** (fence labels Full) |
| R3f | Rich multi-client stream events | **N/A** (agent loop Full for single-process) |
| Ship-path Partial→Full | Agent/auth/config/tools/shell/pager/md/sandbox/workspace/media/secrets | **Full** with residual N/A notes |

Ship path has **no unowned Partial/None** rows remaining.

---

## Epic A1 — Tool surface Full (active)

### Backlog (implementation order for next sessions)

1. ~~**`glob` tool**~~ — **done** (Full)  
2. ~~**`write` / `delete_file`**~~ — **done** (Full)  
3. ~~**`wait_*` / multi-task wait**~~ — **done** (Full)  
4. **Close Partial tools** — **done through A1.12** (all model tools Full or N/A)  
5. **Media** — Image#N done; multimodal paste deferred  
6. **Subagent** — core Full; personas N/A  
7. **Epic A1 closed** — next **A2 memory writers** / A3 MCP OAuth / B1 slash builtins

Also check: DENY for explore should filter "task" from schema - tool_name_denied already uses deny list.

Fix task_is_missed logic: for one-shot with interval 5m and created 1h ago, next_fire = created+interval = 55m ago. Good.

Run tests.

### A1 checklist template (per tool)

- [ ] Schema matches Grok required/optional fields  
- [ ] Errors match Grok intent (not necessarily string-identical)  
- [ ] Permission class correct  
- [ ] Offline tests for pure logic  
- [ ] PORTING.md row → Full  

---

## Metrics snapshot (kickoff)

| Tag | Approx. subsystem rows | Approx. tool rows |
|-----|------------------------|-------------------|
| Full | 0 | 0 |
| Partial | many | many |
| Thin | many | few |
| None | hooks, plugins, pager, compact, … | glob, wait, delete_file, … |

Recompute after each epic.

---

## Related

- User-facing overview: [README.md](./README.md)  
- Private mirror (org): `BronzOwl-Labs/aether-grok-build` branch `aether`  
- Reference: `crates/codegen/xai-grok-*` (read-only for port work)  
