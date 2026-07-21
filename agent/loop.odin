package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import "aether:core"
import "aether:hooks"
import "aether:mcp"
import "aether:skills"
import "aether:tools"

// Status_Handler optional UI hook (e.g. TUI status bar).
Status_Handler :: #type proc(text: string)

// History_Handler optional: msgs changed mid-turn (tool cards, etc.).
History_Handler :: #type proc()

// Ask_Handler optional: TUI/REPL tool approval (Deny / Once / Always session).
// name = tool name; summary = short args/command for display.
Ask_Handler :: #type proc(name, summary: string) -> core.Ask_Decision

// Cancel_Flag cooperative cancel (e.g. TUI Ctrl+C mid-turn).
// Checked between steps and during HTTP via libcurl xferinfo (true mid-request cancel).
Cancel_Flag :: ^bool

// Poll_Handler optional: called during blocking HTTP so UIs can read keys (set cancel).
Poll_Handler :: #type proc()

// Turn_Options carries per-run policy for the agent loop.
Turn_Options :: struct {
	workspace:        string,
	max_turns:        int,
	quiet:            bool,
	verbose:          bool,
	permission_mode:  core.Permission_Mode, // snapshot / headless default
	permission_live:  ^core.Permission_Mode, // optional; TUI mid-turn updates
	permission_allow: []string,
	permission_deny:  []string,
	// After first ask-mode allow this turn, subsequent Ask tools auto-allow.
	// Reset by caller per turn (stack bool). Optional.
	ask_turn_allow:   ^bool,
	on_status:        Status_Handler, // optional
	on_history:       History_Handler, // optional; after msgs append mid-turn
	on_ask:           Ask_Handler, // optional; replaces stdin y/N when set
	// ask_user_question: optional TUI multi-choice; nil → stdin path
	on_ask_user:      Ask_User_Handler,
	cancel:           Cancel_Flag, // optional; set *cancel=true to abort HTTP/tool loop
	on_poll:          Poll_Handler, // optional; mid-HTTP key/cancel poll
	// MCP: when true and registry has servers, expose search_tool/use_tool
	mcp_enabled:      bool,
	// Skills: expose skill tool when registry non-empty
	skills_enabled:   bool,
	// Subagents: expose spawn_subagent when enabled and depth allows
	subagents_enabled: bool,
	// deny_tools: never offer or run these tool names (subagent policy)
	deny_tools:       []string,
	// Plan enter/exit approval (TUI modal); nil → default asks / headless auto
	on_plan_enter:    Plan_Enter_Handler,
	on_plan_exit:     Plan_Exit_Handler,
	// Optional session latch for first-turn memory inject (A2.3)
	memory_injected:  ^bool,
	// Optional session for auto-compact / flush (B1.2)
	session:          ^Session,
}

// effective_permission_mode prefers live TUI mode when set.
effective_permission_mode :: proc(opts: Turn_Options) -> core.Permission_Mode {
	if opts.permission_live != nil {
		return opts.permission_live^
	}
	return opts.permission_mode
}

// ask_rest_of_turn_active is true when this turn already approved one ask-mode tool.
ask_rest_of_turn_active :: proc(opts: Turn_Options) -> bool {
	return opts.ask_turn_allow != nil && opts.ask_turn_allow^
}

