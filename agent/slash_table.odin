// Package agent — table-driven slash dispatch for emit-only commands (P3).
// Session lifecycle and permission toggles stay in run_slash's switch.
// Uses a static route table (no heap map) so tests with tracking allocators
// cannot invalidate keys between cases.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"
import "aether:tools"

// Slash_Ctx is the shared context for table-registered slash handlers.
Slash_Ctx :: struct {
	sess:  ^Session,
	arg:   string,
	opts:  Headless_Options,
	model: ^string,
	cwd:   ^string,
	perm:  ^core.Permission_Mode,
	out:   Slash_Writer,
}

Slash_Handler :: #type proc(ctx: Slash_Ctx) -> Slash_Action

Slash_Route :: struct {
	names:  []string,
	handle: Slash_Handler,
}

// Package-level name arrays (static string data; safe as map-free keys).
SLASH_N_DOCS := [?]string{"/docs", "/howto", "/guides"}
SLASH_N_ALIASES := [?]string{"/aliases", "/alias"}
SLASH_N_ABOUT := [?]string{"/about"}
SLASH_N_KEYS := [?]string{"/keys", "/bindings", "/shortcuts"}
SLASH_N_ENV := [?]string{"/env", "/environ", "/environment"}
SLASH_N_FEATURES := [?]string{"/features", "/feature", "/flags"}
SLASH_N_TOOLS := [?]string{"/tools", "/tool"}
SLASH_N_PATHS := [?]string{"/paths", "/path", "/where"}
SLASH_N_VERSION := [?]string{"/version"}
SLASH_N_LOGOUT := [?]string{"/logout"}
SLASH_N_PRIVACY := [?]string{"/privacy"}
SLASH_N_TERMINAL := [?]string{"/terminal-setup", "/terminal-check", "/terminal-info"}
SLASH_N_TASKS := [?]string{"/tasks"}
SLASH_N_QUEUE := [?]string{"/queue"}
SLASH_N_VOICE := [?]string{"/voice"}
SLASH_N_EXPAND := [?]string{"/expand"}
SLASH_N_RELEASE := [?]string{"/release-notes", "/changelog"}
SLASH_N_MARKET := [?]string{"/marketplace"}
SLASH_N_AGENTS := [?]string{"/config-agents", "/agents"}
SLASH_N_VIEW_PLAN := [?]string{"/view-plan", "/show-plan", "/plan-view"}
SLASH_N_GOAL := [?]string{"/goal"}
SLASH_N_IMAGINE := [?]string{"/imagine"}
SLASH_N_IMAGINE_VIDEO := [?]string{"/imagine-video"}
SLASH_N_LOOP := [?]string{"/loop"}
SLASH_N_SOFT_BASH := [?]string{"/soft-bash", "/bash-soft", "/softbash"}
SLASH_N_PERMS := [?]string{"/permissions", "/permission", "/perm", "/perms"}
SLASH_N_FIND := [?]string{"/find"}
SLASH_N_MULTILINE := [?]string{"/multiline", "/ml"}
SLASH_N_MOUSE := [?]string{"/toggle-mouse-reporting"}
SLASH_N_BTW := [?]string{"/btw"}
SLASH_N_FEEDBACK := [?]string{"/feedback"}
SLASH_N_CONTEXT := [?]string{"/context"}
SLASH_N_USAGE := [?]string{"/usage", "/cost"}
SLASH_N_DIFF := [?]string{"/diff"}
SLASH_N_TRANSCRIPT := [?]string{"/transcript", "/log"}
SLASH_N_RECAP := [?]string{"/recap"}
SLASH_N_SHARE := [?]string{"/share"}
SLASH_N_IMPORT_CLAUDE := [?]string{"/import-claude"}
SLASH_N_DASHBOARD := [?]string{"/dashboard", "/agents-dashboard"}
SLASH_N_MCP := [?]string{"/mcp", "/mcps"}
SLASH_N_HOOKS := [?]string{"/hooks"}
SLASH_N_CREATE_SKILL := [?]string{"/create-skill", "/createskill", "/new-skill"}
SLASH_N_PLUGINS := [?]string{"/plugins", "/plugin"}
SLASH_N_STATUS := [?]string{"/status"}
SLASH_N_SETTINGS := [?]string{"/settings", "/config", "/preferences", "/prefs"}
SLASH_N_DOCTOR := [?]string{"/doctor"}
SLASH_N_HELP := [?]string{"/help", "/?"}
SLASH_N_FLUSH := [?]string{"/flush"}
SLASH_N_MEMORY := [?]string{"/memory"}
SLASH_N_DREAM := [?]string{"/dream"}
SLASH_N_REMEMBER := [?]string{"/remember"}
SLASH_N_VIM := [?]string{"/vim-mode", "/vim"}
SLASH_N_TIMESTAMPS := [?]string{"/timestamps", "/timestamp"}
SLASH_N_COMPACT_MODE := [?]string{"/compact-mode", "/cm"}
SLASH_N_TODOS := [?]string{"/todos", "/todo"}
SLASH_N_EFFORT := [?]string{"/effort"}
SLASH_N_WHOAMI := [?]string{"/whoami"}
SLASH_N_PERSONAS := [?]string{"/personas", "/persona"}
SLASH_N_COMPACT := [?]string{"/compact"}

