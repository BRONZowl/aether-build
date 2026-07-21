// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:core"
import "aether:hooks"

// Nesting depth: top-level session = 0; first subagent = 1. Max depth 1.
g_subagent_depth: int

Subagent_Type :: enum {
	General_Purpose,
	Explore,
	Plan,
}

subagent_type_from_string :: proc(s: string) -> (Subagent_Type, bool) {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "", "general-purpose", "general_purpose", "general":
		return .General_Purpose, true
	case "explore":
		return .Explore, true
	case "plan":
		return .Plan, true
	}
	return .General_Purpose, false
}

subagent_type_string :: proc(t: Subagent_Type) -> string {
	switch t {
	case .General_Purpose:
		return "general-purpose"
	case .Explore:
		return "explore"
	case .Plan:
		return "plan"
	}
	return "general-purpose"
}

subagents_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_SUBAGENTS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	if v := os.get_env("GROK_SUBAGENTS", context.temp_allocator); v == "0" ||
	   strings.equal_fold(v, "false") {
		return false
	}
	// Config [subagents] enabled=false (env kill-switch still wins above).
	if !core.flag_subagents() {
		return false
	}
	return true
}

DENY_EXPLORE := []string{"search_replace", "spawn_subagent", "task"}
DENY_GENERAL := []string{"spawn_subagent", "task"}

// deny_tools_for_subagent: children never spawn; explore/plan cannot edit.
deny_tools_for_subagent :: proc(t: Subagent_Type) -> []string {
	switch t {
	case .Explore, .Plan:
		return DENY_EXPLORE
	case .General_Purpose:
		return DENY_GENERAL
	}
	return DENY_GENERAL
}

subagent_system_prompt :: proc(
	t: Subagent_Type,
	cwd: string,
	skills_catalog: string,
	allocator := context.allocator,
	persona_instructions: string = "",
) -> string {
	role: string
	switch t {
	case .Explore:
		role =
			"You are an explore subagent. Investigate the codebase with read/search/shell tools. Do NOT edit files (search_replace is unavailable). Return a clear findings report with file paths."
	case .Plan:
		role =
			"You are a plan subagent. Explore the codebase and produce a concrete implementation plan (steps, files to touch, risks). Do NOT edit files. End with a structured plan the parent can execute."
	case .General_Purpose:
		role =
			"You are a general-purpose subagent. Complete the assigned task efficiently using available tools. You may edit files. Do not spawn further subagents. Report results clearly to the parent."
	}
	date := utc_date_string(context.temp_allocator)
	base := fmt.aprintf(
		`%s

Workspace: %s
Date (UTC): %s

You are a delegated worker — stay in scope. Prefer tools over guessing. Be concise in the final answer.`,
		role,
		cwd,
		date,
		allocator = allocator,
	)
	if persona_instructions != "" {
		base = fmt.aprintf(
			"%s\n\n## Persona instructions\n\n%s",
			base,
			persona_instructions,
			allocator = allocator,
		)
	}
	if skills_catalog != "" {
		return fmt.aprintf("%s%s", base, skills_catalog, allocator = allocator)
	}
	return base
}

// refresh_subagent_system_prompt replaces the first System message (or prepends one).
refresh_subagent_system_prompt :: proc(
	msgs: ^[dynamic]Chat_Message,
	kind: Subagent_Type,
	cwd: string,
	skills_catalog: string,
	allocator := context.allocator,
	persona_instructions: string = "",
) {
	sys := subagent_system_prompt(kind, cwd, skills_catalog, allocator, persona_instructions)
	if len(msgs) > 0 && msgs[0].role == .System {
		delete(msgs[0].content)
		msgs[0].content = sys
		return
	}
	// Prepend system if missing
	sys_msg := Chat_Message {
		role    = .System,
		content = sys,
	}
	inject_at(msgs, 0, sys_msg)
}

// sanitize_resume_from drops model sentinel values; returns "" when absent.
sanitize_resume_from :: proc(raw: string) -> string {
	t := strings.trim_space(raw)
	if t == "" {
		return ""
	}
	if strings.equal_fold(t, "null") ||
	   strings.equal_fold(t, "none") ||
	   strings.equal_fold(t, "undefined") {
		return ""
	}
	return t
}

// run_subagent executes a synchronous nested agent turn; returns report text with resume footer.
run_subagent :: proc(
	creds: Credentials,
	model: string,
	prompt: string,
	kind: Subagent_Type,
	parent: Turn_Options,
	allocator := context.allocator,
	isolation: Isolation_Mode = .None,
	inherit_worktree := "",
	persona_instructions := "",
) -> string {
	empty: [dynamic]Chat_Message
	return run_subagent_seeded(
		creds,
		model,
		prompt,
		kind,
		parent,
		empty,
		false,
		allocator,
		isolation,
		inherit_worktree,
		persona_instructions,
	)
}