// run_agent_turn runs the tool loop against an existing message history.
// Caller owns msgs (must already include system + latest user message).
// On success (final assistant text), appends the assistant message to msgs and returns text + 0.
// Exit codes: 0 ok, 2 max turns, 3 model/HTTP error, 4 cancelled.
run_agent_turn :: proc(
	creds: Credentials,
	model: string,
	msgs: ^[dynamic]Chat_Message,
	opts: Turn_Options,
) -> (final_text: string, code: int) {
	reg := mcp.get_registry()
	with_mcp := opts.mcp_enabled && reg != nil && len(reg.tools) > 0
	sreg := skills.get_registry()
	with_skills := opts.skills_enabled && sreg != nil && len(sreg.skills) > 0
	with_spawn := opts.subagents_enabled && subagents_enabled() && g_subagent_depth == 0
	with_plan := plan_mode_enabled()
	with_memory := tools.memory_enabled()
	deny := opts.deny_tools
	// Feature-flagged tools: strip from schema when disabled.
	deny_slice := deny
	merged := make([dynamic]string, 0, len(deny) + 2, context.temp_allocator)
	for d in deny {
		append(&merged, d)
	}
	if !web_fetch_enabled() {
		append(&merged, "web_fetch")
	}
	if !tools.todo_write_enabled() {
		append(&merged, "todo_write")
	}
	if !ask_user_enabled() {
		append(&merged, "ask_user_question")
	}
	if !tools.lsp_enabled() {
		append(&merged, "lsp")
	}
	if !monitor_enabled() {
		append(&merged, "monitor")
	}
	if !scheduler_enabled() {
		append(&merged, "scheduler_create")
		append(&merged, "scheduler_list")
		append(&merged, "scheduler_delete")
	}
	if !goal_enabled() {
		append(&merged, "update_goal")
	}
	if !image_gen_enabled() {
		append(&merged, "image_gen")
		append(&merged, "image_edit")
	}
	if !video_gen_enabled() {
		append(&merged, "image_to_video")
		append(&merged, "reference_to_video")
	}
	if len(merged) > len(deny) {
		deny_slice = merged[:]
	}
	tools_json := tools.tools_json_schema(
		with_mcp,
		with_skills,
		with_spawn,
		with_plan,
		with_memory,
		deny_slice,
	)
	turns := opts.max_turns if opts.max_turns > 0 else 20

	// One-shot plan activation / exit reminders for user toggles and session resume
	if maybe_inject_plan_reminders(msgs, opts.workspace) {
		// history may have grown; UI optional refresh after tools anyway
	}
	// First-turn memory context (workspace/global MEMORY.md); latch in system message
	_ = ensure_memory_injection_msgs(
		msgs,
		opts.workspace,
		last_user_text(msgs[:]),
		opts.memory_injected,
	)
	// Auto-compact once at turn start when over threshold (heuristic)
	if note := maybe_auto_compact(
		opts.session,
		msgs,
		model,
		effective_permission_mode(opts),
		context.temp_allocator,
	); note != "" {
		if opts.on_status != nil {
			opts.on_status("auto-compact")
		}
		if !opts.quiet {
			fmt.eprintf("%s\n", note)
		}
		if opts.on_history != nil {
			opts.on_history()
		}
	}
	// Scheduler fires, monitor line events, bg completions
	_ = maybe_inject_scheduler_fires(msgs)
	_ = maybe_inject_monitor_events(msgs)
	if maybe_inject_bg_completions(msgs) {
		// model sees them on first sample
	}

	// status_stderr_worthy: headless stderr stays quiet like Grok (-p → result on stdout).
	// Progress (sampling/tool) only with --verbose; errors/cancel always surface.
	status_stderr_worthy :: proc(text: string) -> bool {
		t := strings.trim_space(text)
		if strings.has_prefix(t, "error") || strings.has_prefix(t, "Error") {
			return true
		}
		if t == "cancelled" || strings.has_prefix(t, "max turns") {
			return true
		}
		if strings.contains(t, "fail") || strings.has_prefix(t, "goal budget") {
			return true
		}
		return false
	}

	emit_status :: proc(opts: Turn_Options, text: string) {
		if opts.on_status != nil {
			opts.on_status(text)
		}
		if !opts.quiet && (opts.verbose || status_stderr_worthy(text)) {
			fmt.eprintf("aether: %s\n", text)
		}
	}

	emit_history :: proc(opts: Turn_Options) {
		if opts.on_history != nil {
			opts.on_history()
		}
	}

	cancelled :: proc(opts: Turn_Options) -> bool {
		return opts.cancel != nil && opts.cancel^
	}

	// short error for UI status bar
	short_err :: proc(err: string) -> string {
		if len(err) <= 160 {
			return err
		}
		return fmt.tprintf("%s…", err[:157])
	}

	// Wire FG tool cancel/poll (bash honors Ctrl+C mid-command)
	tools.tool_set_cancel_hooks(opts.cancel, opts.on_poll)
	defer tools.tool_clear_cancel_hooks()
	core.hang_log("run_agent_turn enter")
	defer core.hang_log("run_agent_turn exit")

	for turn_i in 0 ..< turns {
		if cancelled(opts) {
			emit_status(opts, "cancelled")
			return "", 4
		}
		// Scheduler / monitor / completions during previous tool batch
		if turn_i > 0 {
			inj := maybe_inject_scheduler_fires(msgs)
			if maybe_inject_monitor_events(msgs) {
				inj = true
			}
			if maybe_inject_bg_completions(msgs) {
				inj = true
			}
			if inj {
				emit_history(opts)
			}
		}
		emit_status(opts, fmt.tprintf("sampling %d/%d…", turn_i + 1, turns))
		if opts.verbose && !opts.quiet {
			fmt.eprintf("aether: POST %s/chat/completions\n", host_of(creds.base_url))
		}

		asst, err := chat_completion_stream(
			creds,
			model,
			msgs[:],
			tools_json,
			opts.quiet,
			opts.verbose,
			context.allocator,
			Chat_Http_Opts {
				cancel  = opts.cancel,
				on_poll = opts.on_poll,
				verbose = opts.verbose,
			},
		)
		if err == "cancelled" || cancelled(opts) {
			destroy_assistant_turn(&asst)
			emit_status(opts, "cancelled")
			finish_plan_mode_turn()
			return "", 4
		}
		if err != "" {
			emit_status(opts, fmt.tprintf("error: %s", short_err(err)))
			if !opts.quiet {
				// full line if longer than status truncation
				if len(err) > 160 {
					fmt.eprintf("aether: model error: %s\n", err)
				}
			} else if opts.on_status == nil {
				fmt.eprintf("aether: model error: %s\n", err)
			}
			hooks.run_stop_hooks(opts.workspace, "error")
			finish_plan_mode_turn()
			return "", 3
		}

		if len(asst.tool_calls) == 0 {
			text := strings.clone(asst.content)
			streamed := asst.streamed_to_stdout
			append(
				msgs,
				Chat_Message {
					role    = .Assistant,
					content = strings.clone(asst.content),
				},
			)
			destroy_assistant_turn(&asst)
			emit_history(opts)
			// Final answer only on stdout (markdown source, Grok plain).
			// Mid-tool assistant chatter is never printed unless it was live-streamed.
			if !streamed && strings.trim_space(text) != "" {
				out := strings.trim_right_space(text)
				fmt.println(out)
			}
			hooks.run_stop_hooks(opts.workspace, "completed")
			if note := goal_check_budget(msgs[:]); note != "" {
				append(msgs, Chat_Message{role = .System, content = strings.clone(note)})
				emit_history(opts)
				emit_status(opts, "goal budget exhausted — paused")
			}
			finish_plan_mode_turn()
			return text, 0
		}

		asst_msg := Chat_Message {
			role       = .Assistant,
			content    = strings.clone(asst.content),
			tool_calls = asst.tool_calls,
		}
		asst.tool_calls = nil
		asst.content = ""
		destroy_assistant_turn(&asst)
		append(msgs, asst_msg)
		emit_history(opts)

		for tc in asst_msg.tool_calls {
			if cancelled(opts) {
				emit_status(opts, "cancelled")
				hooks.run_stop_hooks(opts.workspace, "cancelled")
				finish_plan_mode_turn()
				return "", 4
			}
			emit_status(opts, fmt.tprintf("tool: %s", tc.name))
			core.hang_log(fmt.tprintf("tool enter %s", tc.name))
			result := run_one_tool(creds, model, tc.name, tc.arguments, opts)
			core.hang_log(fmt.tprintf("tool exit %s", tc.name))
			// PostToolUse / PostToolUseFailure (non-blocking)
			hooks.run_post_tool_hooks(
				opts.workspace,
				tc.name,
				tc.arguments,
				result,
				tool_result_is_error(result),
			)
			append(
				msgs,
				Chat_Message {
					role         = .Tool,
					content      = result,
					tool_call_id = strings.clone(tc.id),
				},
			)
			emit_history(opts)
			emit_status(opts, tool_status_label(tc.name, result))
			if tool_result_is_error(result) && !opts.quiet && opts.on_status == nil {
				// headless/REPL: short stderr detail when no UI status bar
				detail := strings.trim_space(result)
				if len(detail) > 120 {
					detail = fmt.tprintf("%s…", detail[:117])
				}
				fmt.eprintf("aether: %s\n", detail)
			}
		}
		// Surface scheduler / monitor / bg completions while tools ran (before next sample)
		inj_end := maybe_inject_scheduler_fires(msgs)
		if maybe_inject_monitor_events(msgs) {
			inj_end = true
		}
		if maybe_inject_bg_completions(msgs) {
			inj_end = true
		}
		if inj_end {
			emit_history(opts)
		}
	}

	emit_status(opts, fmt.tprintf("max turns (%d) — history kept", turns))
	if !opts.quiet {
		fmt.eprintf(
			"aether: max tool iterations (%d); history kept — continue or /clear\n",
			turns,
		)
	}
	if note := goal_check_budget(msgs[:]); note != "" {
		append(msgs, Chat_Message{role = .System, content = strings.clone(note)})
		emit_history(opts)
		emit_status(opts, "goal budget exhausted — paused")
	}
	finish_plan_mode_turn()
	return "", 2
}

