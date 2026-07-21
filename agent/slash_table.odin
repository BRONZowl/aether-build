// Package agent — table-driven slash dispatch for emit-only commands (P3).
// Session lifecycle and permission toggles stay in run_slash's switch.
// Uses a static route table (no heap map) so tests with tracking allocators
// cannot invalidate keys between cases.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "aether:core"

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

// SLASH_ROUTES: emit-only commands (primary + aliases).
SLASH_ROUTES := [?]Slash_Route {
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
