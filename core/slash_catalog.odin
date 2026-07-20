// Package core — single source of truth for displayed slash commands.
// Drives /help, /aliases, and TUI slash menu primaries (Grok-facing names).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package core

import "core:strings"

// Slash_Entry is one product slash command for display surfaces.
// Dispatch still lives in agent/slash.odin; this table is display + completion only.
Slash_Entry :: struct {
	primary:    string,   // menu + canonical name, e.g. "/quit"
	aliases:    []string, // e.g. {"/exit", "/q"}
	section:    string,   // /help section title
	help_left:  string,   // left column incl. args, e.g. "/help [filter]"
	help_right: string,   // /help description (+ optional alias notes)
	desc:       string,   // slash dropdown description (Grok-facing when shared; else help_right)
	in_menu:    bool,     // show primary on bare `/` menu
}

// Slash_Match is one row in the TUI slash dropdown (Grok SuggestionRow-shaped).
Slash_Match :: struct {
	name: string, // e.g. "/quit" or alias "/exit"
	desc: string, // short description for the right column
}

// SLASH_CATALOG: bare-/ menu order matches Grok builtin_commands() for shared
// cmds. Redundant names are aliases (not separate menu rows):
//   /session → /session-info, /sessions → /resume
// Aether-only discover dumps (env/paths/doctor/…) stay in /help but in_menu=false.
// /help groups by section title (not array order).
SLASH_CATALOG := [?]Slash_Entry {
	{
		primary = "/quit",
		aliases = {"/exit", "/q"},
		section = "Exit",
		help_left = "/quit",
		help_right = "quit (/exit, /q)",
		desc = "Quit the application",
		in_menu = true,
	},
	{
		primary = "/help",
		aliases = {"/?"},
		section = "Discover",
		help_left = "/help [filter]",
		help_right = "this help (optional substring filter)",
		desc = "List slash commands by section",
		in_menu = true,
	},
	{
		primary = "/docs",
		aliases = {"/howto", "/guides"},
		section = "Discover",
		help_left = "/docs [web|title]",
		help_right = "guides + online Build docs (/howto)",
		desc = "Open How-to Guides or online Build docs",
		in_menu = true,
	},
	{
		primary = "/home",
		aliases = {"/welcome"},
		section = "Session",
		help_left = "/home",
		help_right = "return to welcome (new empty session)",
		desc = "Return to the welcome screen",
		in_menu = true,
	},
	{
		primary = "/new",
		aliases = {"/clear"},
		section = "Session",
		help_left = "/new",
		help_right = "start a fresh session (/clear)",
		desc = "Start a new session",
		in_menu = true,
	},
	{
		primary = "/fork",
		section = "Session",
		help_left = "/fork [title]",
		help_right = "branch conversation into a new session",
		desc = "Branch the current session into a peer agent",
		in_menu = true,
	},
	{
		primary = "/compact",
		section = "Memory & context",
		help_left = "/compact [notes]",
		help_right = "compress history (heuristic|status|focus)",
		desc = "Compact conversation history",
		in_menu = true,
	},
	{
		primary = "/copy",
		section = "Session",
		help_left = "/copy [N]",
		help_right = "copy Nth-latest assistant (TUI: selected)",
		desc = "Copy last response to clipboard (/copy N for Nth-latest)",
		in_menu = true,
	},
	{
		primary = "/find",
		section = "TUI & chrome",
		help_left = "/find [text]",
		help_right = "(TUI) search scrollback",
		desc = "Search the conversation scrollback",
		in_menu = true,
	},
	{
		primary = "/history",
		section = "Session",
		help_left = "/history [n|text]",
		help_right = "list/filter/show session user prompts",
		desc = "Search prompt history",
		in_menu = true,
	},
	{
		primary = "/export",
		section = "Session",
		help_left = "/export [json|md] [path]",
		help_right = "transcript (md default; json dump)",
		desc = "Export the current conversation to a file or clipboard",
		in_menu = true,
	},
	{
		primary = "/transcript",
		aliases = {"/log"},
		section = "Session",
		help_left = "/transcript",
		help_right = "export + open in $PAGER (/log)",
		desc = "View the full conversation transcript in your pager ($PAGER)",
		in_menu = true,
	},
	{
		primary = "/expand",
		section = "TUI & chrome",
		help_left = "/expand",
		help_right = "(TUI) expand last tool card",
		desc = "Expand the last collapsed tool card",
		in_menu = true,
	},
	{
		primary = "/context",
		section = "Memory & context",
		help_left = "/context",
		help_right = "estimated context window usage",
		desc = "View context usage",
		in_menu = true,
	},
	{
		primary = "/usage",
		aliases = {"/cost"},
		section = "Memory & context",
		help_left = "/usage [show|manage]",
		help_right = "credit/billing (Grok); aether shows context fallback",
		desc = "View credit usage or manage billing",
		in_menu = true,
	},
	{
		primary = "/model",
		aliases = {"/m"},
		section = "Model & auth",
		help_left = "/model [id]",
		help_right = "show or set model (/m)",
		desc = "Switch the active model",
		in_menu = true,
	},
	{
		primary = "/effort",
		section = "Model & auth",
		help_left = "/effort [level]",
		help_right = "reasoning effort: low|medium|high|xhigh|off",
		desc = "Set reasoning effort for the current model",
		in_menu = true,
	},
	{
		primary = "/always-approve",
		aliases = {"/yolo"},
		section = "Permissions & plan",
		help_left = "/always-approve [on|off|status]",
		help_right = "permission mode (/yolo)",
		desc = "Toggle always-approve mode (skip all permission prompts)",
		in_menu = true,
	},
	{
		primary = "/auto",
		section = "Permissions & plan",
		help_left = "/auto [on|off]",
		help_right = "auto-approve file edits; ask for shell",
		desc = "Auto-approve file edits; ask for shell",
		in_menu = true,
	},
	{
		primary = "/multiline",
		aliases = {"/ml"},
		section = "TUI & chrome",
		help_left = "/multiline|/ml",
		help_right = "(TUI) toggle multiline compose",
		desc = "Toggle multiline input mode (swap Enter and Shift+Enter)",
		in_menu = true,
	},
	{
		primary = "/compact-mode",
		aliases = {"/cm"},
		section = "TUI & chrome",
		help_left = "/compact-mode [on|off]",
		help_right = "denser TUI chrome (/cm)",
		desc = "Toggle compact UI (less padding, more content)",
		in_menu = true,
	},
	{
		primary = "/vim-mode",
		aliases = {"/vim"},
		section = "TUI & chrome",
		help_left = "/vim-mode [on|off]",
		help_right = "scrollback j/k/g/G/i (TUI)",
		desc = "Toggle vim-style scrollback keybindings (j/k, h/l, g/G, y/Y, …)",
		in_menu = true,
	},
	{
		primary = "/hooks",
		section = "Extensions",
		help_left = "/hooks [status|list|paths|add|remove|reload]",
		help_right = "local hooks",
		desc = "List local hooks status",
		in_menu = true,
	},
	{
		primary = "/plugins",
		aliases = {"/plugin"},
		section = "Extensions",
		help_left = "/plugins",
		help_right = "list/add/remove/reload local plugins (M4)",
		desc = "List local plugins",
		in_menu = true,
	},
	{
		primary = "/marketplace",
		section = "Extensions",
		help_left = "/marketplace",
		help_right = "local plugins (no remote marketplace UI)",
		desc = "Browse plugins marketplace (local plugins list)",
		in_menu = true,
	},
	{
		primary = "/skills",
		section = "Extensions",
		help_left = "/skills [reload]",
		help_right = "list skills + commands (reload rediscovers)",
		desc = "List discovered skills",
		in_menu = true,
	},
	{
		primary = "/share",
		section = "Session",
		help_left = "/share",
		help_right = "export transcript + copy path (local)",
		desc = "Export transcript and copy path for local share",
		in_menu = true,
	},
	{
		primary = "/session-info",
		aliases = {"/session"},
		section = "Session",
		help_left = "/session-info",
		help_right = "session + context one-liner (/session)",
		desc = "Show session info",
		in_menu = true,
	},
	{
		primary = "/rename",
		aliases = {"/title"},
		section = "Session",
		help_left = "/rename|/title <t>",
		help_right = "set session title",
		desc = "Rename the current session",
		in_menu = true,
	},
	{
		primary = "/dashboard",
		aliases = {"/agents-dashboard"},
		section = "Session",
		help_left = "/dashboard",
		help_right = "sessions + bg tasks overview",
		desc = "Open the Agent Dashboard — overview of running sessions",
		in_menu = true,
	},
	{
		primary = "/cd",
		section = "Session",
		help_left = "/cd [path]",
		help_right = "change workspace directory",
		desc = "Change the working directory for this session",
		in_menu = true,
	},
	{
		primary = "/theme",
		aliases = {"/t"},
		section = "TUI & chrome",
		help_left = "/theme [name|list]",
		help_right = "TUI color theme (cycle if bare)",
		desc = "Switch the color theme",
		in_menu = true,
	},
	{
		primary = "/feedback",
		section = "TUI & chrome",
		help_left = "/feedback <text>",
		help_right = "local session feedback (JSONL; not model)",
		desc = "Save local session feedback (JSONL)",
		in_menu = true,
	},
	{
		primary = "/remember",
		section = "Memory & context",
		help_left = "/remember <note>",
		help_right = "append user note to today's memory log",
		desc = "Save a memory note",
		in_menu = true,
	},
	{
		primary = "/plan",
		section = "Permissions & plan",
		help_left = "/plan [desc|off|status]",
		help_right = "plan mode (Pending→Active; off to leave)",
		desc = "Enter plan mode",
		in_menu = true,
	},
	{
		primary = "/view-plan",
		aliases = {"/show-plan", "/plan-view"},
		section = "Permissions & plan",
		help_left = "/view-plan",
		help_right = "show .grok/plan.md (/show-plan)",
		desc = "View the current plan",
		in_menu = true,
	},
	{
		primary = "/resume",
		aliases = {"/sessions"},
		section = "Session",
		help_left = "/resume",
		help_right = "list/filter/delete sessions (/sessions)",
		desc = "Resume a previous session",
		in_menu = true,
	},
	{
		primary = "/mcps",
		aliases = {"/mcp"},
		section = "Extensions",
		help_left = "/mcps [status|reconnect|auth|set-token]",
		help_right = "MCP servers (/mcp)",
		desc = "MCP server status",
		in_menu = true,
	},
	{
		primary = "/btw",
		section = "TUI & chrome",
		help_left = "/btw <question>",
		help_right = "side agent answer (off-transcript)",
		desc = "Ask a side question without interrupting the session history",
		in_menu = true,
	},
	{
		primary = "/recap",
		section = "Session",
		help_left = "/recap",
		help_right = "model \"where was I\" summary (local fallback)",
		desc = "Summarize the session so far",
		in_menu = true,
	},
	{
		primary = "/terminal-setup",
		aliases = {"/terminal-check", "/terminal-info"},
		section = "TUI & chrome",
		help_left = "/terminal-setup",
		help_right = "term/color/clipboard diagnostics",
		desc = "Check terminal, color, and clipboard setup",
		in_menu = true,
	},
	{
		primary = "/voice",
		section = "TUI & chrome",
		help_left = "/voice",
		help_right = "dictation N/A (no STT stack)",
		desc = "Dictation is not available in Aether",
		in_menu = false,
	},
	{
		primary = "/loop",
		section = "Extensions",
		help_left = "/loop [interval] <prompt>",
		help_right = "schedule recurring prompt (list|stop)",
		desc = "Run a prompt on a recurring interval",
		in_menu = true,
	},
	{
		primary = "/imagine",
		section = "Extensions",
		help_left = "/imagine <desc>",
		help_right = "generate an image (XAI_API_KEY; Imagine API)",
		desc = "Generate an image from a text description",
		in_menu = true,
	},
	{
		primary = "/imagine-video",
		section = "Extensions",
		help_left = "/imagine-video <img> [prompt]",
		help_right = "animate image → video",
		desc = "Generate a video from a text description",
		in_menu = true,
	},
	{
		primary = "/timestamps",
		aliases = {"/timestamp"},
		section = "TUI & chrome",
		help_left = "/timestamps [on|off]",
		help_right = "HH:MM prefixes on transcript blocks",
		desc = "Toggle message timestamps on/off",
		in_menu = true,
	},
	{
		primary = "/toggle-mouse-reporting",
		section = "TUI & chrome",
		help_left = "/toggle-mouse-reporting",
		help_right = "(TUI) toggle SGR mouse capture",
		desc = "Toggle mouse reporting / capture",
		in_menu = true,
	},
	{
		primary = "/settings",
		aliases = {"/config", "/preferences", "/prefs"},
		section = "Discover",
		help_left = "/settings",
		help_right = "effective settings dump (/config)",
		desc = "Show effective settings dump (no modal)",
		in_menu = true,
	},
	{
		primary = "/privacy",
		section = "Model & auth",
		help_left = "/privacy [opt-in|opt-out]",
		help_right = "local coding_data_share preference",
		desc = "Show or toggle local privacy preference",
		in_menu = true,
	},
	{
		primary = "/rewind",
		section = "Session",
		help_left = "/rewind [N|status]",
		help_right = "drop last N user turns (default 1)",
		desc = "Drop last N user turns",
		in_menu = true,
	},
	{
		primary = "/login",
		section = "Model & auth",
		help_left = "/login [--host]",
		help_right = "device-code sign-in (in-process); --host → grok login",
		desc = "Log in or re-authenticate with your account",
		in_menu = true,
	},
	{
		primary = "/logout",
		section = "Model & auth",
		help_left = "/logout",
		help_right = "clear disk auth (or unset API key env)",
		desc = "Log out and clear saved credentials",
		in_menu = true,
	},
	{
		primary = "/import-claude",
		section = "Session",
		help_left = "/import-claude [apply]",
		help_right = "scan/merge Claude mcpServers into config",
		desc = "Import Claude MCP settings (scan or apply)",
		in_menu = true,
	},
	{
		primary = "/queue",
		section = "Session",
		help_left = "/queue",
		help_right = "list mid-turn follow-up queue",
		desc = "List the prompts queued behind the running turn",
		in_menu = true,
	},
	{
		primary = "/tasks",
		section = "Extensions",
		help_left = "/tasks",
		help_right = "bg tasks + scheduler + todos",
		desc = "List background tasks, subagents, and scheduled tasks",
		in_menu = true,
	},
	{
		primary = "/release-notes",
		aliases = {"/changelog"},
		section = "Discover",
		help_left = "/release-notes",
		help_right = "local CHANGELOG (/changelog)",
		desc = "View release notes for the current version",
		in_menu = true,
	},
	{
		primary = "/config-agents",
		aliases = {"/agents"},
		section = "Extensions",
		help_left = "/config-agents",
		help_right = "personas + subagent types (/agents)",
		desc = "Manage agent definitions",
		in_menu = true,
	},
	{
		primary = "/personas",
		aliases = {"/persona"},
		section = "Extensions",
		help_left = "/personas",
		help_right = "list subagent personas for spawn persona= (M9)",
		desc = "List subagent personas",
		in_menu = true,
	},
	// --- Aether-only (after Grok shared set) ---
	{
		primary = "/about",
		section = "Discover",
		help_left = "/about",
		help_right = "product blurb + discover tips",
		desc = "Product blurb and discover tips",
		in_menu = true,
	},
	{
		primary = "/aliases",
		aliases = {"/alias"},
		section = "Discover",
		help_left = "/aliases [filter]",
		help_right = "slash command aliases",
		desc = "List slash command aliases",
		in_menu = false,
	},
	{
		primary = "/keys",
		aliases = {"/bindings", "/shortcuts"},
		section = "Discover",
		help_left = "/keys",
		help_right = "TUI keyboard shortcuts (/bindings)",
		desc = "TUI keyboard shortcuts",
		in_menu = false,
	},
	{
		primary = "/tools",
		aliases = {"/tool"},
		section = "Discover",
		help_left = "/tools [filter]",
		help_right = "list model tools (+ short descriptions)",
		desc = "List model tools",
		in_menu = false,
	},
	{
		primary = "/soft-bash",
		aliases = {"/bash-soft", "/softbash"},
		section = "Discover",
		help_left = "/soft-bash [on|off|check <cmd>]",
		help_right = "soft-bash safety (/bash-soft)",
		desc = "Soft-bash shell safety settings",
		in_menu = false,
	},
	{
		primary = "/permissions",
		aliases = {"/permission", "/perm", "/perms"},
		section = "Discover",
		help_left = "/permissions",
		help_right = "permission mode dashboard (/perm)",
		desc = "Permission mode dashboard",
		in_menu = false,
	},
	{
		primary = "/env",
		aliases = {"/environ", "/environment"},
		section = "Discover",
		help_left = "/env [filter|set]",
		help_right = "product env catalog (AETHER_* kill-switches)",
		desc = "Product environment catalog",
		in_menu = false,
	},
	{
		primary = "/paths",
		aliases = {"/path", "/where"},
		section = "Discover",
		help_left = "/paths [filter]",
		help_right = "product data paths (config/sessions/memory)",
		desc = "Product data paths",
		in_menu = false,
	},
	{
		primary = "/features",
		aliases = {"/feature", "/flags"},
		section = "Discover",
		help_left = "/features [filter]",
		help_right = "process feature flags on/off (/flags)",
		desc = "Process feature flags",
		in_menu = false,
	},
	{
		primary = "/status",
		section = "Discover",
		help_left = "/status",
		help_right = "product status (auth/model/session/tools)",
		desc = "Product status snapshot",
		in_menu = false,
	},
	{
		primary = "/doctor",
		section = "Discover",
		help_left = "/doctor",
		help_right = "health check (auth, deps, paths, soft systems)",
		desc = "Health check (auth, deps, paths)",
		in_menu = false,
	},
	{
		primary = "/version",
		section = "Discover",
		help_left = "/version",
		help_right = "version banner",
		desc = "Version banner",
		in_menu = false,
	},
	{
		primary = "/save",
		section = "Session",
		help_left = "/save [title]",
		help_right = "save now (optional title)",
		desc = "Save the current session",
		in_menu = false,
	},
	{
		primary = "/load",
		section = "Session",
		help_left = "/load <id|title>",
		help_right = "load a saved session",
		desc = "Load a saved session",
		in_menu = false,
	},
	{
		primary = "/import",
		section = "Session",
		help_left = "/import <path.json>",
		help_right = "import session/export JSON as new session",
		desc = "Import session JSON as a new session",
		in_menu = false,
	},
	{
		primary = "/undo-file",
		aliases = {"/rewind-file"},
		section = "Session",
		help_left = "/undo-file [status|clear]",
		help_right = "undo last write/edit/delete",
		desc = "Undo last write/edit/delete",
		in_menu = false,
	},
	{
		primary = "/whoami",
		section = "Model & auth",
		help_left = "/whoami",
		help_right = "show auth identity",
		desc = "Show auth identity",
		in_menu = false,
	},
	{
		primary = "/create-skill",
		aliases = {"/createskill", "/new-skill"},
		section = "Extensions",
		help_left = "/create-skill",
		help_right = "scaffold SKILL.md under user or project skills (M10)",
		desc = "Scaffold a new SKILL.md",
		in_menu = true,
	},
	{
		primary = "/skill",
		section = "Extensions",
		help_left = "/skill <name>",
		help_right = "load skill/command body (user; disabled OK)",
		desc = "Load a skill or command body",
		in_menu = true,
	},
	{
		primary = "/todos",
		aliases = {"/todo"},
		section = "Extensions",
		help_left = "/todos [clear]",
		help_right = "show session task list (or clear)",
		desc = "Show session task list",
		in_menu = true,
	},
	{
		primary = "/goal",
		section = "Extensions",
		help_left = "/goal [obj|status|pause|resume|clear]",
		help_right = "process-local goal mode",
		desc = "Process-local goal mode",
		in_menu = true,
	},
	{
		primary = "/flush",
		section = "Memory & context",
		help_left = "/flush [heuristic]",
		help_right = "persist session notes to memory daily log",
		desc = "Persist session notes to memory",
		in_menu = false,
	},
	{
		primary = "/dream",
		section = "Memory & context",
		help_left = "/dream [status|heuristic]",
		help_right = "consolidate session logs → MEMORY.md",
		desc = "Consolidate session logs into MEMORY.md",
		in_menu = false,
	},
	{
		primary = "/memory",
		section = "Memory & context",
		help_left = "/memory [status|path|on|off|help]",
		help_right = "memory root / process toggle",
		desc = "Memory root and process toggle",
		in_menu = false,
	},
	{
		primary = "/diff",
		section = "Memory & context",
		help_left = "/diff [stat|full]",
		help_right = "git status -sb + diff --stat (read-only)",
		desc = "Git status and diff summary",
		in_menu = false,
	},
}

