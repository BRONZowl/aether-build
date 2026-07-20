// Package agent — /settings effective settings dump (B34; aliases /config /preferences /prefs).
// Read-only view of process-effective product knobs; no secrets.
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:core"
import "aether:tools"

// handle_config_slash: effective config dashboard (not a full settings modal).
// Live model/perm from session; UI/flags from process globals; paths from core helpers.
handle_config_slash :: proc(
	sess: ^Session,
	model: string,
	perm: core.Permission_Mode,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether config (effective)\n")
	strings.write_string(
		&b,
		"(read-only dump; change via /model /effort /theme /vim-mode /compact-mode /always-approve /auto /memory, Shift+Tab, or ~/.grok/config.toml)\n\n",
	)

	// --- Model & permissions ---
	m := model
	if sess != nil && sess.model != "" {
		m = sess.model
	}
	if m == "" {
		m = core.DEFAULT_MODEL
	}
	strings.write_string(&b, fmt.tprintf("model:           %s\n", m))
	eff := reasoning_effort_current()
	strings.write_string(
		&b,
		fmt.tprintf("effort:          %s\n", eff if eff != "" else "(default/off)"),
	)
	strings.write_string(
		&b,
		fmt.tprintf("permission:      %s\n", core.permission_mode_string(perm)),
	)

	// --- UI ---
	theme := core.get_ui_theme_name()
	if theme == "" {
		theme = "dark"
	}
	strings.write_string(&b, fmt.tprintf("theme:           %s\n", theme))
	strings.write_string(
		&b,
		fmt.tprintf("vim_mode:        %v\n", core.vim_mode_enabled()),
	)
	strings.write_string(
		&b,
		fmt.tprintf("compact_mode:    %v\n", core.compact_mode_enabled()),
	)
	strings.write_string(
		&b,
		fmt.tprintf("timestamps:      %v\n", core.timestamps_enabled()),
	)

	// --- Agent product flags (config load + process) ---
	strings.write_string(
		&b,
		fmt.tprintf("auto_compact:    %v  (threshold %d%%)\n", core.flag_auto_compact(), core.flag_auto_compact_pct()),
	)
	strings.write_string(
		&b,
		fmt.tprintf("subagents:       %v\n", core.flag_subagents()),
	)
	// Memory: process-effective (env / toggle) vs config flag
	mem_eff := tools.memory_enabled()
	mem_cfg := core.flag_memory()
	strings.write_string(
		&b,
		fmt.tprintf(
			"memory:          %s  (config flag %v; inject %v; auto-dream %v)\n",
			"on" if mem_eff else "off",
			mem_cfg,
			core.flag_memory_inject(),
			core.flag_auto_dream(),
		),
	)
	strings.write_string(
		&b,
		fmt.tprintf(
			"bash_soft:       %s%s\n",
			"on" if core.bash_soft_enabled() else "off",
			" (process)" if core.bash_soft_process_override_active() else "",
		),
	)
	strings.write_string(
		&b,
		fmt.tprintf(
			"plan_mode:       %s\n",
			plan_state_to_string(plan_mode_state()),
		),
	)

	// --- Session / cwd ---
	if sess != nil {
		strings.write_string(
			&b,
			fmt.tprintf("cwd:             %s\n", sess.cwd if sess.cwd != "" else "."),
		)
		strings.write_string(
			&b,
			fmt.tprintf("session_id:      %s\n", sess.id if sess.id != "" else "(none)"),
		)
		strings.write_string(&b, fmt.tprintf("autosave:        %v\n", sess.auto_save))
	} else {
		strings.write_string(&b, "cwd:             (no session)\n")
	}

	// --- Paths (no secrets) ---
	gh := core.grok_home(context.temp_allocator)
	ucfg := core.user_config_toml_path(context.temp_allocator)
	sdir := core.aether_sessions_dir("", context.temp_allocator)
	mroot := tools.memory_root(context.temp_allocator)
	strings.write_string(&b, "\n## paths\n")
	strings.write_string(&b, fmt.tprintf("GROK_HOME:       %s\n", gh))
	strings.write_string(&b, fmt.tprintf("user config:     %s\n", ucfg))
	strings.write_string(&b, fmt.tprintf("sessions:        %s\n", sdir))
	strings.write_string(&b, fmt.tprintf("memory root:     %s\n", mroot))

	// Project aether.toml if present under cwd
	if sess != nil && sess.cwd != "" {
		proj := fmt.tprintf("%s/aether.toml", sess.cwd)
		if os.exists(proj) {
			strings.write_string(&b, fmt.tprintf("project config:  %s\n", proj))
		} else {
			strings.write_string(&b, "project config:  (no aether.toml in cwd)\n")
		}
	}

	// --- Env kill-switches that are set ---
	strings.write_string(&b, "\n## env overrides (set)\n")
	env_keys := []string {
		"AETHER_NO_MEMORY",
		"AETHER_NO_MEMORY_INJECT",
		"AETHER_NO_AUTO_DREAM",
		"AETHER_NO_BASH_SOFT",
		"AETHER_NO_PLAN_MODE",
		"AETHER_NO_SUBAGENTS",
		"AETHER_NO_AUTO_COMPACT",
		"AETHER_NO_UI_PERSIST",
		"AETHER_NO_HOOKS",
		"AETHER_NO_MCP",
		"AETHER_NO_SKILLS",
		"AETHER_NO_DESKTOP_NOTIFY",
		"AETHER_NO_TURN_NOTIFY",
		"AETHER_NO_PROMPT_HISTORY",
		"AETHER_NO_STREAM",
		"AETHER_NO_MULTIMODAL",
		"AETHER_NO_MONITOR",
		"AETHER_NO_PROJECT_RULES",
		"AETHER_CONFIG",
		"AETHER_MEMORY_DIR",
		"AETHER_SESSIONS_DIR",
		"GROK_HOME",
		"XAI_API_KEY",
	}
	any_env := false
	for k in env_keys {
		v := os.get_env(k, context.temp_allocator)
		if v == "" {
			continue
		}
		any_env = true
		// never print secret values
		if k == "XAI_API_KEY" {
			strings.write_string(&b, fmt.tprintf("%s=***set***\n", k))
			continue
		}
		// truncate long values
		show := v
		if len(show) > 80 {
			show = fmt.tprintf("%s…", show[:80])
		}
		strings.write_string(&b, fmt.tprintf("%s=%s\n", k, show))
	}
	if !any_env {
		strings.write_string(&b, "(none of the common AETHER_*/GROK_HOME overrides are set)\n")
	}

	strings.write_string(
		&b,
		"\ntips: /about · /env · /paths · /features · /status · /doctor · /soft-bash · /tools · /help\n",
	)
	return strings.to_string(b)
}
