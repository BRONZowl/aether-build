package agent

// monitor tool — Grok-shaped stdout line events into parent chat (product Full).
// Reference: crates/codegen/xai-grok-tools/.../monitor/
// Session log under {sessions}/terminal/monitor-{id}.log; rate limit + line batch.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "aether:core"
import "aether:tools"

MONITOR_LINE_LIMIT :: 500
MONITOR_BATCH_LIMIT :: 3000
MONITOR_RESULT_CAP :: 200_000
MONITOR_DEFAULT_TIMEOUT_MS :: 36_000_000 // 10h
MONITOR_DEBOUNCE_MS :: 200
MONITOR_RATE_CAP :: 10
MONITOR_RATE_WINDOW_MS :: 2000

// monitor_enabled: opt-out AETHER_NO_MONITOR=1
monitor_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_MONITOR", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	return true
}

// sanitize_monitor_description: no quotes/newlines in event labels.
sanitize_monitor_description :: proc(desc: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(desc) {
		ch := desc[i]
		switch ch {
		case '"':
			strings.write_byte(&b, '\'')
		case '\n', '\r':
			strings.write_byte(&b, ' ')
		case:
			strings.write_byte(&b, ch)
		}
	}
	out := strings.to_string(b)
	if len(out) > 120 {
		trimmed := strings.clone(out[:120], allocator)
		delete(out)
		return trimmed
	}
	return out
}

truncate_monitor_line :: proc(line: string, allocator := context.allocator) -> string {
	if len(line) <= MONITOR_LINE_LIMIT {
		return strings.clone(line, allocator)
	}
	return fmt.aprintf("%s...(truncated)", line[:MONITOR_LINE_LIMIT], allocator = allocator)
}

batch_monitor_lines :: proc(lines: []string, allocator := context.allocator) -> string {
	if len(lines) == 0 {
		return strings.clone("", allocator)
	}
	joined := strings.join(lines, "\n", context.temp_allocator)
	if len(joined) <= MONITOR_BATCH_LIMIT {
		return strings.clone(joined, allocator)
	}
	return fmt.aprintf("%s\n...(truncated)", joined[:MONITOR_BATCH_LIMIT], allocator = allocator)
}

// resolve_monitor_timeout_ms: 0 = no deadline (persistent or explicit 0 with persistent).
resolve_monitor_timeout_ms :: proc(timeout_ms: int, persistent: bool) -> int {
	if persistent {
		return 0
	}
	if timeout_ms < 0 {
		return MONITOR_DEFAULT_TIMEOUT_MS
	}
	if timeout_ms == 0 {
		// omitted/zero without persistent → default 10h (Grok)
		return MONITOR_DEFAULT_TIMEOUT_MS
	}
	if timeout_ms > MONITOR_DEFAULT_TIMEOUT_MS {
		return MONITOR_DEFAULT_TIMEOUT_MS
	}
	return timeout_ms
}

// --- pending event queue ---

Monitor_Event :: struct {
	task_id:     string, // owned
	description: string, // owned
	body:        string, // owned
}

g_mon_ev_mu:   sync.Mutex
g_mon_events:  [dynamic]Monitor_Event
g_mon_rate_n:  int
g_mon_rate_t:  time.Time
g_mon_rate_id: string // task id of last rate-limit notice