// tool_result_is_error reports results that follow the tools/agent error: prefix convention.
tool_result_is_error :: proc(result: string) -> bool {
	t := strings.trim_space(result)
	return strings.has_prefix(t, "error:") || strings.has_prefix(t, "Error:")
}

// tool_status_label is the short chrome string after a tool finishes.
tool_status_label :: proc(name, result: string) -> string {
	if tool_result_is_error(result) {
		return fmt.tprintf("fail: %s", name)
	}
	return fmt.tprintf("done: %s", name)
}

run_one_tool :: proc(
	creds: Credentials,
	model: string,
	name: string,
	arguments_json: string,
	opts: Turn_Options,
	allocator := context.allocator,
) -> string {
	if tools.tool_name_denied(name, opts.deny_tools) {
		return fmt.aprintf(
			"error: tool %s denied by subagent/policy filter",
			name,
			allocator = allocator,
		)
	}
	// Plan mode tools — no permission gate (read-only UX; seed write is internal).
	if name == "enter_plan_mode" {
		return enter_plan_mode_impl(opts.workspace, opts.on_plan_enter, allocator)
	}
	if name == "exit_plan_mode" {
		return exit_plan_mode_impl(opts.workspace, opts.on_plan_exit, allocator)
	}

	// Plan mode edit gate (Active only): Edit/Write tools only plan file.
	// Grok AccessKind::Edit — bash/web/MCP not gated here.
	if plan_mode_is_active() && plan_mode_blocks_write_tool(name) {
		plan_path := plan_file_path_for_cwd(opts.workspace, context.temp_allocator)
		// Allow search_replace / write / delete_file only for the plan file path.
		if name == "search_replace" || name == "write" || name == "delete_file" {
			file_path := ""
			if obj, ok := tools.json_obj(arguments_json); ok {
				file_path = tools.jstr(obj, "file_path")
				if file_path == "" {
					file_path = tools.jstr(obj, "target_file")
				}
			}
			target, inside := resolve_edit_target_abs(opts.workspace, file_path, context.temp_allocator)
			if inside && is_plan_file_write(target, plan_path) {
				// Plan-file edits auto-allow (mirror Grok should_auto_approve_edit).
				return tools.dispatch(name, arguments_json, opts.workspace, allocator)
			}
		}
		return plan_mode_edit_rejected(plan_path, allocator)
	}

	command := ""
	if name == "run_terminal_cmd" || name == "monitor" {
		if obj, ok := tools.json_obj(arguments_json); ok {
			command = tools.jstr(obj, "command")
		}
	}
	mode := effective_permission_mode(opts)
	// Config + process-local session grants (Grok AllowAlways / RejectAlways).
	merged_allow := core.merge_allow_lists(opts.permission_allow, context.temp_allocator)
	merged_deny := core.merge_deny_lists(opts.permission_deny, context.temp_allocator)
	decision := core.check_tool(
		mode,
		name,
		command,
		merged_allow,
		merged_deny,
	)
	// First ask-allow this turn → auto-allow later write/shell asks.
	if decision == .Ask && ask_rest_of_turn_active(opts) {
		decision = .Allow
	}
	switch decision {
	case .Deny:
		hooks.run_permission_denied_hooks(
			opts.workspace,
			name,
			arguments_json,
			fmt.tprintf("permission mode %s", core.permission_mode_string(mode)),
		)
		return fmt.aprintf(
			"error: tool %s denied by permission mode %s",
			name,
			core.permission_mode_string(mode),
			allocator = allocator,
		)
	case .Ask:
		summary := arguments_json
		if command != "" {
			summary = command
		}
		if len(summary) > 200 {
			summary = summary[:200]
		}
		// Vendor-compatible Notification for attention-needed permission prompts.
		hooks.run_notification_hooks(
			opts.workspace,
			"permission_prompt",
			fmt.tprintf("%s: %s", name, summary),
			"Permission required",
			"info",
		)
		ask_dec: core.Ask_Decision = .Deny
		if opts.on_ask != nil {
			ask_dec = opts.on_ask(name, summary)
		} else {
			ask_dec = approve_tool_interactive(name, summary, opts.quiet)
		}
		if ask_dec == .Never {
			rule := core.rule_for_session_grant(name, command, context.temp_allocator)
			if rule != "" {
				core.session_deny_add(rule)
				if opts.on_status != nil {
					opts.on_status(fmt.tprintf("session deny: %s", rule))
				} else if !opts.quiet {
					fmt.eprintf("aether: session deny: %s\n", rule)
				}
			}
			hooks.run_permission_denied_hooks(
				opts.workspace,
				name,
				arguments_json,
				"user never-allow",
			)
			return fmt.aprintf("error: tool %s denied by user (session never-allow)", name, allocator = allocator)
		}
		if ask_dec == .Deny {
			hooks.run_permission_denied_hooks(opts.workspace, name, arguments_json, "user deny")
			return fmt.aprintf("error: tool %s denied by user", name, allocator = allocator)
		}
		if ask_dec == .Always {
			rule := core.rule_for_session_grant(name, command, context.temp_allocator)
			if rule != "" {
				core.session_allow_add(rule)
				if opts.on_status != nil {
					opts.on_status(fmt.tprintf("session allow: %s", rule))
				} else if !opts.quiet {
					fmt.eprintf("aether: session allow: %s\n", rule)
				}
			}
		}
		// Once and Always both proceed; rest-of-turn auto-allow on positive answer.
		// Never must not set ask_turn_allow (handled above).
		if opts.ask_turn_allow != nil {
			opts.ask_turn_allow^ = true
			if opts.on_status != nil {
				opts.on_status("tools auto-allowed for rest of turn")
			} else if !opts.quiet {
				fmt.eprintf("aether: tools auto-allowed for rest of turn\n")
			}
		}
	case .Allow:
	}

	// PreToolUse hooks (blocking deny; fail-open)
	if hooks.hooks_enabled() {
		hdec, hreason := hooks.run_pre_tool_hooks(opts.workspace, name, arguments_json)
		if hdec == .Deny {
			return fmt.aprintf(
				"error: tool %s denied by hook: %s",
				name,
				hreason if hreason != "" else "PreToolUse",
				allocator = allocator,
			)
		}
	}

	if name == "spawn_subagent" || name == "task" {
		return handle_spawn_subagent(creds, model, arguments_json, opts, allocator)
	}
	if name == "get_task_output" {
		return handle_get_task_output(arguments_json, allocator)
	}
	if name == "wait_tasks" || name == "wait_commands_or_subagents" {
		return handle_wait_tasks(arguments_json, allocator)
	}
	if name == "kill_task" {
		return handle_kill_task(arguments_json, allocator)
	}
	if name == "run_terminal_cmd" && is_background_arg(arguments_json) {
		return handle_bash_background(arguments_json, opts, allocator)
	}
	if name == "monitor" {
		return handle_monitor(arguments_json, opts, allocator)
	}
	if name == "scheduler_create" {
		return handle_scheduler_create(arguments_json, allocator)
	}
	if name == "scheduler_list" {
		return handle_scheduler_list(arguments_json, allocator)
	}
	if name == "scheduler_delete" {
		return handle_scheduler_delete(arguments_json, allocator)
	}
	if name == "update_goal" {
		return handle_update_goal(arguments_json, allocator)
	}
	if name == "image_gen" {
		return handle_image_gen(creds, arguments_json, allocator)
	}
	if name == "image_edit" {
		return handle_image_edit(creds, arguments_json, allocator)
	}
	if name == "image_to_video" {
		return handle_image_to_video(creds, arguments_json, allocator)
	}
	if name == "reference_to_video" {
		return handle_reference_to_video(creds, arguments_json, allocator)
	}
	if name == "skill" {
		return skills.handle_skill_tool(skills.get_registry(), arguments_json, allocator)
	}
	if name == "search_tool" ||
	   name == "use_tool" ||
	   name == "list_mcp_resources" ||
	   name == "read_mcp_resource" ||
	   name == "list_mcp_prompts" ||
	   name == "get_mcp_prompt" {
		return mcp.handle_meta_tool(mcp.get_registry(), name, arguments_json, allocator)
	}
	if name == "web_search" {
		return web_search_from_args(creds, model, arguments_json, allocator)
	}
	if name == "web_fetch" {
		return web_fetch_from_args(arguments_json, allocator)
	}
	if name == "ask_user_question" {
		return ask_user_from_args(arguments_json, opts, allocator)
	}
	return tools.dispatch(name, arguments_json, opts.workspace, allocator)
}

