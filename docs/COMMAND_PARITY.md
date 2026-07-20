# Slash command parity — Aether vs Grok Build

Review of **shared** command names. Aether-only commands (`/doctor`, `/soft-bash`, …) are out of scope for “match Grok.”

| Command | Grok behavior | Aether behavior | Status |
|---------|---------------|-----------------|--------|
| `/quit` (`exit`) | Quit app | Quit | **Match** |
| `/help` | Open command palette | Sectioned text help | **Partial** (no palette) |
| `/docs` (`howto`, `guides`) | How-to guides / docs.x.ai | Discover list + `/docs web` opens Build docs | **Partial** (no in-TUI guide picker) |
| `/home` (`welcome`) | Welcome screen | New empty session (welcome when TUI blocks empty) | **Match** |
| `/new` (`clear`) | New session | New session (`/clear` = same) | **Match** |
| `/fork` | Branch peer agent | Branch new session | **Partial** (no worktree fork UI) |
| `/compact` | Compact history | Compact history | **Match** |
| `/copy` | Copy Nth assistant | Copy Nth / TUI selection | **Match** |
| `/find` | Scrollback search | Scrollback search (TUI) | **Match** |
| `/history` | Prompt history search | List/filter prompts; TUI recall | **Match** |
| `/export` | Export conversation | Export md/json | **Match** |
| `/transcript` (`log`) | Open transcript in `$PAGER` | Export md + TUI suspends for `$PAGER` | **Match** |
| `/expand` | Re-print last folded block (minimal) | Expand last tool card (TUI) | **Partial** (fullscreen fold, not minimal re-print) |
| `/context` | Context usage pane | Context usage text | **Match** (text vs pane) |
| `/usage` (`cost`) | Credit/billing | Context fallback only — **billing N/A by design** | **N/A** (billing skipped) |
| `/model` (`m`) | Switch model | Set model / TUI picker | **Match** |
| `/effort` | Reasoning effort | Reasoning effort | **Match** |
| `/always-approve` (`yolo`) | Toggle YOLO | Toggle / set modes | **Match** |
| `/auto` | Classifier auto mode | Auto file edits, ask shell | **Partial** (no classifier) |
| `/multiline` (`ml`) | Toggle multiline | Toggle multiline | **Match** |
| `/compact-mode` | Toggle compact UI | Toggle compact UI | **Match** |
| `/vim-mode` | Vim scrollback keys | Vim scrollback keys | **Match** |
| `/hooks` | Extensions modal | TUI extensions hub (Hooks tab) + CLI | **Match** (hub; no per-hook toggle UI) |
| `/plugins` | Extensions modal | TUI extensions hub (Plugins tab) + CLI | **Match** (hub) |
| `/marketplace` | Extensions marketplace tab | Hub Market tab = local plugins (no remote catalog) | **Partial** (local only) |
| `/skills` | Extensions modal | TUI extensions hub (Skills tab) + CLI | **Match** (hub) |
| `/share` | Public session URL | Honest N/A + `/export` path | **Partial** (no cloud share) |
| `/session-info` | Session info | Session + context info | **Match** |
| `/rename` (`title`) | Rename session | Rename session | **Match** |
| `/dashboard` | Agent dashboard | Sessions + bg tasks text overview | **Partial** (no fullscreen dashboard) |
| `/cd` | Change dashboard workspace | Change process + session cwd | **Match** (session-scoped, not dashboard-only) |
| `/theme` (`t`) | Set theme | Set theme | **Match** |
| `/feedback` | Send product feedback | Local JSONL only | **Partial** |
| `/remember` | Save memory note | Append memory log | **Match** |
| `/plan` | Enter plan mode | Plan mode on/off/status | **Match** |
| `/view-plan` | Show plan | Show plan.md | **Match** |
| `/resume` | Session picker | TUI picker / list sessions | **Match** |
| `/mcps` | Extensions modal | TUI extensions hub (MCPs tab) + CLI | **Match** (hub) |
| `/btw` | Side agent question | Local note only | **Partial** |
| `/recap` | Model session recap | Local recent-turn recap | **Partial** (no model recap) |
| `/terminal-setup` | Terminal diagnostics | TERM/color/clipboard report | **Match** (text) |
| `/voice` | Dictation toggle | Honest N/A | **Partial** (not available) |
| `/loop` | Recurring prompt | Scheduler loop | **Match** |
| `/imagine` | Image gen | Image gen | **Match** |
| `/imagine-video` | Video gen | Video gen | **Match** |
| `/timestamps` | Toggle timestamps | Toggle timestamps | **Match** |
| `/toggle-mouse-reporting` | Toggle mouse capture | Toggle SGR mouse (TUI) | **Match** |
| `/settings` | Settings modal | TUI settings list (toggle vim/compact/timestamps/multiline; **no billing**) | **Partial** (browse/toggle; full form editor later) |
| `/privacy` | Cloud data-sharing toggle | Local privacy posture notes | **Partial** (no remote preference) |
| `/rewind` | Rewind picker | TUI user-turn picker; `/rewind N` still works | **Match** |
| `/login` | Login flow | Device-code / host login | **Match** |
| `/logout` | Clear credentials | Rename/remove auth.json (or env note) | **Match** |
| `/import-claude` | Claude settings modal | Scan Claude paths + import tips | **Partial** (no merge modal) |
| `/queue` | Mid-turn prompt queue | TUI FIFO queue (type+Enter mid-turn; force-send empty Enter; pane) | **Match** |
| `/tasks` | Bg + scheduled tasks list | Bg + scheduler + todos list | **Match** (text) |
| `/release-notes` (`changelog`) | Release notes pane | Local CHANGELOG.md head | **Match** (text) |
| `/config-agents` (`agents`) | Agents modal | Personas + subagent types list | **Partial** (no modal) |
| `/personas` | Manage personas modal | List personas | **Partial** |

## Aether-only (intentional)

`/about`, `/doctor`, `/soft-bash`, `/env`, `/paths`, `/features`, `/status`, `/diff`, `/flush`, `/dream`, `/memory`, `/goal`, `/todos`, `/create-skill`, `/skill`, `/save`, `/load`, `/import`, `/undo-file`, `/whoami`, `/aliases`, `/keys`, `/tools`, `/permissions`, `/version`, …

## Policy

- Prefer Grok **primary names** and **aliases** when both products implement the feature.
- When Aether cannot open Grok modals/panes, keep the **same command name** and provide the closest functional equivalent (text dump / list / picker).
- Do not advertise billing `/usage` as context-only without a note.
- Catalog order follows Grok `builtin_commands()` for shared commands.
