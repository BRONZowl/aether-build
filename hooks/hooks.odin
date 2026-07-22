// Package hooks — Grok-compatible discovery (A4.1–7).
// Command + HTTP handlers; lifecycle, tools, prompts, permissions, subagents, compact, notifications.
// Fail-open by default (except PreToolUse / UserPromptSubmit explicit deny).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package hooks

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "aether:core"

Hook_Event :: enum {
	Session_Start,
	Pre_Tool_Use,
	Post_Tool_Use,
	Post_Tool_Use_Failure,
	Session_End,
	Stop,
	User_Prompt_Submit,
	Permission_Denied,
	Subagent_Start,
	Subagent_Stop,
	Pre_Compact,
	Post_Compact,
	Notification,
	Other,
}

Hook_Decision :: enum {
	Allow,
	Deny,
}

// Hook_Kind: command (spawn) or http (POST envelope JSON).
Hook_Kind :: enum {
	Command,
	Http,
}

Hook_Spec :: struct {
	event:       Hook_Event,
	kind:        Hook_Kind,
	name:        string, // owned label
	command:     string, // owned; command hooks
	url:         string, // owned; http hooks (post-expansion preferred)
	timeout_s:   int, // default 5
	matcher:     string, // owned; empty = all
	source_dir:  string, // owned; for relative command resolution
	source_file: string, // owned path of json
}

Hook_Registry :: struct {
	specs: [dynamic]Hook_Spec,
}

g_registry:         Hook_Registry
g_loaded:           bool
g_session_end_fired: bool

hooks_enabled :: proc() -> bool {
	return !core.feature_killed("AETHER_NO_HOOKS")
}

destroy_spec :: proc(s: ^Hook_Spec) {
	delete(s.name)
	delete(s.command)
	delete(s.url)
	delete(s.matcher)
	delete(s.source_dir)
	delete(s.source_file)
}

destroy_registry :: proc(r: ^Hook_Registry) {
	for &s in r.specs {
		destroy_spec(&s)
	}
	delete(r.specs)
	r.specs = {}
}

// set_global_registry replaces process registry (takes ownership of specs).
set_global_registry :: proc(r: Hook_Registry) {
	destroy_registry(&g_registry)
	g_registry = r
	g_loaded = true
}

get_registry :: proc() -> ^Hook_Registry {
	return &g_registry
}

clear_global_registry :: proc() {
	destroy_registry(&g_registry)
	g_loaded = false
	g_session_end_fired = false
}

// parse_event_name accepts PascalCase and snake_case (+ common Grok aliases).
parse_event_name :: proc(s: string) -> (Hook_Event, bool) {
	switch s {
	case "SessionStart", "session_start", "sessionStart":
		return .Session_Start, true
	case "PreToolUse", "pre_tool_use", "preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile":
		return .Pre_Tool_Use, true
	case "PostToolUse", "post_tool_use", "postToolUse", "afterShellExecution", "afterMCPExecution", "afterFileEdit":
		return .Post_Tool_Use, true
	case "PostToolUseFailure", "post_tool_use_failure", "postToolUseFailure":
		return .Post_Tool_Use_Failure, true
	case "SessionEnd", "session_end", "sessionEnd":
		return .Session_End, true
	case "Stop", "stop":
		return .Stop, true
	case "UserPromptSubmit", "user_prompt_submit", "userPromptSubmit", "beforeSubmitPrompt":
		return .User_Prompt_Submit, true
	case "PermissionDenied", "permission_denied", "permissionDenied":
		return .Permission_Denied, true
	case "SubagentStart", "subagent_start", "subagentStart":
		return .Subagent_Start, true
	case "SubagentStop", "subagent_stop", "subagentStop", "SubagentEnd", "subagent_end", "subagentEnd":
		return .Subagent_Stop, true
	case "PreCompact", "pre_compact", "preCompact":
		return .Pre_Compact, true
	case "PostCompact", "post_compact", "postCompact":
		return .Post_Compact, true
	case "Notification", "notification":
		return .Notification, true
	}
	return .Other, false
}

event_string :: proc(e: Hook_Event) -> string {
	switch e {
	case .Session_Start:
		return "SessionStart"
	case .Pre_Tool_Use:
		return "PreToolUse"
	case .Post_Tool_Use:
		return "PostToolUse"
	case .Post_Tool_Use_Failure:
		return "PostToolUseFailure"
	case .Session_End:
		return "SessionEnd"
	case .Stop:
		return "Stop"
	case .User_Prompt_Submit:
		return "UserPromptSubmit"
	case .Permission_Denied:
		return "PermissionDenied"
	case .Subagent_Start:
		return "SubagentStart"
	case .Subagent_Stop:
		return "SubagentStop"
	case .Pre_Compact:
		return "PreCompact"
	case .Post_Compact:
		return "PostCompact"
	case .Notification:
		return "Notification"
	case .Other:
		return "Other"
	}
	return "Other"
}