// run_subagent_seeded: has_seed transfers ownership of seed_msgs.
run_subagent_seeded :: proc(
	creds: Credentials,
	model: string,
	prompt: string,
	kind: Subagent_Type,
	parent: Turn_Options,
	seed_msgs: [dynamic]Chat_Message,
	has_seed: bool,
	allocator := context.allocator,
	isolation: Isolation_Mode = .None,
	inherit_worktree := "",
	persona_instructions := "",
) -> string {
	if !subagents_enabled() {
		if has_seed {
			destroy_messages(seed_msgs[:])
		}
		return strings.clone("error: subagents disabled (AETHER_NO_SUBAGENTS=1)", allocator)
	}
	if g_subagent_depth >= 1 {
		if has_seed {
			destroy_messages(seed_msgs[:])
		}
		return strings.clone("error: subagents cannot spawn further subagents", allocator)
	}
	if strings.trim_space(prompt) == "" {
		if has_seed {
			destroy_messages(seed_msgs[:])
		}
		return strings.clone("error: prompt is required", allocator)
	}

	g_subagent_depth += 1
	defer g_subagent_depth -= 1

	label := subagent_type_string(kind)
	hooks.run_subagent_start_hooks(parent.workspace, label, prompt, false)
	if parent.on_status != nil {
		parent.on_status(fmt.tprintf("subagent: %s…", label))
	} else if !parent.quiet {
		fmt.eprintf("aether: subagent %s starting\n", label)
	}

	deny := deny_tools_for_subagent(kind)
	child_status :: proc(text: string) {
		// Prefixed via parent if available — use package-level trampoline
		if g_sub_parent_status != nil {
			g_sub_parent_status(fmt.tprintf("[sub] %s", text))
		}
	}
	g_sub_parent_status = parent.on_status
	defer g_sub_parent_status = nil

	max_turns := 12
	if parent.max_turns > 0 && parent.max_turns < max_turns {
		max_turns = parent.max_turns
	}

	catalog := ""
	if parent.skills_enabled {
		catalog = skills_catalog_text(context.temp_allocator)
	}

	desc_src := prompt
	task := bg_new_subagent_task(kind, desc_src, model, context.allocator)

	ws, wt, werr := resolve_subagent_workspace(
		parent.workspace,
		isolation,
		inherit_worktree,
		task.id,
		context.allocator,
	)
	if werr != "" {
		if has_seed {
			destroy_messages(seed_msgs[:])
		}
		task.status = .Failed
		task.result = strings.clone(werr, context.allocator)
		task.delivered = true
		return strings.clone(werr, allocator)
	}
	if wt != "" {
		task.worktree_path = wt
	}

	msgs: [dynamic]Chat_Message
	if has_seed {
		msgs = seed_msgs
		// Resume: keep original system prompt (persona already applied if any)
		refresh_subagent_system_prompt(&msgs, kind, ws, catalog, allocator, persona_instructions)
		append(
			&msgs,
			Chat_Message {
				role    = .User,
				content = strings.clone(prompt, allocator),
			},
		)
	} else {
		msgs = make([dynamic]Chat_Message, 0, 16, allocator)
		append(
			&msgs,
			Chat_Message {
				role    = .System,
				content = subagent_system_prompt(kind, ws, catalog, allocator, persona_instructions),
			},
		)
		append(
			&msgs,
			Chat_Message {
				role    = .User,
				content = strings.clone(prompt, allocator),
			},
		)
	}
	defer destroy_messages(msgs[:])

	child_opts := Turn_Options {
		workspace         = ws,
		max_turns         = max_turns,
		quiet             = true, // child logs via on_status only
		verbose           = parent.verbose,
		permission_mode   = parent.permission_mode,
		permission_live   = parent.permission_live,
		permission_allow  = parent.permission_allow,
		permission_deny   = parent.permission_deny,
		ask_turn_allow    = parent.ask_turn_allow,
		on_status         = child_status if parent.on_status != nil else nil,
		on_history        = nil, // don't pollute parent UI mid-child
		on_ask            = parent.on_ask,
		cancel            = parent.cancel,
		on_poll           = parent.on_poll,
		mcp_enabled       = parent.mcp_enabled,
		skills_enabled    = parent.skills_enabled,
		subagents_enabled = false, // schema: no spawn for child
		deny_tools        = deny,
	}

	text, code := run_agent_turn(creds, model, &msgs, child_opts)

	result: string
	status: Bg_Task_Status
	wt_path := task.worktree_path

	if code == 0 {
		status = .Completed
		body := text if text != "" else "(empty report)"
		result = format_subagent_result(task.id, kind, "completed", body, "", wt_path, allocator)
		if text != "" {
			delete(text)
		}
	} else {
		// non-zero: include any last assistant content if present
		partial := ""
		#reverse for m in msgs {
			if m.role == .Assistant && m.content != "" {
				partial = m.content
				break
			}
		}
		err_label := "error"
		switch code {
		case 2:
			err_label = "max turns"
		case 3:
			err_label = "model/HTTP error"
		case 4:
			err_label = "cancelled"
		}
		if code == 4 {
			status = .Cancelled
			result = format_subagent_result(
				task.id,
				kind,
				"cancelled",
				partial if partial != "" else text,
				"",
				wt_path,
				allocator,
			)
		} else {
			status = .Failed
			if partial != "" {
				result = format_subagent_result(
					task.id,
					kind,
					"stopped",
					partial,
					err_label,
					wt_path,
					allocator,
				)
			} else {
				result = format_subagent_result(
					task.id,
					kind,
					"failed",
					"",
					err_label,
					wt_path,
					allocator,
				)
			}
		}
		if text != "" {
			delete(text)
		}
	}

	// Sync path never took a running slot via bg_try_begin
	bg_finish_subagent(task, status, result, msgs[:], model, false)
	return strings.clone(result, allocator)
}