// SLASH_ROUTES: emit-only commands (primary + aliases).
// Session lifecycle (/quit, /new, /resume, /model, …) stays in run_slash switch.
SLASH_ROUTES := [?]Slash_Route {
	{SLASH_N_HELP[:], slash_h_help},
	{SLASH_N_DOCS[:], slash_h_docs},
	{SLASH_N_ALIASES[:], slash_h_aliases},
	{SLASH_N_ABOUT[:], slash_h_about},
	{SLASH_N_KEYS[:], slash_h_keys},
	{SLASH_N_ENV[:], slash_h_env},
	{SLASH_N_FEATURES[:], slash_h_features},
	{SLASH_N_TOOLS[:], slash_h_tools},
	{SLASH_N_PATHS[:], slash_h_paths},
	{SLASH_N_VERSION[:], slash_h_version},
	{SLASH_N_LOGOUT[:], slash_h_logout},
	{SLASH_N_PRIVACY[:], slash_h_privacy},
	{SLASH_N_TERMINAL[:], slash_h_terminal},
	{SLASH_N_TASKS[:], slash_h_tasks},
	{SLASH_N_QUEUE[:], slash_h_queue},
	{SLASH_N_VOICE[:], slash_h_voice},
	{SLASH_N_EXPAND[:], slash_h_expand},
	{SLASH_N_RELEASE[:], slash_h_release_notes},
	{SLASH_N_MARKET[:], slash_h_marketplace},
	{SLASH_N_AGENTS[:], slash_h_config_agents},
	{SLASH_N_VIEW_PLAN[:], slash_h_view_plan},
	{SLASH_N_GOAL[:], slash_h_goal},
	{SLASH_N_IMAGINE[:], slash_h_imagine},
	{SLASH_N_IMAGINE_VIDEO[:], slash_h_imagine_video},
	{SLASH_N_LOOP[:], slash_h_loop},
	{SLASH_N_SOFT_BASH[:], slash_h_soft_bash},
	{SLASH_N_PERMS[:], slash_h_permissions},
	{SLASH_N_FIND[:], slash_h_find},
	{SLASH_N_MULTILINE[:], slash_h_multiline},
	{SLASH_N_MOUSE[:], slash_h_toggle_mouse},
	{SLASH_N_BTW[:], slash_h_btw},
	{SLASH_N_FEEDBACK[:], slash_h_feedback},
	{SLASH_N_CONTEXT[:], slash_h_context},
	{SLASH_N_USAGE[:], slash_h_usage},
	{SLASH_N_DIFF[:], slash_h_diff},
	{SLASH_N_TRANSCRIPT[:], slash_h_transcript},
	{SLASH_N_RECAP[:], slash_h_recap},
	{SLASH_N_SHARE[:], slash_h_share},
	{SLASH_N_IMPORT_CLAUDE[:], slash_h_import_claude},
	{SLASH_N_DASHBOARD[:], slash_h_dashboard},
	{SLASH_N_MCP[:], slash_h_mcp},
	{SLASH_N_HOOKS[:], slash_h_hooks},
	{SLASH_N_CREATE_SKILL[:], slash_h_create_skill},
	{SLASH_N_PLUGINS[:], slash_h_plugins},
	{SLASH_N_STATUS[:], slash_h_status},
	{SLASH_N_SETTINGS[:], slash_h_settings},
	{SLASH_N_DOCTOR[:], slash_h_doctor},
	{SLASH_N_FLUSH[:], slash_h_flush},
	{SLASH_N_MEMORY[:], slash_h_memory},
	{SLASH_N_DREAM[:], slash_h_dream},
	{SLASH_N_REMEMBER[:], slash_h_remember},
	{SLASH_N_VIM[:], slash_h_vim_mode},
	{SLASH_N_TIMESTAMPS[:], slash_h_timestamps},
	{SLASH_N_COMPACT_MODE[:], slash_h_compact_mode},
	{SLASH_N_TODOS[:], slash_h_todos},
	{SLASH_N_EFFORT[:], slash_h_effort},
	{SLASH_N_WHOAMI[:], slash_h_whoami},
	{SLASH_N_PERSONAS[:], slash_h_personas},
	{SLASH_N_COMPACT[:], slash_h_compact},
}

