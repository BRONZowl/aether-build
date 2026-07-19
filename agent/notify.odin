package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:hooks"

// Test capture: when true, desktop_notify records instead of exec'ing.
g_notify_test_capture: bool
g_notify_last_title:   string
g_notify_last_body:    string
g_notify_call_count:   int

// env_buf reads an env var into a stack buffer (safe on worker threads; no temp_allocator).
env_buf :: proc(key: string) -> string {
	buf: [256]u8
	return strings.trim_space(os.get_env(buf[:], key))
}

// desktop_notify_enabled is false when explicitly disabled via env.
// Uses stack buffers — may run on bg worker threads without a valid temp arena.
desktop_notify_enabled :: proc() -> bool {
	if v := env_buf("AETHER_NO_DESKTOP_NOTIFY"); v == "1" || strings.equal_fold(v, "true") {
		return false
	}
	if v := env_buf("AETHER_NOTIFY"); v == "0" ||
	   strings.equal_fold(v, "false") ||
	   strings.equal_fold(v, "off") ||
	   strings.equal_fold(v, "none") {
		return false
	}
	return true
}

// notify_method_is reports whether AETHER_NOTIFY_METHOD equals name (case-insensitive).
// Empty env is treated as "auto".
notify_method_is :: proc(name: string) -> bool {
	v := env_buf("AETHER_NOTIFY_METHOD")
	if v == "" {
		return name == "auto"
	}
	return strings.equal_fold(v, name)
}

// format_bg_notify_title status → short title.
format_bg_notify_title :: proc(status: Bg_Task_Status) -> string {
	switch status {
	case .Completed:
		return "aether: bg done"
	case .Failed:
		return "aether: bg failed"
	case .Cancelled:
		return "aether: bg cancelled"
	case .Running:
		return "aether: bg"
	}
	return "aether: bg"
}

// format_bg_notify_body builds a short body for the notification.
format_bg_notify_body :: proc(
	task_id: string,
	description: string,
	status: Bg_Task_Status,
	allocator := context.allocator,
) -> string {
	desc := description
	if desc == "" {
		desc = "(no description)"
	}
	if len(desc) > 100 {
		desc = fmt.tprintf("%s…", desc[:97])
	}
	return fmt.aprintf(
		"%s · %s · %s",
		task_id,
		bg_status_string(status),
		desc,
		allocator = allocator,
	)
}

// desktop_notify best-effort OS/terminal notification. Safe from worker threads.
// External commands are backgrounded so finish paths never block on D-Bus.
desktop_notify :: proc(title, body: string) {
	if !desktop_notify_enabled() {
		return
	}
	if g_notify_test_capture {
		if g_notify_last_title != "" {
			delete(g_notify_last_title)
		}
		if g_notify_last_body != "" {
			delete(g_notify_last_body)
		}
		g_notify_last_title = strings.clone(title, context.allocator)
		g_notify_last_body = strings.clone(body, context.allocator)
		g_notify_call_count += 1
		return
	}

	if notify_method_is("none") {
		return
	}
	if notify_method_is("bel") {
		fmt.eprint("\a")
		return
	}
	if notify_method_is("osc9") {
		sb := sanitize_osc(body)
		defer delete(sb)
		fmt.eprintf("\x1b]9;%s\x07", sb)
		return
	}
	if notify_method_is("osc777") {
		st := sanitize_osc(title)
		sb := sanitize_osc(body)
		defer delete(st)
		defer delete(sb)
		fmt.eprintf("\x1b]777;notify;%s;%s\x07", st, sb)
		return
	}
	if notify_method_is("notify-send") || notify_method_is("auto") {
		// no-op without a session (CI/headless)
		if !desktop_session_available() {
			return
		}
		// Background + timeout: outer shell returns immediately
		// (notify-send must not block the agent or test runner).
		// Heap buffers — worker may lack a temp arena.
		qt := shell_quote(title)
		qb := shell_quote(body)
		defer delete(qt)
		defer delete(qb)
		script := fmt.aprintf(
			`(command -v notify-send >/dev/null 2>&1 && (command -v timeout >/dev/null 2>&1 && timeout 2 notify-send -a aether -- %s %s || notify-send -a aether -- %s %s) &) >/dev/null 2>&1`,
			qt,
			qb,
			qt,
			qb,
			allocator = context.allocator,
		)
		defer delete(script)
		state, _, _, err := os.process_exec({command = {"sh", "-c", script}}, context.allocator)
		_ = state
		_ = err
		return
	}

	// custom or unknown: support AETHER_NOTIFY_COMMAND
	cmd_buf: [1024]u8
	cmd := strings.trim_space(os.get_env(cmd_buf[:], "AETHER_NOTIFY_COMMAND"))
	if cmd != "" {
		_ = os.set_env("AETHER_NOTIFY_TITLE", title)
		_ = os.set_env("AETHER_NOTIFY_BODY", body)
		qc := shell_quote(cmd)
		defer delete(qc)
		script := fmt.aprintf(
			`(command -v timeout >/dev/null 2>&1 && timeout 2 sh -c %s || sh -c %s) >/dev/null 2>&1 &`,
			qc,
			qc,
			allocator = context.allocator,
		)
		defer delete(script)
		state, _, _, err := os.process_exec({command = {"sh", "-c", script}}, context.allocator)
		_ = state
		_ = err
	}
}