// Trampoline for nested status (set during run_subagent).
g_sub_parent_status: Status_Handler

// handle_spawn_subagent parses tool JSON and runs a subagent (optional resume_from).
handle_spawn_subagent :: proc(
	creds: Credentials,
	model: string,
	arguments_json: string,
	parent: Turn_Options,
	allocator := context.allocator,
) -> string {
	prompt := extract_json_string_field_agent(arguments_json, "prompt")
	if prompt == "" {
		return strings.clone("error: prompt is required", allocator)
	}
	type_s := extract_json_string_field_agent(arguments_json, "subagent_type")
	type_provided := strings.trim_space(type_s) != ""
	kind, ok := subagent_type_from_string(type_s)
	if type_provided && !ok {
		return fmt.aprintf(
			"error: unknown subagent_type %q (use explore, plan, general-purpose)",
			type_s,
			allocator = allocator,
		)
	}
	desc := extract_json_string_field_agent(arguments_json, "description")
	background := extract_json_bool_field_agent(arguments_json, "background")
	resume_raw := extract_json_string_field_agent(arguments_json, "resume_from")
	resume_id := sanitize_resume_from(resume_raw)
	isol_s := extract_json_string_field_agent(arguments_json, "isolation")
	isolation, isol_ok := isolation_from_string(isol_s)
	if !isol_ok {
		return fmt.aprintf(
			"error: unknown isolation %q (use none or worktree)",
			isol_s,
			allocator = allocator,
		)
	}
	// M9: optional persona
	persona_name := extract_json_string_field_agent(arguments_json, "persona")
	persona_instr := ""
	if strings.trim_space(persona_name) != "" {
		pi, perr := persona_instructions_for(persona_name, parent.workspace, context.temp_allocator)
		if perr != "" {
			return fmt.aprintf("error: %s", perr, allocator = allocator)
		}
		persona_instr = pi
	}

	if resume_id != "" {
		src, err := bg_lookup_for_resume(resume_id, allocator)
		if err != "" {
			return err
		}
		// Type: if provided must match; else inherit
		if type_provided && kind != src.kind {
			destroy_messages(src.msgs[:])
			delete(src.id)
			delete(src.model)
			delete(src.worktree_path)
			return fmt.aprintf(
				"error: resume_from type mismatch: source is %s, requested %s",
				subagent_type_string(src.kind),
				subagent_type_string(kind),
				allocator = allocator,
			)
		}
		kind = src.kind
		// Prefer source model if set; isolation ignored — inherit worktree
		run_model := model
		if src.model != "" {
			run_model = src.model
		}
		inherit_wt := src.worktree_path
		delete(src.id)
		// src.msgs ownership transfers into run/spawn
		if background {
			out := spawn_subagent_background_seeded(
				creds,
				run_model,
				prompt,
				kind,
				desc,
				parent,
				src.msgs,
				true,
				allocator,
				.None,
				inherit_wt,
			)
			delete(src.model)
			delete(src.worktree_path)
			return out
		}
		out := run_subagent_seeded(
			creds,
			run_model,
			prompt,
			kind,
			parent,
			src.msgs,
			true,
			allocator,
			.None,
			inherit_wt,
		)
		delete(src.model)
		delete(src.worktree_path)
		return out
	}

	if background {
		return spawn_subagent_background(
			creds,
			model,
			prompt,
			kind,
			desc,
			parent,
			allocator,
			isolation,
			"",
			persona_instr,
		)
	}
	return run_subagent(creds, model, prompt, kind, parent, allocator, isolation, "", persona_instr)
}

// small JSON string extractor (duplicated lightly to avoid mcp import here for fields)
extract_json_string_field_agent :: proc(raw: string, key: string) -> string {
	pat := fmt.tprintf("\"%s\"", key)
	i := strings.index(raw, pat)
	if i < 0 {
		return ""
	}
	rest := raw[i + len(pat):]
	for len(rest) > 0 && rest[0] != ':' {
		rest = rest[1:]
	}
	if len(rest) == 0 {
		return ""
	}
	rest = rest[1:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != '"' {
		return ""
	}
	rest = rest[1:]
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	esc := false
	for j in 0 ..< len(rest) {
		ch := rest[j]
		if esc {
			strings.write_byte(&b, ch)
			esc = false
			continue
		}
		if ch == '\\' {
			esc = true
			continue
		}
		if ch == '"' {
			return strings.to_string(b)
		}
		strings.write_byte(&b, ch)
	}
	return ""
}