// tool_name_matches: empty matcher = all; | split; aliases for Bash→run_terminal_cmd.
tool_name_matches :: proc(matcher, tool_name: string) -> bool {
	m := strings.trim_space(matcher)
	if m == "" {
		return true
	}
	// Expand tool aliases for matching
	candidates := make([dynamic]string, 0, 4, context.temp_allocator)
	append(&candidates, tool_name)
	if tool_name == "run_terminal_cmd" {
		append(&candidates, "Bash")
		append(&candidates, "bash")
	}
	if tool_name == "search_replace" || tool_name == "write" {
		append(&candidates, "Edit")
		append(&candidates, "Write")
	}

	// Split matcher on |
	start := 0
	for i := 0; i <= len(m); i += 1 {
		if i == len(m) || m[i] == '|' {
			pat := strings.trim_space(m[start:i])
			start = i + 1
			if pat == "" {
				continue
			}
			for c in candidates {
				if c == pat || strings.contains(c, pat) || strings.contains(pat, c) {
					return true
				}
			}
		}
	}
	return false
}

// tool_events need matcher filter when tool_name set.
is_tool_event :: proc(e: Hook_Event) -> bool {
	return e == .Pre_Tool_Use ||
		e == .Post_Tool_Use ||
		e == .Post_Tool_Use_Failure ||
		e == .Permission_Denied
}

// specs_for returns matching specs for event (+ tool filter for tool events).
specs_for :: proc(
	r: ^Hook_Registry,
	event: Hook_Event,
	tool_name: string = "",
	allocator := context.allocator,
) -> []Hook_Spec {
	if r == nil {
		return nil
	}
	out := make([dynamic]Hook_Spec, 0, 4, allocator)
	for s in r.specs {
		if s.event != event {
			continue
		}
		if is_tool_event(event) && tool_name != "" {
			if !tool_name_matches(s.matcher, tool_name) {
				continue
			}
		}
		append(&out, s) // shallow copy of strings (owned by registry)
	}
	return out[:]
}

status_text :: proc(r: ^Hook_Registry, allocator := context.allocator) -> string {
	if !hooks_enabled() {
		return strings.clone("hooks: DISABLED (AETHER_NO_HOOKS=1)", allocator)
	}
	if r == nil || len(r.specs) == 0 {
		return strings.clone(
			"hooks: none loaded (dirs: $GROK_HOME/hooks, <cwd>/.grok/hooks)",
			allocator,
		)
	}
	n_start, n_pre, n_post, n_fail, n_stop, n_end, n_ups, n_pd, n_ss, n_se, n_pc, n_poc, n_notif :=
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	for s in r.specs {
		switch s.event {
		case .Session_Start:
			n_start += 1
		case .Pre_Tool_Use:
			n_pre += 1
		case .Post_Tool_Use:
			n_post += 1
		case .Post_Tool_Use_Failure:
			n_fail += 1
		case .Stop:
			n_stop += 1
		case .Session_End:
			n_end += 1
		case .User_Prompt_Submit:
			n_ups += 1
		case .Permission_Denied:
			n_pd += 1
		case .Subagent_Start:
			n_ss += 1
		case .Subagent_Stop:
			n_se += 1
		case .Pre_Compact:
			n_pc += 1
		case .Post_Compact:
			n_poc += 1
		case .Notification:
			n_notif += 1
		case .Other:
		}
	}
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		fmt.tprintf(
			"hooks: %d (Start=%d Pre=%d Post=%d PostFail=%d Stop=%d End=%d Prompt=%d PermDeny=%d SubStart=%d SubStop=%d PreC=%d PostC=%d Notif=%d)\n",
			len(r.specs),
			n_start,
			n_pre,
			n_post,
			n_fail,
			n_stop,
			n_end,
			n_ups,
			n_pd,
			n_ss,
			n_se,
			n_pc,
			n_poc,
			n_notif,
		),
	)
	for s in r.specs {
		target := s.command
		kind_s := "cmd"
		if s.kind == .Http {
			target = s.url
			kind_s = "http"
		}
		strings.write_string(
			&b,
			fmt.tprintf(
				"  %s  matcher=%q  %s=%s  timeout=%ds\n",
				event_string(s.event),
				s.matcher if s.matcher != "" else "*",
				kind_s,
				target,
				s.timeout_s if s.timeout_s > 0 else 5,
			),
		)
	}
	return strings.to_string(b)
}

// hooks_root_user: $GROK_HOME/hooks
hooks_root_user :: proc(allocator := context.allocator) -> string {
	home := core.grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "hooks"}, allocator)
	return joined
}

// hooks_root_project: {cwd}/.grok/hooks
hooks_root_project :: proc(cwd: string, allocator := context.allocator) -> string {
	base := cwd
	if base == "" {
		base = "."
	}
	joined, _ := filepath.join({base, ".grok", "hooks"}, allocator)
	return joined
}
