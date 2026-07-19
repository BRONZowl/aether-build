// Package agent — /features process feature flags dashboard (B68).
// Read-only view of product gates (env + config + process toggles).
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:core"
import "aether:hooks"
import "aether:skills"
import "aether:tools"

// env_kill_set: true when AETHER_NO_* style env is truthy (1/true/yes/on).
env_kill_set :: proc(key: string) -> bool {
	v := os.get_env(key, context.temp_allocator)
	if v == "" {
		return false
	}
	return v == "1" ||
		v == "true" ||
		v == "yes" ||
		v == "on" ||
		strings.equal_fold(v, "true")
}

// features_write_row appends one feature line if filter matches.
features_write_row :: proc(
	b: ^strings.Builder,
	filter: string,
	n, n_on: ^int,
	name: string,
	on: bool,
	note: string,
) {
	if filter != "" {
		nl := strings.to_lower(name, context.temp_allocator)
		tl := strings.to_lower(note, context.temp_allocator)
		if !strings.contains(nl, filter) && !strings.contains(tl, filter) {
			return
		}
	}
	n^ += 1
	if on {
		n_on^ += 1
	}
	mark := "·"
	if on {
		mark = "Y"
	}
	strings.write_string(b, fmt.tprintf("  %s   %-20s  %s\n", mark, name, note))
}

// handle_features_slash: on/off table for major product features.
handle_features_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /features [filter|help]\n" +
			"Show process-effective product feature flags (on/off) and how they are gated.\n" +
			"Does not toggle features — use the listed slash/env controls.\n" +
			"See also: /config · /env · /permissions · /soft-bash · /doctor.",
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether features\n")
	strings.write_string(&b, fmt.tprintf("%s\n\n", core.version_string()))
	strings.write_string(&b, "  on  feature              gate / notes\n")
	strings.write_string(&b, "  --  -------------------  --------------------------------\n")

	n := 0
	n_on := 0
	f := a

	soft_note := "AETHER_NO_BASH_SOFT · /soft-bash on|off"
	if core.bash_soft_process_override_active() {
		soft_note = "process override · /soft-bash · AETHER_NO_BASH_SOFT wins"
	}
	features_write_row(&b, f, &n, &n_on, "bash-soft", core.bash_soft_enabled(), soft_note)

	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"plan-mode",
		plan_mode_enabled(),
		fmt.tprintf("%s · AETHER_NO_PLAN_MODE · /plan", plan_state_to_string(plan_mode_state())),
	)

	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"memory",
		tools.memory_enabled(),
		"AETHER_NO_MEMORY · /memory on|off · [memory] enabled",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"memory-inject",
		memory_inject_enabled(),
		"AETHER_NO_MEMORY_INJECT · [memory.initial_injection]",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"auto-dream",
		auto_dream_enabled(),
		"AETHER_NO_AUTO_DREAM · [memory] auto_dream · /dream",
	)

	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"subagents",
		core.flag_subagents(),
		"AETHER_NO_SUBAGENTS · [subagents] enabled",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"auto-compact",
		auto_compact_enabled(),
		fmt.tprintf(
			"AETHER_NO_AUTO_COMPACT · threshold %d%% · /compact",
			core.flag_auto_compact_pct(),
		),
	)

	features_write_row(&b, f, &n, &n_on, "hooks", hooks.hooks_enabled(), "AETHER_NO_HOOKS · /hooks")
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"skills",
		!env_kill_set("AETHER_NO_SKILLS"),
		"AETHER_NO_SKILLS · /skills",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"mcp",
		!env_kill_set("AETHER_NO_MCP"),
		"AETHER_NO_MCP · /mcp",
	)

	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"desktop-notify",
		desktop_notify_enabled(),
		"AETHER_NO_DESKTOP_NOTIFY",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"turn-notify",
		turn_notify_enabled(),
		"AETHER_NO_TURN_NOTIFY",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"prompt-history",
		core.prompt_history_enabled(),
		"AETHER_NO_PROMPT_HISTORY",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"ui-persist",
		core.ui_persist_enabled(),
		"AETHER_NO_UI_PERSIST · theme/vim/perm → config.toml",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"project-rules",
		project_rules_enabled(),
		"AETHER_NO_PROJECT_RULES",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"multimodal",
		!multimodal_disabled(),
		"AETHER_NO_MULTIMODAL · image paste / vision",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"folder-trust",
		core.folder_trust_enabled(),
		"AETHER_NO_FOLDER_TRUST · gate project hooks until /hooks trust",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"plugins",
		plugins_enabled(),
		"AETHER_NO_PLUGINS · /plugins local packages",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"personas",
		personas_enabled(),
		"AETHER_NO_PERSONAS · spawn_subagent persona=",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"tool-pack-hashline",
		tools.tool_pack_from_env() == .Hashline,
		"AETHER_TOOL_PACK=hashline · hashline_read/edit/grep",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"os-sandbox",
		core.effective_sandbox_mode() != .Off,
		"AETHER_OS_SANDBOX=soft|bwrap · workspace shell isolation",
	)
	// M8: mermaid Unicode layout (logic mirrored from tui.mermaid_render_enabled)
	mermaid_on := !env_kill_set("AETHER_NO_MERMAID")
	if mermaid_on {
		mv := strings.to_lower(
			strings.trim_space(os.get_env("AETHER_RENDER_MERMAID", context.temp_allocator)),
			context.temp_allocator,
		)
		switch mv {
		case "0", "off", "false", "no", "source", "raw":
			mermaid_on = false
		}
	}
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"mermaid-layout",
		mermaid_on,
		"AETHER_RENDER_MERMAID · AETHER_NO_MERMAID · Unicode flowchart/sequence art",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"web-fetch",
		web_fetch_enabled(),
		"AETHER_NO_WEB_FETCH",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"web-search",
		!env_kill_set("AETHER_NO_WEB_SEARCH"),
		"AETHER_NO_WEB_SEARCH",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"file-rewind",
		!env_kill_set("AETHER_NO_FILE_REWIND"),
		"AETHER_NO_FILE_REWIND · /undo-file",
	)

	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"vim-mode",
		core.vim_mode_enabled(),
		"/vim-mode · [ui] vim_mode",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"compact-mode",
		core.compact_mode_enabled(),
		"/compact-mode · [ui] compact_mode",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"timestamps",
		core.timestamps_enabled(),
		"/timestamps · [ui] timestamps",
	)

	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"claude-skills",
		skills.claude_skills_enabled(),
		"AETHER_NO_CLAUDE_SKILLS",
	)
	features_write_row(
		&b,
		f,
		&n,
		&n_on,
		"cursor-skills",
		skills.cursor_skills_enabled(),
		"AETHER_NO_CURSOR_SKILLS",
	)

	if n == 0 {
		strings.write_string(&b, fmt.tprintf("(no features matching %q)\n", arg))
	} else {
		strings.write_string(
			&b,
			fmt.tprintf(
				"\n%d feature(s), %d on.  tips: /env · /config · /permissions · /soft-bash · /doctor · /help\n",
				n,
				n_on,
			),
		)
	}
	return strings.to_string(b)
}