monitor_events_ensure_heap :: proc() {
	raw := (^runtime.Raw_Dynamic_Array)(&g_mon_events)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	old := g_mon_events
	g_mon_events = make([dynamic]Monitor_Event, 0, max(8, len(old)), runtime.heap_allocator())
	for e in old {
		append(&g_mon_events, e)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

monitor_push_event :: proc(task_id, description, body: string) {
	if body == "" {
		return
	}
	sync.mutex_lock(&g_mon_ev_mu)
	defer sync.mutex_unlock(&g_mon_ev_mu)
	monitor_events_ensure_heap()
	// soft rate limit
	now := time.now()
	if g_mon_rate_n == 0 {
		g_mon_rate_t = now
	}
	if time.diff(g_mon_rate_t, now) >= MONITOR_RATE_WINDOW_MS * time.Millisecond {
		g_mon_rate_n = 0
		g_mon_rate_t = now
		g_mon_rate_id = ""
	}
	if g_mon_rate_n >= MONITOR_RATE_CAP {
		if g_mon_rate_id != task_id {
			// one notice per window per task
			append(
				&g_mon_events,
				Monitor_Event {
					task_id     = strings.clone(task_id, runtime.heap_allocator()),
					description = strings.clone(description, runtime.heap_allocator()),
					body        = strings.clone("…(rate limited)", runtime.heap_allocator()),
				},
			)
			g_mon_rate_id = task_id
		}
		return
	}
	g_mon_rate_n += 1
	append(
		&g_mon_events,
		Monitor_Event {
			task_id     = strings.clone(task_id, runtime.heap_allocator()),
			description = strings.clone(description, runtime.heap_allocator()),
			body        = strings.clone(body, runtime.heap_allocator()),
		},
	)
}

monitor_has_pending_events :: proc() -> bool {
	sync.mutex_lock(&g_mon_ev_mu)
	defer sync.mutex_unlock(&g_mon_ev_mu)
	return len(g_mon_events) > 0
}

// monitor_drain_events moves pending events to caller (owns strings).
// Queue storage is heap-allocated; free with heap_allocator (not context.allocator).
monitor_drain_events :: proc(allocator := context.allocator) -> []Monitor_Event {
	sync.mutex_lock(&g_mon_ev_mu)
	defer sync.mutex_unlock(&g_mon_ev_mu)
	if len(g_mon_events) == 0 {
		return {}
	}
	ha := runtime.heap_allocator()
	out := make([]Monitor_Event, len(g_mon_events), allocator)
	for e, i in g_mon_events {
		out[i] = Monitor_Event {
			task_id     = strings.clone(e.task_id, allocator),
			description = strings.clone(e.description, allocator),
			body        = strings.clone(e.body, allocator),
		}
		delete(e.task_id, ha)
		delete(e.description, ha)
		delete(e.body, ha)
	}
	clear(&g_mon_events)
	return out
}

destroy_monitor_events :: proc(events: []Monitor_Event) {
	for e in events {
		delete(e.task_id)
		delete(e.description)
		delete(e.body)
	}
	delete(events)
}

format_monitor_events_reminder :: proc(events: []Monitor_Event, allocator := context.allocator) -> string {
	if len(events) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "<system-reminder>\nMonitor event(s):\n")
	for e in events {
		fmt.sbprintf(
			&b,
			"\n[%s] task_id=%s\n%s\n",
			e.description if e.description != "" else "monitor",
			e.task_id,
			e.body,
		)
	}
	strings.write_string(&b, "</system-reminder>")
	return strings.to_string(b)
}

// maybe_inject_monitor_events drains line events into a user system-reminder.
maybe_inject_monitor_events :: proc(
	msgs: ^[dynamic]Chat_Message,
	allocator := context.allocator,
) -> bool {
	if g_subagent_depth != 0 {
		return false
	}
	events := monitor_drain_events(context.temp_allocator)
	if len(events) == 0 {
		return false
	}
	// re-clone for durable message
	owned := make([dynamic]Monitor_Event, 0, len(events), context.temp_allocator)
	for e in events {
		append(
			&owned,
			Monitor_Event {
				task_id     = e.task_id,
				description = e.description,
				body        = e.body,
			},
		)
	}
	text := format_monitor_events_reminder(owned[:], allocator)
	if text == "" {
		return false
	}
	append(msgs, Chat_Message{role = .User, content = text})
	return true
}

// --- spawn + worker ---

Bg_Monitor_Work :: struct {
	task:       ^Bg_Task,
	command:    string,
	workspace:  string,
	timeout_ms: int,
	log_path:   string, // owned; session terminal log
	allocator:  runtime.Allocator,
}

// monitor_log_path: {sessions}/terminal/monitor-{id}.log (or AETHER_MONITOR_DIR).
monitor_log_path :: proc(task_id: string, allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_MONITOR_DIR", context.temp_allocator); v != "" {
		_ = core.ensure_dir(v)
		p, _ := filepath.join({v, fmt.tprintf("monitor-%s.log", task_id)}, allocator)
		return p
	}
	base := core.aether_sessions_dir("", context.temp_allocator)
	dir, _ := filepath.join({base, "terminal"}, context.temp_allocator)
	_ = core.ensure_dir(dir)
	p, _ := filepath.join({dir, fmt.tprintf("monitor-%s.log", task_id)}, allocator)
	return p
}

