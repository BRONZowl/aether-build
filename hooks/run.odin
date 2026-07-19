package hooks

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "aether:core"

MAX_HOOK_STDOUT :: 64 * 1024
DENY_EXIT_CODE :: 2

// build_pre_tool_envelope minimal JSON for PreToolUse.
build_pre_tool_envelope :: proc(
	cwd, tool_name, tool_input_json: string,
	allocator := context.allocator,
) -> string {
	inp := tool_input_json
	if inp == "" {
		inp = "{}"
	}
	if len(inp) > 8000 {
		inp = inp[:8000]
	}
	// If tool_input is already JSON object/array, embed raw; else string-escape.
	embed := inp
	trimmed := strings.trim_space(inp)
	if len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[') {
		// raw
	} else {
		embed = fmt.tprintf(`"%s"`, json_escape(inp, context.temp_allocator))
	}
	return fmt.aprintf(
		`{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"%s","tool_input":%s}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(tool_name, context.temp_allocator),
		embed,
		allocator = allocator,
	)
}

build_session_start_envelope :: proc(cwd: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		`{"hook_event_name":"SessionStart","cwd":"%s"}`,
		json_escape(cwd, context.temp_allocator),
		allocator = allocator,
	)
}

// json_escape: shared core helper (control → \u00xx).
json_escape :: proc(s: string, allocator := context.allocator) -> string {
	return core.json_string_escape(s, allocator)
}

// needs_shell true if command needs sh -c.
needs_shell :: proc(cmd: string) -> bool {
	for i in 0 ..< len(cmd) {
		switch cmd[i] {
		case ' ', '|', '&', ';', '>', '<', '$', '`':
			return true
		}
	}
	return strings.has_prefix(cmd, "~")
}

// resolve_command path: relative to source_dir if not absolute.
resolve_command :: proc(spec: Hook_Spec, allocator := context.allocator) -> string {
	cmd := spec.command
	if cmd == "" {
		return ""
	}
	if os.is_absolute_path(cmd) {
		return strings.clone(cmd, allocator)
	}
	// shell commands keep as-is for sh -c
	if needs_shell(cmd) {
		return strings.clone(cmd, allocator)
	}
	// relative to hook file directory
	if spec.source_dir != "" {
		joined, _ := filepath.join({spec.source_dir, cmd}, allocator)
		return joined
	}
	return strings.clone(cmd, allocator)
}

// parse_decision_from_stdout: look for "decision":"deny" or allow.
parse_decision_from_stdout :: proc(stdout: string) -> (Hook_Decision, string /* reason */) {
	lower := strings.to_lower(stdout, context.temp_allocator)
	if strings.contains(lower, `"decision":"deny"`) || strings.contains(lower, `"decision": "deny"`) {
		reason := "hook denied"
		// crude reason extract
		if idx := strings.index(lower, `"reason"`); idx >= 0 {
			// find next quote pair in original — best-effort
			rest := stdout[idx:]
			if q1 := strings.index(rest, `"`); q1 >= 0 {
				// skip "reason"
			}
		}
		if strings.contains(stdout, `"reason":"`) {
			if p := strings.index(stdout, `"reason":"`); p >= 0 {
				start := p + len(`"reason":"`)
				if end := strings.index_byte(stdout[start:], '"'); end >= 0 {
					reason = stdout[start:start + end]
				}
			}
		}
		return .Deny, reason
	}
	return .Allow, ""
}

// run_hook dispatches command or HTTP handler (A4.7).
run_hook :: proc(
	spec: Hook_Spec,
	envelope_json: string,
	blocking: bool,
) -> (
	decision: Hook_Decision,
	reason: string,
	exit_code: int,
) {
	if spec.kind == .Http {
		return run_hook_http(spec, envelope_json, blocking)
	}
	return run_hook_command(spec, envelope_json, blocking)
}

