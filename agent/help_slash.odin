// Package agent — /help sectioned command list (B65).
// Optional filter matches section titles or command lines.
package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// Help_Line is either a section header (is_section) or a command row.
Help_Line :: struct {
	is_section: bool,
	text:       string,
}

// Static help catalog (text only; order is display order).
HELP_CATALOG := [?]Help_Line {
	{is_section = true, text = "Discover"},
	{is_section = false, text = "  /help [filter]      this help (optional substring filter)"},
	{is_section = false, text = "  /about              product blurb + discover tips"},
	{is_section = false, text = "  /aliases [filter]   slash command aliases"},
	{is_section = false, text = "  /keys               TUI keyboard shortcuts (/bindings)"},
	{is_section = false, text = "  /tools [filter]     list model tools (+ short descriptions)"},
	{is_section = false, text = "  /soft-bash [on|off|check <cmd>] soft-bash safety (/bash-soft)"},
	{is_section = false, text = "  /permissions        permission mode dashboard (/perm)"},
	{is_section = false, text = "  /env [filter|set]   product env catalog (AETHER_* kill-switches)"},
	{is_section = false, text = "  /paths [filter]     product data paths (config/sessions/memory)"},
	{is_section = false, text = "  /features [filter]  process feature flags on/off (/flags)"},
	{is_section = false, text = "  /status             product status (auth/model/session/tools)"},
	{is_section = false, text = "  /config             effective settings dump (/settings)"},
	{is_section = false, text = "  /doctor             health check (auth, deps, paths, soft systems)"},
	{is_section = false, text = "  /version            version banner"},
	{is_section = true, text = "Session"},
	{is_section = false, text = "  /session            show current session id/path"},
	{is_section = false, text = "  /session-info       session + context usage one-liner"},
	{is_section = false, text = "  /sessions [N|search q|delete id]  list/filter/delete sessions"},
	{is_section = false, text = "  /resume             list sessions (use /load <id>)"},
	{is_section = false, text = "  /save [title]       save now (optional title)"},
	{is_section = false, text = "  /load <id|title>    load a saved session"},
	{is_section = false, text = "  /rename|/title <t>  set session title"},
	{is_section = false, text = "  /fork [title]       branch conversation into a new session"},
	{is_section = false, text = "  /export [json|md] [path]  transcript (md default; json dump)"},
	{is_section = false, text = "  /import <path.json> import session/export JSON as new session"},
	{is_section = false, text = "  /rewind [N|status]  drop last N user turns (default 1)"},
	{is_section = false, text = "  /undo-file [status|clear]  undo last write/edit/delete"},
	{is_section = false, text = "  /copy [N]           copy Nth-latest assistant (TUI: selected)"},
	{is_section = false, text = "  /history [n|text]   list/filter/show session user prompts"},
	{is_section = false, text = "  /new                start a fresh session"},
	{is_section = false, text = "  /clear              clear history (keep session id)"},
	{is_section = true, text = "Model & auth"},
	{is_section = false, text = "  /model [id]         show or set model (/m)"},
	{is_section = false, text = "  /effort [level]     reasoning effort: low|medium|high|xhigh|off"},
	{is_section = false, text = "  /whoami             show auth identity"},
	{is_section = false, text = "  /login [--host]     device-code sign-in (in-process); --host → grok login"},
	{is_section = true, text = "Permissions & plan"},
	{is_section = false, text = "  /always-approve [on|off|status]  permission mode (/yolo)"},
	{is_section = false, text = "  /auto [on|off]      auto-approve file edits; ask for shell"},
	{is_section = false, text = "  /plan [desc|off|status]  plan mode (Pending→Active; off to leave)"},
	{is_section = false, text = "  /view-plan          show .grok/plan.md (/show-plan)"},
	{is_section = true, text = "Extensions"},
	{is_section = false, text = "  /mcp [status|reconnect|auth|set-token]  MCP servers"},
	{is_section = false, text = "  /hooks [status|list|paths|add|remove|reload]  local hooks"},
	{is_section = false, text = "  /skills [reload]    list skills + commands (reload rediscovers)"},
	{is_section = false, text = "  /create-skill       scaffold SKILL.md under user or project skills (M10)"},
	{is_section = false, text = "  /plugins            list/add/remove/reload local plugins (M4)"},
	{is_section = false, text = "  /personas           list subagent personas for spawn persona= (M9)"},
	{is_section = false, text = "  /skill <name>       load skill/command body (user; disabled OK)"},
	{is_section = false, text = "  /todos [clear]      show session task list (or clear)"},
	{is_section = false, text = "  /goal [obj|status|pause|resume|clear]  process-local goal mode"},
	{is_section = false, text = "  /loop [interval] <prompt>  schedule recurring prompt (list|stop)"},
	{is_section = false, text = "  /imagine <desc>     generate an image (XAI_API_KEY; Imagine API)"},
	{is_section = false, text = "  /imagine-video <img> [prompt]  animate image → video"},
	{is_section = true, text = "Memory & context"},
	{is_section = false, text = "  /flush [heuristic]  persist session notes to memory daily log"},
	{is_section = false, text = "  /remember <note>    append user note to today's memory log"},
	{is_section = false, text = "  /dream [status|heuristic]  consolidate session logs → MEMORY.md"},
	{is_section = false, text = "  /memory [status|path|on|off|help]  memory root / process toggle"},
	{is_section = false, text = "  /context|/usage     estimated context window usage"},
	{is_section = false, text = "  /compact [notes]    compress history (heuristic|status|focus)"},
	{is_section = false, text = "  /diff [stat|full]   git status -sb + diff --stat (read-only)"},
	{is_section = true, text = "TUI & chrome"},
	{is_section = false, text = "  /theme [name|list]  TUI color theme (cycle if bare)"},
	{is_section = false, text = "  /vim-mode [on|off]  scrollback j/k/g/G/i (TUI)"},
	{is_section = false, text = "  /compact-mode [on|off] denser TUI chrome (/cm)"},
	{is_section = false, text = "  /timestamps [on|off]  HH:MM prefixes on transcript blocks"},
	{is_section = false, text = "  /find [text]        (TUI) search scrollback"},
	{is_section = false, text = "  /multiline|/ml      (TUI) toggle multiline compose"},
	{is_section = false, text = "  /btw <text>         local note (not sent to the model)"},
	{is_section = false, text = "  /feedback <text>    local session feedback (JSONL; not model)"},
	{is_section = true, text = "Exit"},
	{is_section = false, text = "  /exit               quit (/quit, /q)"},
}