approve_tool_interactive :: proc(name: string, summary: string, quiet: bool) -> core.Ask_Decision {
	if !terminal.is_terminal(os.stdin) {
		if !quiet {
			fmt.eprintf("aether: ask mode but stdin is not a TTY — denying %s\n", name)
		}
		return .Deny
	}
	s := summary
	if len(s) > 120 {
		s = s[:120]
	}
	if core.session_allow_enabled() {
		fmt.eprintf("aether: allow tool %s? %s [y/N/a=always/d=never session] ", name, s)
	} else {
		fmt.eprintf("aether: allow tool %s? %s [y/N] ", name, s)
	}
	line, ok := read_stdin_line(context.temp_allocator)
	if !ok {
		return .Deny
	}
	t := strings.to_lower(strings.trim_space(line), context.temp_allocator)
	if t == "y" || t == "yes" {
		return .Once
	}
	if (t == "a" || t == "always") && core.session_allow_enabled() {
		return .Always
	}
	if (t == "d" || t == "never") && core.session_allow_enabled() {
		return .Never
	}
	return .Deny
}

read_stdin_line :: proc(allocator := context.allocator) -> (string, bool) {
	// small blocking read until newline
	buf: [512]u8
	n, err := os.read(os.stdin, buf[:])
	if n <= 0 {
		_ = err
		return "", false
	}
	s := string(buf[:n])
	if i := strings.index_byte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return strings.clone(strings.trim_space(s), allocator), true
}