// run_hook_command executes one command hook; fail-open on errors.
run_hook_command :: proc(
	spec: Hook_Spec,
	envelope_json: string,
	blocking: bool,
) -> (
	decision: Hook_Decision,
	reason: string,
	exit_code: int,
) {
	decision = .Allow
	cmd_path := resolve_command(spec, context.temp_allocator)
	if cmd_path == "" {
		return .Allow, "", 0
	}

	timeout_s := spec.timeout_s
	if timeout_s <= 0 {
		timeout_s = 5
	}

	argv: []string
	if needs_shell(spec.command) {
		// cd to source_dir then run
		script := spec.command
		if spec.source_dir != "" {
			script = fmt.tprintf("cd %s && %s", shell_quote(spec.source_dir), spec.command)
		}
		argv = []string{"sh", "-c", script}
	} else {
		argv = []string{cmd_path}
	}

	stdin_r, stdin_w, e1 := os.pipe()
	if e1 != nil {
		return .Allow, "", 0 // fail-open
	}
	stdout_r, stdout_w, e2 := os.pipe()
	if e2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return .Allow, "", 0
	}

	child, serr := os.process_start(
		{
			command = argv,
			stdin   = stdin_r,
			stdout  = stdout_w,
		},
	)
	os.close(stdin_r)
	os.close(stdout_w)
	if serr != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		return .Allow, "", 0
	}

	// Write envelope + close stdin
	_, _ = os.write(stdin_w, transmute([]byte)envelope_json)
	os.close(stdin_w)

	// Read stdout with cap
	stdout_buf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	tmp := make([]byte, 4096, context.temp_allocator)
	for {
		n, rerr := os.read(stdout_r, tmp)
		if n > 0 {
			end := n
			if len(stdout_buf) + end > MAX_HOOK_STDOUT {
				end = MAX_HOOK_STDOUT - len(stdout_buf)
			}
			if end > 0 {
				append(&stdout_buf, ..tmp[:end])
			}
			if len(stdout_buf) >= MAX_HOOK_STDOUT {
				break
			}
		}
		if rerr != nil || n == 0 {
			break
		}
	}
	os.close(stdout_r)

	timeout_dur := time.Duration(timeout_s) * time.Second
	state, werr := os.process_wait(child, timeout_dur)
	if werr != nil {
		// timeout or error — kill and fail-open
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 2 * time.Second)
		return .Allow, "", -1
	}
	exit_code = int(state.exit_code)
	stdout_s := string(stdout_buf[:])

	if blocking {
		if exit_code == DENY_EXIT_CODE {
			dec, why := parse_decision_from_stdout(stdout_s)
			if why == "" {
				why = "hook exit code 2"
			}
			if dec == .Deny || true {
				return .Deny, why, exit_code
			}
		}
		dec, why := parse_decision_from_stdout(stdout_s)
		if dec == .Deny {
			return .Deny, why if why != "" else "hook denied", exit_code
		}
	}
	return .Allow, "", exit_code
}

shell_quote :: proc(s: string) -> string {
	// single-quote wrap with escape
	return fmt.tprintf("'%s'", strings.replace_all(s, "'", `'"'"'`, context.temp_allocator))
}

// run_pre_tool_hooks runs all matching PreToolUse hooks; first Deny wins.
run_pre_tool_hooks :: proc(
	cwd, tool_name, tool_input_json: string,
) -> (
	decision: Hook_Decision,
	reason: string,
) {
	if !hooks_enabled() {
		return .Allow, ""
	}
	r := get_registry()
	if r == nil || len(r.specs) == 0 {
		return .Allow, ""
	}
	specs := specs_for(r, .Pre_Tool_Use, tool_name, context.temp_allocator)
	if len(specs) == 0 {
		return .Allow, ""
	}
	env := build_pre_tool_envelope(cwd, tool_name, tool_input_json, context.temp_allocator)
	for s in specs {
		dec, why, _ := run_hook(s, env, true)
		if dec == .Deny {
			return .Deny, why if why != "" else s.name
		}
	}
	return .Allow, ""
}

// run_session_start_hooks non-blocking fail-open.
run_session_start_hooks :: proc(cwd: string) {
	if !hooks_enabled() {
		return
	}
	r := get_registry()
	if r == nil || len(r.specs) == 0 {
		return
	}
	specs := specs_for(r, .Session_Start, "", context.temp_allocator)
	env := build_session_start_envelope(cwd, context.temp_allocator)
	for s in specs {
		_, _, _ = run_hook(s, env, false)
	}
}