// handle_help_slash builds sectioned help; filter keeps matching sections/rows.
handle_help_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /help [filter]\n" +
			"List slash commands by section. Optional filter matches section titles or command text.\n" +
			"Examples: /help session · /help plan · /help mem",
			allocator,
		)
	}

	cat := HELP_CATALOG[:]
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether commands\n")
	if a == "" {
		strings.write_string(&b, fmt.tprintf("%s\n\n", core.version_string()))
	} else {
		strings.write_string(
			&b,
			fmt.tprintf("%s  (filter: %s)\n\n", core.version_string(), arg),
		)
	}

	// Filter: section title match → all cmds in section; else only matching cmd rows.
	n_cmds := 0
	i := 0
	for i < len(cat) {
		if !cat[i].is_section {
			i += 1
			continue
		}
		sec_title := cat[i].text
		sec_match :=
			a == "" ||
			strings.contains(strings.to_lower(sec_title, context.temp_allocator), a)
		j := i + 1
		matched_cmds: [dynamic]string
		// note: defer in loop is OK in Odin (runs at end of iteration scope... actually
		// Odin defer is procedure-scoped. Use clear/delete carefully.
		for j < len(cat) && !cat[j].is_section {
			cmd := cat[j].text
			include := a == "" || sec_match
			if !include {
				include = strings.contains(strings.to_lower(cmd, context.temp_allocator), a)
			}
			if include {
				append(&matched_cmds, cmd)
			}
			j += 1
		}
		if len(matched_cmds) > 0 {
			strings.write_string(&b, fmt.tprintf("### %s\n", sec_title))
			for c in matched_cmds {
				strings.write_string(&b, c)
				strings.write_string(&b, "\n")
				n_cmds += 1
			}
			strings.write_string(&b, "\n")
		}
		delete(matched_cmds)
		i = j
	}

	if n_cmds == 0 {
		strings.write_string(&b, fmt.tprintf("(no commands matching %q)\n", arg))
	} else {
		strings.write_string(
			&b,
			"Anything else is sent to the agent with tools.\n" +
			"tips: /about · /aliases · /keys · /tools · /permissions · /env · /paths\n",
		)
	}
	return strings.to_string(b)
}