// run_tool_loop is the one-shot headless path: system + user, one agent turn, print result.
run_tool_loop :: proc(
	creds: Credentials,
	model: string,
	user_prompt: string,
	opts: Turn_Options,
) -> int {
	msgs := make([dynamic]Chat_Message, 0, 16)
	defer destroy_messages(msgs[:])

	if !allow_user_prompt(opts.workspace, user_prompt, opts.quiet) {
		return 1
	}

	append(
		&msgs,
		Chat_Message {
			role    = .System,
			content = build_system_prompt(
				opts.workspace,
				opts.permission_mode,
				context.allocator,
				skills_catalog_text(context.temp_allocator),
			),
		},
	)
	append(
		&msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone(user_prompt),
		},
	)

	text, code := run_agent_turn(creds, model, &msgs, opts)
	// B21: headless/REPL shared path also fires turn notify
	maybe_notify_agent_turn(code, "", text, opts.workspace)
	if code == 0 {
		delete(text)
	}
	return code
}

web_search_from_args :: proc(
	creds: Credentials,
	model: string,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !web_search_enabled() {
		return strings.clone("error: web_search disabled (AETHER_NO_WEB_SEARCH=1)", allocator)
	}
	val, err := json.parse(
		transmute([]byte)arguments_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return strings.clone("error: arguments must be object", allocator)
	}
	query, _ := json_str(obj, "query")
	if strings.trim_space(query) == "" {
		return strings.clone("error: query is required", allocator)
	}
	domains := make([dynamic]string, 0, 4, context.temp_allocator)
	if v, has := obj["allowed_domains"]; has {
		if arr, is_arr := v.(json.Array); is_arr {
			for item in arr {
				if s, is_s := item.(json.String); is_s {
					append(&domains, string(s))
				}
			}
		}
	}
	return web_search_via_responses(creds, model, query, domains[:], allocator)
}