// build_post_tool_envelope for PostToolUse / PostToolUseFailure.
build_post_tool_envelope :: proc(
	event_name, cwd, tool_name, tool_input_json, tool_result: string,
	is_error: bool,
	allocator := context.allocator,
) -> string {
	inp := tool_input_json
	if inp == "" {
		inp = "{}"
	}
	if len(inp) > 8000 {
		inp = inp[:8000]
	}
	embed := inp
	trimmed := strings.trim_space(inp)
	if len(trimmed) == 0 || (trimmed[0] != '{' && trimmed[0] != '[') {
		embed = fmt.tprintf(`"%s"`, json_escape(inp, context.temp_allocator))
	}
	res := tool_result
	if len(res) > 4000 {
		res = res[:4000]
	}
	err_s := "false"
	if is_error {
		err_s = "true"
	}
	return fmt.aprintf(
		`{"hook_event_name":"%s","cwd":"%s","tool_name":"%s","tool_input":%s,"tool_result":"%s","is_error":%s}`,
		json_escape(event_name, context.temp_allocator),
		json_escape(cwd, context.temp_allocator),
		json_escape(tool_name, context.temp_allocator),
		embed,
		json_escape(res, context.temp_allocator),
		err_s,
		allocator = allocator,
	)
}

build_reason_envelope :: proc(
	event_name, cwd, reason: string,
	allocator := context.allocator,
) -> string {
	return fmt.aprintf(
		`{"hook_event_name":"%s","cwd":"%s","reason":"%s"}`,
		json_escape(event_name, context.temp_allocator),
		json_escape(cwd, context.temp_allocator),
		json_escape(reason, context.temp_allocator),
		allocator = allocator,
	)
}

// run_event_hooks non-blocking for all specs of event (optional tool matcher).
run_event_hooks :: proc(event: Hook_Event, envelope: string, tool_name: string = "") {
	if !hooks_enabled() {
		return
	}
	r := get_registry()
	if r == nil || len(r.specs) == 0 {
		return
	}
	specs := specs_for(r, event, tool_name, context.temp_allocator)
	for s in specs {
		_, _, _ = run_hook(s, envelope, false)
	}
}

// run_post_tool_hooks fires PostToolUse or PostToolUseFailure (non-blocking).
run_post_tool_hooks :: proc(
	cwd, tool_name, tool_input_json, tool_result: string,
	is_error: bool,
) {
	ev: Hook_Event = .Post_Tool_Use
	name := "PostToolUse"
	if is_error {
		ev = .Post_Tool_Use_Failure
		name = "PostToolUseFailure"
	}
	env := build_post_tool_envelope(
		name,
		cwd,
		tool_name,
		tool_input_json,
		tool_result,
		is_error,
		context.temp_allocator,
	)
	run_event_hooks(ev, env, tool_name)
}

// run_stop_hooks non-blocking (end of agent turn).
run_stop_hooks :: proc(cwd: string, reason: string = "completed") {
	env := build_reason_envelope("Stop", cwd, reason, context.temp_allocator)
	run_event_hooks(.Stop, env, "")
}

// run_session_end_hooks once per process (latch).
run_session_end_hooks :: proc(cwd: string, reason: string = "exit") {
	if g_session_end_fired {
		return
	}
	g_session_end_fired = true
	if !hooks_enabled() {
		return
	}
	env := build_reason_envelope("SessionEnd", cwd, reason, context.temp_allocator)
	run_event_hooks(.Session_End, env, "")
}

// run_user_prompt_submit_hooks may block the turn (exit 2 / decision deny).
run_user_prompt_submit_hooks :: proc(
	cwd, prompt: string,
) -> (
	decision: Hook_Decision,
	reason: string,
) {
	if !hooks_enabled() {
		return .Allow, ""
	}
	r := get_registry()
	if r == nil || len(r.specs) == 0 {
		return .Allow, ""
	}
	specs := specs_for(r, .User_Prompt_Submit, "", context.temp_allocator)
	if len(specs) == 0 {
		return .Allow, ""
	}
	p := prompt
	if len(p) > 4000 {
		p = p[:4000]
	}
	env := fmt.aprintf(
		`{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"%s"}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(p, context.temp_allocator),
		allocator = context.temp_allocator,
	)
	for s in specs {
		dec, why, _ := run_hook(s, env, true)
		if dec == .Deny {
			return .Deny, why if why != "" else s.name
		}
	}
	return .Allow, ""
}

// run_permission_denied_hooks non-blocking (permission/ask denials only).
run_permission_denied_hooks :: proc(
	cwd, tool_name, tool_input_json, reason: string,
) {
	if !hooks_enabled() {
		return
	}
	r := get_registry()
	if r == nil || len(r.specs) == 0 {
		return
	}
	inp := tool_input_json
	if inp == "" {
		inp = "{}"
	}
	if len(inp) > 8000 {
		inp = inp[:8000]
	}
	embed := inp
	trimmed := strings.trim_space(inp)
	if len(trimmed) == 0 || (trimmed[0] != '{' && trimmed[0] != '[') {
		embed = fmt.tprintf(`"%s"`, json_escape(inp, context.temp_allocator))
	}
	env := fmt.aprintf(
		`{"hook_event_name":"PermissionDenied","cwd":"%s","tool_name":"%s","tool_input":%s,"reason":"%s"}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(tool_name, context.temp_allocator),
		embed,
		json_escape(reason, context.temp_allocator),
		allocator = context.temp_allocator,
	)
	// Matcher optional on tool name
	specs := specs_for(r, .Permission_Denied, tool_name, context.temp_allocator)
	for s in specs {
		_, _, _ = run_hook(s, env, false)
	}
}

