// Package agent — /env product environment catalog (B62).
// Lists known AETHER_*/product env knobs with set status; secrets redacted.
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:core"

// Env_Row: known product env var + short description.
Env_Row :: struct {
	key:  string,
	desc: string,
	secret: bool,
}

// Product-relevant env vars (kill-switches, paths, auth). Not exhaustive OS env.
ENV_CATALOG := []Env_Row {
	{"XAI_API_KEY", "API key auth (value never shown)", true},
	{"GROK_HOME", "user data root (default ~/.grok)", false},
	{"AETHER_CONFIG", "override path to aether.toml / project config", false},
	{"AETHER_MEMORY_DIR", "override memory root directory", false},
	{"AETHER_SESSIONS_DIR", "override sessions directory", false},
	{"AETHER_NO_BASH_SOFT", "disable soft-bash hard-deny + inspect auto-allow", false},
	{"AETHER_NO_MEMORY", "disable memory subsystem", false},
	{"AETHER_NO_MEMORY_INJECT", "disable initial memory injection", false},
	{"AETHER_NO_AUTO_DREAM", "disable automatic dream consolidation", false},
	{"AETHER_NO_PLAN_MODE", "disable plan mode tools/gates", false},
	{"AETHER_NO_SUBAGENTS", "disable subagent spawn", false},
	{"AETHER_NO_AUTO_COMPACT", "disable auto-compact on context pressure", false},
	{"AETHER_AUTO_COMPACT_PCT", "auto-compact threshold percent override", false},
	{"AETHER_NO_UI_PERSIST", "do not write UI prefs to config.toml", false},
	{"AETHER_NO_HOOKS", "disable hooks", false},
	{"AETHER_NO_FOLDER_TRUST", "disable folder trust (always load project hooks)", false},
	{"AETHER_NO_MCP", "disable MCP", false},
	{"AETHER_NO_SKILLS", "disable skills discovery", false},
	{"AETHER_NO_DESKTOP_NOTIFY", "disable desktop notifications", false},
	{"AETHER_NO_TURN_NOTIFY", "disable end-of-turn desktop notify", false},
	{"AETHER_NO_PROMPT_HISTORY", "disable durable prompt history", false},
	{"AETHER_NO_STREAM", "disable streaming responses", false},
	{"AETHER_NO_MULTIMODAL", "disable image paste / vision expand", false},
	{"AETHER_NO_MONITOR", "disable monitor/watch helpers", false},
	{"AETHER_NO_PROJECT_RULES", "skip project rules injection", false},
	{"AETHER_NO_FILE_REWIND", "disable /undo-file stack", false},
	{"AETHER_NO_LSP", "disable LSP diagnostics tools", false},
	{"AETHER_NO_WEB_SEARCH", "disable web_search tool", false},
	{"AETHER_NO_COLOR", "disable ANSI color (also NO_COLOR)", false},
	{"NO_COLOR", "standard no-color signal", false},
	{"AETHER_NO_CLAUDE_SKILLS", "skip Claude-format skill roots", false},
	{"AETHER_NO_CURSOR_SKILLS", "skip Cursor-format skill roots", false},
}

// handle_env_slash: catalog of product env vars; optional filter; secrets redacted.
handle_env_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /env [filter|set|help]\n" +
			"List known AETHER_*/product environment knobs and whether they are set.\n" +
			"  set     only show variables that are currently set\n" +
			"  filter  substring match on name or description\n" +
			"Secrets (e.g. XAI_API_KEY) show as set without values.\n" +
			"See also: /config · /paths · /doctor · /soft-bash.",
			allocator,
		)
	}
	only_set := a == "set" || a == "active" || a == "on"
	filter := a
	if only_set {
		filter = ""
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether env\n")
	strings.write_string(
		&b,
		fmt.tprintf("%s\n\n", core.version_string()),
	)
	strings.write_string(&b, "  set  name                         description\n")
	strings.write_string(&b, "  ---  ----------------------------  --------------------------------\n")

	n := 0
	n_set := 0
	for row in ENV_CATALOG {
		kl := strings.to_lower(row.key, context.temp_allocator)
		dl := strings.to_lower(row.desc, context.temp_allocator)
		if filter != "" && !strings.contains(kl, filter) && !strings.contains(dl, filter) {
			continue
		}
		v := os.get_env(row.key, context.temp_allocator)
		is_set := v != ""
		if only_set && !is_set {
			continue
		}
		n += 1
		mark := "·"
		if is_set {
			mark = "Y"
			n_set += 1
		}
		// value column only for non-secrets when set (truncated)
		extra := ""
		if is_set {
			if row.secret {
				extra = "  =***"
			} else {
				show := v
				if len(show) > 40 {
					show = fmt.tprintf("%s…", show[:40])
				}
				// single-line safety
				if strings.contains(show, "\n") {
					show = "(multiline)"
				}
				extra = fmt.tprintf("  =%s", show)
			}
		}
		strings.write_string(
			&b,
			fmt.tprintf("  %s    %-28s  %s%s\n", mark, row.key, row.desc, extra),
		)
	}
	if n == 0 {
		if only_set {
			strings.write_string(&b, "(none of the catalogued product env vars are set)\n")
		} else {
			strings.write_string(&b, fmt.tprintf("(no rows matching %q)\n", arg))
		}
	} else {
		strings.write_string(
			&b,
			fmt.tprintf("\n%d row(s), %d set.  Y=set ·=unset.  tips: /config · /doctor · /soft-bash · /help\n", n, n_set),
		)
	}
	return strings.to_string(b)
}