// slash_table_has reports whether cmd is table-dispatched.
slash_table_has :: proc(cmd: string) -> bool {
	for route in SLASH_ROUTES {
		for n in route.names {
			if n == cmd {
				return true
			}
		}
	}
	return false
}

// slash_table_dispatch looks up cmd; returns ok=false if unregistered.
slash_table_dispatch :: proc(cmd: string, ctx: Slash_Ctx) -> (Slash_Action, bool) {
	for route in SLASH_ROUTES {
		for n in route.names {
			if n == cmd {
				return route.handle(ctx), true
			}
		}
	}
	return .Continue, false
}

// --- helpers ---

slash_ctx_cwd :: proc(ctx: Slash_Ctx) -> string {
	if ctx.sess != nil && ctx.sess.cwd != "" {
		return ctx.sess.cwd
	}
	if ctx.cwd != nil {
		return ctx.cwd^
	}
	return "."
}

// --- handlers ---

slash_h_docs :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_docs_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_aliases :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_aliases_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_about :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_about_slash(context.temp_allocator))
	return .Continue
}

slash_h_keys :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_keys_slash(context.temp_allocator))
	return .Continue
}

slash_h_env :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_env_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_features :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_features_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_tools :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_tools_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_paths :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_paths_slash(ctx.arg, ctx.sess, context.temp_allocator))
	return .Continue
}

slash_h_version :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_version_slash(context.temp_allocator))
	return .Continue
}

slash_h_logout :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_logout_slash(context.temp_allocator))
	return .Continue
}

slash_h_privacy :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_privacy_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_terminal :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_terminal_setup_slash(context.temp_allocator))
	return .Continue
}

slash_h_tasks :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_tasks_slash(context.temp_allocator))
	return .Continue
}

slash_h_queue :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_queue_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_voice :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_voice_slash(context.temp_allocator))
	return .Continue
}

slash_h_expand :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_expand_slash(context.temp_allocator))
	return .Continue
}

slash_h_release_notes :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_release_notes_slash(slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_marketplace :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_marketplace_slash(slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_config_agents :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_config_agents_slash(slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_view_plan :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_view_plan_slash(slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_goal :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_line(ctx.out, handle_goal_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_imagine :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_imagine_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_imagine_video :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_imagine_video_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_loop :: proc(ctx: Slash_Ctx) -> Slash_Action {
	loop_out := handle_loop_slash(ctx.arg, context.temp_allocator)
	emit_lines(ctx.out, loop_out)
	if len(loop_out) == 0 {
		emit_line(ctx.out, loop_usage_message())
	}
	return .Continue
}

slash_h_soft_bash :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_soft_bash_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_permissions :: proc(ctx: Slash_Ctx) -> Slash_Action {
	mode := core.Permission_Mode.Always_Approve
	if ctx.perm != nil {
		mode = ctx.perm^
	}
	emit_lines(ctx.out, handle_permissions_slash(ctx.arg, mode, context.temp_allocator))
	return .Continue
}

slash_h_find :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_line(ctx.out, "aether: /find is TUI-only (Ctrl+F in aether tui)")
	return .Continue
}

slash_h_multiline :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_line(ctx.out, "use Ctrl+M in the TUI to toggle multiline (or /multiline|/ml there)")
	return .Continue
}

slash_h_toggle_mouse :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_line(ctx.out, "aether: /toggle-mouse-reporting is TUI-only (toggles SGR mouse capture)")
	return .Continue
}

slash_ctx_model :: proc(ctx: Slash_Ctx) -> string {
	if ctx.model != nil {
		return ctx.model^
	}
	return ""
}

slash_ctx_perm :: proc(ctx: Slash_Ctx) -> core.Permission_Mode {
	if ctx.perm != nil {
		return ctx.perm^
	}
	return .Always_Approve
}

slash_h_btw :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_btw_slash(ctx.sess, slash_ctx_model(ctx), ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_feedback :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_feedback_slash(ctx.sess, ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_context :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_context_slash(ctx.sess, ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_usage :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_line(ctx.out, "aether: /usage credit/billing UI is not available (Grok Build only).")
	emit_line(ctx.out, "Showing context window usage instead (/context):")
	emit_lines(ctx.out, handle_context_slash(ctx.sess, ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_diff :: proc(ctx: Slash_Ctx) -> Slash_Action {
	diff_out := handle_diff_slash(slash_ctx_cwd(ctx), ctx.arg, context.temp_allocator)
	emit_lines(ctx.out, diff_out)
	if len(diff_out) == 0 {
		emit_line(ctx.out, "aether: /diff produced no output")
	}
	return .Continue
}

slash_h_transcript :: proc(ctx: Slash_Ctx) -> Slash_Action {
	if ctx.sess == nil {
		emit_line(ctx.out, "aether: no session")
		return .Continue
	}
	emit_lines(ctx.out, handle_transcript_slash(ctx.sess^, context.temp_allocator))
	return .Continue
}

slash_h_recap :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_recap_slash(ctx.sess, slash_ctx_model(ctx), context.temp_allocator))
	return .Continue
}

slash_h_share :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_share_slash(ctx.sess, context.temp_allocator))
	return .Continue
}

slash_h_import_claude :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_import_claude_slash(ctx.arg, slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_dashboard :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_dashboard_slash(ctx.sess, context.temp_allocator))
	return .Continue
}

slash_h_mcp :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_mcp_slash(ctx.arg, ctx.opts.no_mcp, ctx.opts.quiet, context.temp_allocator))
	return .Continue
}