// run_subagent_start_hooks non-blocking.
run_subagent_start_hooks :: proc(
	cwd, subagent_type, description: string,
	background: bool,
) {
	bg := "false"
	if background {
		bg = "true"
	}
	env := fmt.aprintf(
		`{"hook_event_name":"SubagentStart","cwd":"%s","subagent_type":"%s","description":"%s","background":%s}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(subagent_type, context.temp_allocator),
		json_escape(description, context.temp_allocator),
		bg,
		allocator = context.temp_allocator,
	)
	run_event_hooks(.Subagent_Start, env, "")
}

// run_subagent_stop_hooks non-blocking.
run_subagent_stop_hooks :: proc(
	cwd, subagent_type, task_id, status: string,
	exit_code: int,
) {
	env := fmt.aprintf(
		`{"hook_event_name":"SubagentStop","cwd":"%s","subagent_type":"%s","task_id":"%s","status":"%s","exit_code":%d}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(subagent_type, context.temp_allocator),
		json_escape(task_id, context.temp_allocator),
		json_escape(status, context.temp_allocator),
		exit_code,
		allocator = context.temp_allocator,
	)
	run_event_hooks(.Subagent_Stop, env, "")
}

// run_pre_compact_hooks non-blocking.
run_pre_compact_hooks :: proc(cwd, mode: string, message_count: int) {
	env := fmt.aprintf(
		`{"hook_event_name":"PreCompact","cwd":"%s","mode":"%s","message_count":%d}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(mode, context.temp_allocator),
		message_count,
		allocator = context.temp_allocator,
	)
	run_event_hooks(.Pre_Compact, env, "")
}

// run_post_compact_hooks non-blocking.
run_post_compact_hooks :: proc(
	cwd, mode: string,
	before, after: int,
	ok: bool,
) {
	ok_s := "false"
	if ok {
		ok_s = "true"
	}
	env := fmt.aprintf(
		`{"hook_event_name":"PostCompact","cwd":"%s","mode":"%s","message_count":%d,"message_count_after":%d,"ok":%s}`,
		json_escape(cwd, context.temp_allocator),
		json_escape(mode, context.temp_allocator),
		before,
		after,
		ok_s,
		allocator = context.temp_allocator,
	)
	run_event_hooks(.Post_Compact, env, "")
}

// run_notification_hooks non-blocking. Matcher is tested against notification_type
// (Grok: permission_prompt, agent_error, bg_task, …).
run_notification_hooks :: proc(
	cwd, notification_type, message, title, level: string,
) {
	if !hooks_enabled() {
		return
	}
	r := get_registry()
	if r == nil || len(r.specs) == 0 {
		return
	}
	nt := notification_type if notification_type != "" else "info"
	msg := message
	if len(msg) > 4000 {
		msg = msg[:4000]
	}
	ttl := title
	if len(ttl) > 500 {
		ttl = ttl[:500]
	}
	lvl := level
	env := fmt.aprintf(
		`{"hook_event_name":"Notification","cwd":"%s","notificationType":"%s","message":"%s","title":"%s","level":"%s"}`,
		json_escape(cwd if cwd != "" else ".", context.temp_allocator),
		json_escape(nt, context.temp_allocator),
		json_escape(msg, context.temp_allocator),
		json_escape(ttl, context.temp_allocator),
		json_escape(lvl, context.temp_allocator),
		allocator = context.temp_allocator,
	)
	// Matcher on notification_type (same path as tool-name matchers).
	specs := specs_for(r, .Notification, nt, context.temp_allocator)
	for s in specs {
		_, _, _ = run_hook(s, env, false)
	}
}
