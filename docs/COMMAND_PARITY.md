# Slash command parity — Aether vs Grok Build

Review of **shared** command names. Aether-only commands (`/doctor`, `/soft-bash`, …) are out of scope for “match Grok.”

| Command | Grok behavior | Aether behavior | Status |
|---------|---------------|-----------------|--------|
| `/quit` (`exit`) | Quit app | Quit | **Match** |
| `/help` | Open command palette | TUI searchable command palette; sectioned text in REPL | **Match** |
| `/docs` (`howto`, `guides`) | How-to guides / docs.x.ai | TUI docs picker (local md + web + discover) | **Match** |
| `/home` (`welcome`) | Welcome screen | New empty session (welcome when TUI blocks empty) | **Match** |
| `/new` (`clear`) | New session | New session (`/clear` = same) | **Match** |
| `/fork` | Branch peer agent | Branch new session | **Partial** (no worktree fork UI) |
| `/compact` | Compact history | Compact history | **Match** |
| `/copy` | Copy Nth assistant | Copy Nth / TUI selection | **Match** |
| `/find` | Scrollback search | Scrollback search (TUI) | **Match** |
| `/history` | Prompt history search | List/filter prompts; TUI recall | **Match** |
| `/export` | Export conversation | Export md/json | **Match** |
| `/transcript` (`log`) | Open transcript in `$PAGER` | Export md + TUI suspends for `$PAGER` | **Match** |
| `/expand` | Re-print last folded block (minimal) | Expand last tool card (fullscreen TUI) | **Match** |
| `/context` | Context usage pane | Context usage text | **Match** (text vs pane) |
| `/usage` (`cost`) | Credit/billing | Context fallback only | **N/A** (billing skipped by design) |
| `/model` (`m`) | Switch model | Set model / TUI picker | **Match** |
| `/effort` | Reasoning effort | Reasoning effort | **Match** |
| `/always-approve` (`yolo`) | Toggle YOLO | Toggle / set modes | **Match** |
| `/auto` | Classifier auto mode | Accept file edits; ask shell (local Auto) | **Match** (remote classifier N/A) |
| `/multiline` (`ml`) | Toggle multiline | Toggle multiline | **Match** |
| `/compact-mode` | Toggle compact UI | Toggle compact UI | **Match** |
| `/vim-mode` | Vim scrollback keys | Vim scrollback keys | **Match** |
| `/hooks` | Extensions modal | TUI extensions hub (Hooks tab) + CLI | **Match** |
| `/plugins` | Extensions modal | TUI extensions hub (Plugins tab) + CLI | **Match** |
| `/marketplace` | Extensions marketplace tab | Hub Market tab = local plugins | **Match** (local; no remote catalog) |
| `/skills` | Extensions modal | TUI extensions hub (Skills tab) + CLI | **Match** |
| `/share` | Public session URL | Export transcript + clipboard path (local share) | **Match** (no public URL) |
| `/session-info` | Session info | Session + context info | **Match** |
| `/rename` (`title`) | Rename session | Rename session | **Match** |
| `/dashboard` | Agent dashboard | Interactive sessions + bg + scheduled | **Match** |
| `/cd` | Change dashboard workspace | Change process + session cwd | **Match** |
| `/theme` (`t`) | Set theme | Set theme | **Match** |
| `/feedback` | Send product feedback | Local JSONL under sessions dir | **Match** (local only; remote N/A) |
| `/remember` | Save memory note | Append memory log | **Match** |
| `/plan` | Enter plan mode | Plan mode on/off/status | **Match** |
| `/view-plan` | Show plan | Show plan.md | **Match** |
| `/resume` | Session picker | TUI picker / list sessions | **Match** |
| `/mcps` | Extensions modal | TUI extensions hub (MCPs tab) + CLI | **Match** |
| `/btw` | Side agent question | Off-transcript model answer (local if offline) | **Match** |
| `/recap` | Model session recap | Model summary + local fallback | **Match** |
| `/terminal-setup` | Terminal diagnostics | TERM/color/clipboard report | **Match** |
| `/voice` | Dictation toggle | Not available | **N/A** (no STT stack) |
| `/loop` | Recurring prompt | Scheduler loop | **Match** |
| `/imagine` | Image gen | Image gen | **Match** |
| `/imagine-video` | Video gen | Video gen | **Match** |
| `/timestamps` | Toggle timestamps | Toggle timestamps | **Match** |
| `/toggle-mouse-reporting` | Toggle mouse capture | Toggle SGR mouse (TUI) | **Match** |
| `/settings` | Settings modal | TUI settings (theme/perm/model/toggles/privacy; **no billing**) | **Match** |
| `/privacy` | Cloud data-sharing toggle | Persist `[privacy] coding_data_share` locally | **Match** (local; no remote API) |
| `/rewind` | Rewind picker | TUI user-turn picker; `/rewind N` | **Match** |
| `/login` | Login flow | Device-code / host login | **Match** |
| `/logout` | Clear credentials | Rename/remove auth.json (or env note) | **Match** |
| `/import-claude` | Claude settings modal | Scan + `apply` merges mcpServers into config.toml | **Match** (partial Claude surface) |
| `/queue` | Mid-turn prompt queue | TUI FIFO queue + force-send | **Match** |
| `/tasks` | Bg + scheduled tasks list | Dashboard focused on bg tasks | **Match** |
| `/release-notes` (`changelog`) | Release notes pane | Local CHANGELOG.md head | **Match** |
| `/config-agents` (`agents`) | Agents modal | TUI personas/agents list + stub create | **Match** |
| `/personas` | Manage personas modal | Same personas modal | **Match** |

## Intentional N/A

| Item | Why |
|------|-----|
| **Billing** (`/usage` manage) | Product skip |
| **Voice dictation** | No speech-to-text pipeline in Aether |
| Public session URL share | No cloud share backend |
| Remote marketplace catalog | Local plugins only |
| Remote privacy / feedback APIs | Local files only |
| Worktree fork UI | Session fork exists; dashboard worktree UI later |

## Policy

- Prefer Grok **primary names** and **aliases** when both products implement the feature.
- When Aether cannot open Grok cloud surfaces, keep the **same command name** and closest local equivalent.
- Do not claim billing `/usage` without a note.
- Catalog order follows Grok `builtin_commands()` for shared commands.