// desktop_session_available: only try notify-send when a display/session bus exists.
desktop_session_available :: proc() -> bool {
	if env_buf("DISPLAY") != "" {
		return true
	}
	if env_buf("WAYLAND_DISPLAY") != "" {
		return true
	}
	if env_buf("DBUS_SESSION_BUS_ADDRESS") != "" {
		return true
	}
	return false
}

// shell_quote / sanitize_osc use context.allocator (worker sets heap); callers must delete if needed.
// For the fire-and-forget notify path we pass them into a single aprintf that we free.
shell_quote :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '\'')
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == '\'' {
			strings.write_string(&b, `'\''`)
		} else {
			strings.write_byte(&b, ch)
		}
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

sanitize_osc :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == 0x1b || ch == 0x07 {
			continue
		}
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

// turn_notify_enabled: desktop notify when an agent turn finishes (B19).
// Off when desktop notify disabled, or AETHER_NOTIFY_TURNS=0/false/off/no.
turn_notify_enabled :: proc() -> bool {
	if !desktop_notify_enabled() {
		return false
	}
	if v := env_buf("AETHER_NOTIFY_TURNS"); v == "0" ||
	   strings.equal_fold(v, "false") ||
	   strings.equal_fold(v, "off") ||
	   strings.equal_fold(v, "no") ||
	   strings.equal_fold(v, "none") {
		return false
	}
	return true
}

// format_turn_notify_title maps run_agent_turn exit code → short title.
// 0 ok, 2 max turns, 4 cancel, else error.
format_turn_notify_title :: proc(code: int) -> string {
	switch code {
	case 0:
		return "aether: done"
	case 2:
		return "aether: max turns"
	case 4:
		return "aether: cancelled"
	}
	return "aether: error"
}

// format_turn_notify_body: session title + optional assistant preview.
format_turn_notify_body :: proc(
	session_title: string,
	preview: string,
	code: int,
	allocator := context.allocator,
) -> string {
	title := strings.trim_space(session_title)
	if title == "" {
		title = "(untitled)"
	}
	if len(title) > 60 {
		title = fmt.tprintf("%s…", title[:57])
	}
	pv := strings.trim_space(preview)
	// collapse newlines to spaces for notify body
	if strings.contains(pv, "\n") {
		pv, _ = strings.replace_all(pv, "\n", " ", context.temp_allocator)
	}
	if len(pv) > 120 {
		pv = fmt.tprintf("%s…", pv[:117])
	}
	if code == 0 {
		if pv != "" {
			return fmt.aprintf("%s · %s", title, pv, allocator = allocator)
		}
		return strings.clone(title, allocator)
	}
	if pv != "" {
		return fmt.aprintf("%s · %s", title, pv, allocator = allocator)
	}
	return fmt.aprintf("%s · exit %d", title, code, allocator = allocator)
}

// maybe_notify_agent_turn: desktop + Notification hooks after a parent turn (B19).
// Hooks fire even when turn desktop notify is disabled (same as bg path for hooks
// when desktop off — here we still run hooks if desktop notify master is on OR
// always run hooks for parity with permission prompts).
// Always runs Notification hooks; desktop gated by turn_notify_enabled.
maybe_notify_agent_turn :: proc(
	code: int,
	session_title: string,
	preview: string,
	cwd: string = "",
) {
	title := format_turn_notify_title(code)
	body := format_turn_notify_body(session_title, preview, code, context.allocator)
	level := "info"
	notif_type := "agent_turn_complete"
	switch code {
	case 0:
	case 2:
		level = "warning"
		notif_type = "agent_max_turns"
	case 4:
		level = "warning"
		notif_type = "agent_cancelled"
	case:
		level = "error"
		notif_type = "agent_error"
	}
	ws := cwd
	if ws == "" {
		ws = g_hooks_cwd if g_hooks_cwd != "" else "."
	}
	hooks.run_notification_hooks(ws, notif_type, body, title, level)

	if turn_notify_enabled() || g_notify_test_capture {
		desktop_notify(title, body)
	}
	delete(body)
}

// maybe_notify_bg_task fires desktop notify + Notification hooks for bg finishes.
// Background tasks use ids bash-* / sub-* that took a running slot (was_running_slot)
// or shell kind. Sync subagents also use sub-* but never call this if we only wire
// from bg worker finish paths.
// Avoid temp_allocator for desktop path — may run on a worker thread without a
// valid temp arena. Hook path uses temp_allocator (same as other hook call sites).
maybe_notify_bg_task :: proc(task: ^Bg_Task) {
	if task == nil {
		return
	}
	if task.status == .Running {
		return
	}
	title := format_bg_notify_title(task.status)
	body := format_bg_notify_body(task.id, task.description, task.status, context.allocator)
	// Notification hooks fire even when desktop notify is disabled.
	notif_type := "bg_task"
	level := "info"
	if task.task_kind == .Subagent {
		notif_type = "subagent_complete"
	}
	switch task.status {
	case .Failed:
		level = "error"
		notif_type = "agent_error" if task.task_kind != .Subagent else "subagent_complete"
	case .Cancelled:
		level = "warning"
	case .Completed, .Running:
	}
	cwd := task.worktree_path
	if cwd == "" {
		cwd = g_hooks_cwd if g_hooks_cwd != "" else "."
	}
	hooks.run_notification_hooks(cwd, notif_type, body, title, level)

	if !g_notify_test_capture && !desktop_notify_enabled() {
		delete(body)
		return
	}
	desktop_notify(title, body)
	delete(body)
}