slash_h_hooks :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_hooks_slash(ctx.arg, slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_create_skill :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_line(ctx.out, handle_create_skill_slash(ctx.arg, slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_plugins :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_plugins_slash(ctx.arg, slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_status :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(
		ctx.out,
		handle_status_slash(ctx.sess, slash_ctx_model(ctx), slash_ctx_perm(ctx), context.temp_allocator),
	)
	return .Continue
}

slash_h_settings :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(
		ctx.out,
		handle_config_slash(ctx.sess, slash_ctx_model(ctx), slash_ctx_perm(ctx), context.temp_allocator),
	)
	return .Continue
}

slash_h_doctor :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(ctx.out, handle_doctor_slash(ctx.sess, slash_ctx_cwd(ctx), context.temp_allocator))
	return .Continue
}

slash_h_help :: proc(ctx: Slash_Ctx) -> Slash_Action {
	// B65: sectioned help (+ optional filter)
	emit_lines(ctx.out, handle_help_slash(ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_flush :: proc(ctx: Slash_Ctx) -> Slash_Action {
	flush_out := handle_flush_slash(ctx.sess, slash_ctx_model(ctx), ctx.arg, context.temp_allocator)
	emit_lines(ctx.out, flush_out)
	if len(flush_out) == 0 {
		emit_line(ctx.out, "aether: flush produced no output")
	}
	return .Continue
}

slash_h_memory :: proc(ctx: Slash_Ctx) -> Slash_Action {
	emit_lines(
		ctx.out,
		handle_memory_slash(ctx.arg, slash_ctx_cwd(ctx), context.temp_allocator, ctx.sess),
	)
	return .Continue
}

slash_h_dream :: proc(ctx: Slash_Ctx) -> Slash_Action {
	dream_out := handle_dream_slash(ctx.sess, slash_ctx_model(ctx), ctx.arg, context.temp_allocator)
	emit_lines(ctx.out, dream_out)
	if len(dream_out) == 0 {
		emit_line(ctx.out, "aether: dream produced no output")
	}
	return .Continue
}

slash_h_remember :: proc(ctx: Slash_Ctx) -> Slash_Action {
	// B32: save a user note to today's memory session log
	emit_lines(ctx.out, handle_remember_slash(slash_ctx_cwd(ctx), ctx.arg, context.temp_allocator))
	return .Continue
}

slash_h_vim_mode :: proc(ctx: Slash_Ctx) -> Slash_Action {
	// C2.2 — opt-in scrollback j/k navigation; B9 persists [ui] vim_mode
	slash_ui_bool(
		ctx.arg,
		"vim-mode",
		"vim_mode",
		core.vim_mode_enabled,
		core.set_vim_mode,
		core.toggle_vim_mode,
		"scrollback: j/k g/G H/L J/K i; Shift+←/→ user turns; config [ui] vim_mode",
		ctx.out,
	)
	return .Continue
}

slash_h_timestamps :: proc(ctx: Slash_Ctx) -> Slash_Action {
	// B37 — HH:MM prefixes on TUI transcript; persists [ui] timestamps
	slash_ui_bool(
		ctx.arg,
		"timestamps",
		"timestamps",
		core.timestamps_enabled,
		core.set_timestamps,
		core.toggle_timestamps,
		"HH:MM on transcript blocks; config [ui] timestamps",
		ctx.out,
	)
	return .Continue
}

slash_h_compact_mode :: proc(ctx: Slash_Ctx) -> Slash_Action {
	// B8 — denser TUI chrome; B9 persists [ui] compact_mode
	slash_ui_bool(
		ctx.arg,
		"compact-mode",
		"compact_mode",
		core.compact_mode_enabled,
		core.set_compact_mode,
		core.toggle_compact_mode,
		"denser header/status/tool chrome; config [ui] compact_mode",
		ctx.out,
	)
	return .Continue
}

slash_h_todos :: proc(ctx: Slash_Ctx) -> Slash_Action {
	arg_l := strings.to_lower(ctx.arg, context.temp_allocator)
	if arg_l == "clear" || arg_l == "reset" || arg_l == "empty" {
		tools.todo_clear()
		emit_line(ctx.out, "aether: todos cleared")
		return .Continue
	}
	if arg_l != "" && arg_l != "list" && arg_l != "show" && arg_l != "status" {
		emit_line(ctx.out, "aether: usage: /todos [clear]")
		return .Continue
	}
	sum := tools.summarize_todo_state(context.temp_allocator)
	if sum == "" || !strings.contains(sum, "\n") {
		emit_line(ctx.out, sum if sum != "" else "No tasks currently tracked.")
		return .Continue
	}
	emit_lines(ctx.out, sum)
	return .Continue
}

slash_h_effort :: proc(ctx: Slash_Ctx) -> Slash_Action {
	a := strings.trim_space(ctx.arg)
	if a == "" || a == "status" || a == "?" {
		cur := reasoning_effort_current()
		emit_line(
			ctx.out,
			fmt.tprintf(
				"aether: reasoning_effort = %s",
				cur if cur != "" else "(default/off)",
			),
		)
		emit_line(ctx.out, "aether: usage: /effort low|medium|high|xhigh|off")
		return .Continue
	}
	if !set_reasoning_effort(a) {
		emit_line(ctx.out, "aether: usage: /effort low|medium|high|xhigh|off")
		return .Continue
	}
	cur := reasoning_effort_current()
	_ = core.persist_reasoning_effort(cur if cur != "" else "off")
	emit_line(
		ctx.out,
		fmt.tprintf(
			"aether: reasoning_effort = %s",
			cur if cur != "" else "(default/off)",
		),
	)
	return .Continue
}

slash_h_whoami :: proc(ctx: Slash_Ctx) -> Slash_Action {
	// whoami prints its own stderr path; also summarize for sink
	code := run_whoami(ctx.opts.verbose)
	if code != 0 {
		emit_line(ctx.out, "whoami failed (not signed in?)")
	} else if ctx.out != nil {
		emit_line(ctx.out, "whoami: see identity above / auth ok")
	}
	return .Continue
}

slash_h_personas :: proc(ctx: Slash_Ctx) -> Slash_Action {
	ws := slash_ctx_cwd(ctx)
	if strings.trim_space(ctx.arg) == "help" || strings.trim_space(ctx.arg) == "?" {
		emit_line(
			ctx.out,
			"Usage: /personas — list personas for spawn_subagent persona=\n" +
			"Files: ~/.grok/personas/<name>.md or <cwd>/.grok/personas/<name>.md\n" +
			"Optional frontmatter: name, description. Body = instructions (M9).",
		)
		return .Continue
	}
	emit_line(ctx.out, format_personas_list(ws, context.temp_allocator))
	return .Continue
}

slash_h_compact :: proc(ctx: Slash_Ctx) -> Slash_Action {
	cmp_out := handle_compact_slash(
		ctx.sess,
		slash_ctx_model(ctx),
		ctx.arg,
		slash_ctx_perm(ctx),
		context.temp_allocator,
	)
	emit_lines(ctx.out, cmp_out)
	if len(cmp_out) == 0 {
		emit_line(ctx.out, "aether: compact produced no output")
	}
	// History replaced — UI should rebuild
	return .Session_Changed
}