// slash_help_line formats one catalog row for /help.
slash_help_line :: proc(e: Slash_Entry, allocator := context.allocator) -> string {
	// Align like historical HELP_CATALOG (~20 cols for left field).
	left := e.help_left
	if left == "" {
		left = e.primary
	}
	pad := 20 - len(left)
	if pad < 1 {
		pad = 1
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "  ")
	strings.write_string(&b, left)
	for i := 0; i < pad; i += 1 {
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, e.help_right)
	return strings.to_string(b)
}

// slash_entry_desc: dropdown description (Grok-facing when set).
slash_entry_desc :: proc(e: Slash_Entry) -> string {
	if e.desc != "" {
		return e.desc
	}
	return e.help_right
}

// slash_desc_for looks up description by primary or alias name.
slash_desc_for :: proc(name: string) -> string {
	for e in SLASH_CATALOG {
		if e.primary == name {
			return slash_entry_desc(e)
		}
		for a in e.aliases {
			if a == name {
				return slash_entry_desc(e)
			}
		}
	}
	return ""
}

// slash_collect_matches fills out with completion triggers for prefix.
// Bare "/" → in_menu primaries only. Longer prefix → one row per command
// (primary preferred; alias only if primary does not match).
// Prefer slash_collect_match_rows for UI (includes descriptions).
slash_collect_matches :: proc(prefix: string, out: ^[dynamic]string) {
	rows := make([dynamic]Slash_Match, 0, 32, context.temp_allocator)
	slash_collect_match_rows(prefix, &rows)
	clear(out)
	for r in rows {
		append(out, r.name)
	}
}

// slash_collect_match_rows: suggestion rows (name + description).
// At most one row per catalog entry so aliases never duplicate primaries
// (e.g. typing "/session" shows /session-info once, not /session + /session-info).
slash_collect_match_rows :: proc(prefix: string, out: ^[dynamic]Slash_Match) {
	clear(out)
	if prefix == "" {
		return
	}
	bare := prefix == "/"
	for e in SLASH_CATALOG {
		d := slash_entry_desc(e)
		if bare {
			if e.in_menu && e.primary != "" {
				append(out, Slash_Match{name = e.primary, desc = d})
			}
			continue
		}
		// Prefer primary when it matches the typed prefix.
		if strings.has_prefix(e.primary, prefix) {
			append(out, Slash_Match{name = e.primary, desc = d})
			continue
		}
		// Else first matching alias only (still one row for this command).
		for a in e.aliases {
			if strings.has_prefix(a, prefix) {
				append(out, Slash_Match{name = a, desc = d})
				break
			}
		}
	}
}