handle_monitor :: proc(
	arguments_json: string,
	opts: Turn_Options,
	allocator := context.allocator,
) -> string {
	if !monitor_enabled() {
		return strings.clone("error: monitor disabled (AETHER_NO_MONITOR=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	command := strings.trim_space(tools.jstr(obj, "command"))
	if command == "" {
		return strings.clone("error: command is required", allocator)
	}
	desc_raw := tools.jstr(obj, "description")
	if strings.trim_space(desc_raw) == "" {
		return strings.clone("error: description is required", allocator)
	}
	persistent := tools.jbool(obj, "persistent", false)
	timeout_in := -1
	if _, has := obj["timeout_ms"]; has {
		timeout_in = tools.jint(obj, "timeout_ms", 0)
	}
	timeout_ms := resolve_monitor_timeout_ms(timeout_in, persistent)
	desc := sanitize_monitor_description(desc_raw, context.temp_allocator)

	if !bg_try_begin() {
		return fmt.aprintf(
			"error: max concurrent background tasks (%d) reached; wait or kill_task",
			MAX_BG_TASKS,
			allocator = allocator,
		)
	}

	id := generate_bg_task_id("monitor", context.allocator)
	task := new(Bg_Task)
	task.id = id
	task.task_kind = .Monitor
	task.description = strings.clone(desc, context.allocator)
	task.status = .Running
	task.result = ""
	task.cancel = false
	task.has_process = false
	task.delivered = false

	bg_tasks_ensure_heap()
	sync.mutex_lock(&g_bg_mu)
	append(&g_bg_tasks, task)
	sync.mutex_unlock(&g_bg_mu)

	log_path := monitor_log_path(id, context.allocator)

	work := new(Bg_Monitor_Work)
	work.task = task
	work.command = strings.clone(command, context.allocator)
	work.workspace = strings.clone(opts.workspace, context.allocator)
	work.timeout_ms = timeout_ms
	work.log_path = strings.clone(log_path, context.allocator)
	work.allocator = context.allocator

	_ = thread.create_and_start_with_poly_data(work, bg_monitor_worker_proc, nil, .Normal, true)

	preview := command
	if len(preview) > 120 {
		preview = preview[:120]
	}
	if persistent || timeout_ms == 0 {
		return fmt.aprintf(
			"Monitor started (task_id: %s, persistent — runs until kill_task or process exit).\ndescription: %s\ncommand: %s\nlog: %s\n\nStdout lines stream as system-reminders. Use kill_task to stop; get_task_output or read_file on the log for full output.",
			id,
			desc,
			preview,
			log_path,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"Monitor started (task_id: %s, timeout %dms).\ndescription: %s\ncommand: %s\nlog: %s\n\nStdout lines stream as system-reminders. Use kill_task to stop; get_task_output or read_file on the log for full output.",
		id,
		timeout_ms,
		desc,
		preview,
		log_path,
		allocator = allocator,
	)
}

bg_monitor_worker_proc :: proc(work: ^Bg_Monitor_Work) {
	task := work.task
	command := work.command
	workspace := work.workspace
	timeout_ms := work.timeout_ms
	alloc := work.allocator
	if alloc.procedure == nil {
		alloc = context.allocator
	}
	context.allocator = alloc

	stdout_r, stdout_w, perr := os.pipe()
	if perr != nil {
		bg_finish_shell(task, .Failed, fmt.aprintf("error: pipe stdout: %v", perr, allocator = alloc))
		bg_free_monitor_work(work)
		return
	}
	stderr_r, stderr_w, perr2 := os.pipe()
	if perr2 != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		bg_finish_shell(task, .Failed, fmt.aprintf("error: pipe stderr: %v", perr2, allocator = alloc))
		bg_free_monitor_work(work)
		return
	}

	child, serr := os.process_start(
		{
			command     = {"sh", "-c", command},
			working_dir = workspace,
			stdout      = stdout_w,
			stderr      = stderr_w,
		},
	)
	os.close(stdout_w)
	os.close(stderr_w)
	if serr != nil {
		os.close(stdout_r)
		os.close(stderr_r)
		bg_finish_shell(task, .Failed, fmt.aprintf("error: failed to start: %v", serr, allocator = alloc))
		bg_free_monitor_work(work)
		return
	}

	sync.mutex_lock(&g_bg_mu)
	task.process = child
	task.has_process = true
	sync.mutex_unlock(&g_bg_mu)

	// line buffering
	line_buf := make([dynamic]byte, 0, 256, alloc)
	defer delete(line_buf)
	pending_lines := make([dynamic]string, 0, 8, alloc)
	defer {
		for s in pending_lines {
			delete(s)
		}
		delete(pending_lines)
	}
	full_log := make([dynamic]byte, 0, 4096, alloc)
	defer delete(full_log)

	last_flush := time.now()
	start_t := time.now()
	timeout_dur := time.Duration(timeout_ms) * time.Millisecond
	stdout_done := false
	stderr_done := false
	timed_out := false
	cancelled := false
	exit_code := 0
	buf: [4096]u8

	flush_batch :: proc(
		task: ^Bg_Task,
		pending: ^[dynamic]string,
		alloc: runtime.Allocator,
	) {
		if len(pending) == 0 {
			return
		}
		body := batch_monitor_lines(pending[:], alloc)
		monitor_push_event(task.id, task.description, body)
		delete(body)
		for s in pending {
			delete(s)
		}
		clear(pending)
	}

	append_log :: proc(log: ^[dynamic]byte, data: []byte) {
		append(log, ..data)
		// cap tail
		if len(log) > MONITOR_RESULT_CAP {
			keep := MONITOR_RESULT_CAP / 2
			// drop head
			copy(log[:keep], log[len(log) - keep:])
			resize(log, keep)
		}
	}

	push_chunk :: proc(
		task: ^Bg_Task,
		line_buf: ^[dynamic]byte,
		pending: ^[dynamic]string,
		full_log: ^[dynamic]byte,
		chunk: []byte,
		alloc: runtime.Allocator,
	) {
		append_log(full_log, chunk)
		for b in chunk {
			if b == '\n' {
				line := strings.trim_space(string(line_buf[:]))
				clear(line_buf)
				if line == "" {
					continue
				}
				tl := truncate_monitor_line(line, alloc)
				append(pending, tl)
			} else if b != '\r' {
				append(line_buf, b)
			}
		}
	}

	for !stdout_done || !stderr_done {
		if task.cancel {
			cancelled = true
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, 2 * time.Second)
			// drain
			for !stdout_done {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					push_chunk(task, &line_buf, &pending_lines, &full_log, buf[:n], alloc)
				}
				if rerr != nil || n == 0 {
					stdout_done = true
				}
			}
			for !stderr_done {
				n, rerr := os.read(stderr_r, buf[:])
				if n > 0 {
					append_log(&full_log, buf[:n])
				}
				if rerr != nil || n == 0 {
					stderr_done = true
				}
			}
			break
		}

		if !stdout_done {
			has, _ := os.pipe_has_data(stdout_r)
			if has {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					push_chunk(task, &line_buf, &pending_lines, &full_log, buf[:n], alloc)
				}
				if rerr == .EOF || rerr == .Broken_Pipe {
					stdout_done = true
				}
			}
		}
		if !stderr_done {
			has, _ := os.pipe_has_data(stderr_r)
			if has {
				n, rerr := os.read(stderr_r, buf[:])
				if n > 0 {
					append_log(&full_log, buf[:n])
				}
				if rerr == .EOF || rerr == .Broken_Pipe {
					stderr_done = true
				}
			}
		}

		// debounce flush
		if len(pending_lines) > 0 &&
		   time.diff(last_flush, time.now()) >= MONITOR_DEBOUNCE_MS * time.Millisecond {
			flush_batch(task, &pending_lines, alloc)
			last_flush = time.now()
		} else if len(pending_lines) >= 8 {
			flush_batch(task, &pending_lines, alloc)
			last_flush = time.now()
		}

		state, werr := os.process_wait(child, 0)
		if werr == nil && state.exited {
			exit_code = state.exit_code
			for !stdout_done {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					push_chunk(task, &line_buf, &pending_lines, &full_log, buf[:n], alloc)
				}
				if rerr != nil || n == 0 {
					stdout_done = true
				}
			}
			for !stderr_done {
				n, rerr := os.read(stderr_r, buf[:])
				if n > 0 {
					append_log(&full_log, buf[:n])
				}
				if rerr != nil || n == 0 {
					stderr_done = true
				}
			}
			break
		}

		if timeout_ms > 0 && time.diff(start_t, time.now()) >= timeout_dur {
			timed_out = true
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, 2 * time.Second)
			break
		}
		time.sleep(10 * time.Millisecond)
	}

	// flush remainder
	if len(line_buf) > 0 {
		line := strings.trim_space(string(line_buf[:]))
		if line != "" {
			tl := truncate_monitor_line(line, alloc)
			append(&pending_lines, tl)
		}
	}
	flush_batch(task, &pending_lines, alloc)

	os.close(stdout_r)
	os.close(stderr_r)

	sync.mutex_lock(&g_bg_mu)
	task.has_process = false
	sync.mutex_unlock(&g_bg_mu)

	log_s := string(full_log[:])
	// Persist full log under session terminal/ for read_file recovery
	if work.log_path != "" {
		if dir := filepath.dir(work.log_path); dir != "" {
			_ = core.ensure_dir(dir)
		}
		_ = os.write_entire_file(work.log_path, full_log[:])
	}
	capped := tools.cap_output(log_s, MONITOR_RESULT_CAP, alloc)

	status: Bg_Task_Status
	result: string
	log_hint := ""
	if work.log_path != "" {
		log_hint = fmt.tprintf("\n\nFull log: %s", work.log_path)
	}
	if cancelled || task.cancel {
		status = .Cancelled
		result = fmt.aprintf("monitor cancelled:\n\n%s%s", capped, log_hint, allocator = alloc)
		delete(capped)
	} else if timed_out {
		status = .Failed
		result = fmt.aprintf("monitor timed out:\n\n%s%s", capped, log_hint, allocator = alloc)
		delete(capped)
	} else if exit_code != 0 {
		status = .Failed
		result = fmt.aprintf("%s%s", capped, log_hint, allocator = alloc)
		delete(capped)
	} else {
		status = .Completed
		result = fmt.aprintf("%s%s", capped, log_hint, allocator = alloc)
		delete(capped)
	}

	bg_finish_shell(task, status, result)
	bg_free_monitor_work(work)
}

bg_free_monitor_work :: proc(work: ^Bg_Monitor_Work) {
	delete(work.command)
	delete(work.workspace)
	delete(work.log_path)
	free(work)
}
