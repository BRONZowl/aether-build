package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "aether:core"
import "aether:hooks"
import "aether:tools"

MAX_BG_TASKS :: 2
// Keep old name as alias for readability in comments/tests
MAX_BG_SUBAGENTS :: MAX_BG_TASKS
// Soft cap on terminal subagent transcripts kept for resume_from (running tasks uncapped by this).
MAX_SUBAGENT_ARCHIVES :: 32
// Inline body size in auto-wake / mid-turn completion reminders.
MAX_INLINE_COMPLETION :: 4000

Bg_Task_Status :: enum {
	Running,
	Completed,
	Failed,
	Cancelled,
}

Bg_Task_Kind :: enum {
	Subagent,
	Shell,
	Monitor,
}

Bg_Task :: struct {
	id:          string,
	task_kind:   Bg_Task_Kind,
	sub_type:    Subagent_Type, // valid when task_kind == Subagent
	description: string,
	status:      Bg_Task_Status,
	result:      string,
	cancel:      bool,
	process:     os.Process,
	has_process: bool,
	// Transcript for resume_from (subagents only; empty for shell).
	msgs:        [dynamic]Chat_Message,
	model:       string, // model used for this run (resume may pin)
	// Parent auto-wake / mid-turn reminder already delivered this completion.
	delivered:   bool,
	// Isolated git worktree path when isolation=worktree (empty = parent workspace).
	worktree_path: string,
}

// Snapshot of a terminal task for auto-wake formatting (caller owns strings).
Bg_Completion :: struct {
	id:          string,
	task_kind:   Bg_Task_Kind,
	sub_type:    Subagent_Type,
	status:      Bg_Task_Status,
	description: string,
	result:      string,
}

Bg_Work :: struct {
	task:                 ^Bg_Task,
	creds:                Credentials,
	model:                string,
	prompt:               string,
	workspace:            string,
	kind:                 Subagent_Type,
	mcp_enabled:          bool,
	skills_enabled:       bool,
	max_turns:            int,
	// When set, worker resumes from these messages (takes ownership; freed after clone into run).
	seed_msgs:            [dynamic]Chat_Message,
	has_seed:             bool,
	persona_instructions: string, // owned; empty = none (M9)
}

Bg_Shell_Work :: struct {
	task:       ^Bg_Task,
	command:    string,
	workspace:  string,
	timeout_ms: int, // 0 = no timeout
	log_path:   string, // owned; session terminal/bash-{id}.log
	allocator:  runtime.Allocator, // parent heap — avoid thread default/temp mismatch
}

// bash_log_path: {sessions}/terminal/bash-{id}.log (or AETHER_BASH_LOG_DIR).
bash_log_path :: proc(task_id: string, allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_BASH_LOG_DIR", context.temp_allocator); v != "" {
		_ = core.ensure_dir(v)
		p, _ := filepath.join({v, fmt.tprintf("bash-%s.log", task_id)}, allocator)
		return p
	}
	base := core.aether_sessions_dir("", context.temp_allocator)
	dir, _ := filepath.join({base, "terminal"}, context.temp_allocator)
	_ = core.ensure_dir(dir)
	p, _ := filepath.join({dir, fmt.tprintf("bash-%s.log", task_id)}, allocator)
	return p
}

g_bg_mu:      sync.Mutex
g_bg_tasks:   [dynamic]^Bg_Task
g_bg_running: int
g_bg_counter: int
g_depth_mu:   sync.Mutex // protects g_subagent_depth across threads

// Ensure g_bg_tasks grows on the process heap, not the per-test rollback allocator.
// Zero-value [dynamic] uses context.allocator on first reserve — that memory is
// rewound when a test ends, leaving a dangling data pointer for the next test.
bg_tasks_ensure_heap :: proc() {
	sync.mutex_lock(&g_bg_mu)
	defer sync.mutex_unlock(&g_bg_mu)
	raw := (^runtime.Raw_Dynamic_Array)(&g_bg_tasks)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	// Migrate any existing entries (rare: first use path).
	old := g_bg_tasks
	g_bg_tasks = make([dynamic]^Bg_Task, 0, max(8, len(old)), runtime.heap_allocator())
	for t in old {
		append(&g_bg_tasks, t)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

bg_status_string :: proc(s: Bg_Task_Status) -> string {
	switch s {
	case .Running:
		return "running"
	case .Completed:
		return "completed"
	case .Failed:
		return "failed"
	case .Cancelled:
		return "cancelled"
	}
	return "unknown"
}

clone_credentials :: proc(c: Credentials, allocator := context.allocator) -> Credentials {
	return Credentials {
		kind           = c.kind,
		bearer         = strings.clone(c.bearer, allocator),
		base_url       = strings.clone(c.base_url, allocator),
		user_id        = strings.clone(c.user_id, allocator),
		email          = strings.clone(c.email, allocator),
		scope          = strings.clone(c.scope, allocator),
		refresh_token  = strings.clone(c.refresh_token, allocator),
		expires_at     = strings.clone(c.expires_at, allocator),
		oidc_issuer    = strings.clone(c.oidc_issuer, allocator),
		oidc_client_id = strings.clone(c.oidc_client_id, allocator),
		principal_type = strings.clone(c.principal_type, allocator),
		principal_id   = strings.clone(c.principal_id, allocator),
		auth_path      = strings.clone(c.auth_path, allocator),
	}
}

generate_bg_task_id :: proc(prefix: string, allocator := context.allocator) -> string {
	sync.mutex_lock(&g_bg_mu)
	g_bg_counter += 1
	n := g_bg_counter
	sync.mutex_unlock(&g_bg_mu)
	p := prefix if prefix != "" else "task"
	return fmt.aprintf("%s-%d-%d", p, os.get_pid(), n, allocator = allocator)
}

// bg_try_begin returns false if at concurrent cap (does not increment on failure).
bg_try_begin :: proc() -> bool {
	sync.mutex_lock(&g_bg_mu)
	defer sync.mutex_unlock(&g_bg_mu)
	if g_bg_running >= MAX_BG_TASKS {
		return false
	}
	g_bg_running += 1
	return true
}

bg_end_running :: proc() {
	sync.mutex_lock(&g_bg_mu)
	g_bg_running -= 1
	if g_bg_running < 0 {
		g_bg_running = 0
	}
	sync.mutex_unlock(&g_bg_mu)
}

// auto_wake_enabled is true unless AETHER_NO_AUTO_WAKE=1/true.
auto_wake_enabled :: proc() -> bool {
	v := os.get_env("AETHER_NO_AUTO_WAKE", context.temp_allocator)
	if v == "1" || strings.equal_fold(v, "true") {
		return false
	}
	return true
}

// bg_new_subagent_task allocates and registers a Running subagent task (does not bump running cap).
bg_new_subagent_task :: proc(
	kind: Subagent_Type,
	description: string,
	model: string,
	allocator := context.allocator,
) -> ^Bg_Task {
	id := generate_bg_task_id("sub", allocator)
	task := new(Bg_Task)
	task.id = id
	task.task_kind = .Subagent
	task.sub_type = kind
	if len(description) > 80 {
		task.description = strings.clone(description[:80], allocator)
	} else {
		task.description = strings.clone(description, allocator)
	}
	task.status = .Running
	task.result = ""
	task.cancel = false
	task.has_process = false
	task.msgs = make([dynamic]Chat_Message, 0, 0, allocator)
	task.model = strings.clone(model, allocator)
	task.delivered = false
	task.worktree_path = ""
	bg_tasks_ensure_heap()
	sync.mutex_lock(&g_bg_mu)
	append(&g_bg_tasks, task)
	sync.mutex_unlock(&g_bg_mu)
	return task
}

destroy_bg_completion :: proc(c: ^Bg_Completion) {
	delete(c.id)
	delete(c.description)
	delete(c.result)
}

destroy_bg_completions :: proc(items: []Bg_Completion) {
	for &c in items {
		destroy_bg_completion(&c)
	}
	delete(items)
}

// bg_has_undelivered reports whether any terminal task has not been auto-wake delivered.
bg_has_undelivered :: proc() -> bool {
	sync.mutex_lock(&g_bg_mu)
	defer sync.mutex_unlock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.status != .Running && !t.delivered {
			return true
		}
	}
	return false
}

// bg_drain_undelivered clones terminal undelivered tasks and marks them delivered.
// Caller must destroy_bg_completions the result.
bg_drain_undelivered :: proc(allocator := context.allocator) -> []Bg_Completion {
	out := make([dynamic]Bg_Completion, 0, 4, allocator)
	sync.mutex_lock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.status == .Running || t.delivered {
			continue
		}
		t.delivered = true
		append(
			&out,
			Bg_Completion {
				id          = strings.clone(t.id, allocator),
				task_kind   = t.task_kind,
				sub_type    = t.sub_type,
				status      = t.status,
				description = strings.clone(t.description, allocator),
				result      = strings.clone(t.result, allocator),
			},
		)
	}
	sync.mutex_unlock(&g_bg_mu)
	return out[:]
}

cap_completion_body :: proc(s: string, max_bytes: int, allocator := context.allocator) -> string {
	if max_bytes <= 0 || len(s) <= max_bytes {
		return strings.clone(s, allocator)
	}
	return fmt.aprintf(
		"%s\n… [truncated; use get_task_output for full output]",
		s[:max_bytes],
		allocator = allocator,
	)
}

// format_bg_completion_reminder builds a <system-reminder> for drained completions.
format_bg_completion_reminder :: proc(
	items: []Bg_Completion,
	allocator := context.allocator,
) -> string {
	if len(items) == 0 {
		return ""
	}
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		"<system-reminder>\nBackground task(s) finished. Results are included below; you may still call get_task_output for full output if truncated.\n",
	)
	for c, i in items {
		if i > 0 {
			strings.write_string(&b, "\n")
		}
		kind_s := "shell"
		if c.task_kind == .Subagent {
			kind_s = subagent_type_string(c.sub_type)
		} else if c.task_kind == .Monitor {
			kind_s = "monitor"
		}
		strings.write_string(
			&b,
			fmt.tprintf(
				"\ntask_id: %s\nkind: %s\nstatus: %s\ndescription: %s\n---\n",
				c.id,
				kind_s,
				bg_status_string(c.status),
				c.description if c.description != "" else "(none)",
			),
		)
		body := cap_completion_body(c.result, MAX_INLINE_COMPLETION, context.temp_allocator)
		strings.write_string(&b, body)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "</system-reminder>")
	return strings.to_string(b)
}

// maybe_inject_bg_completions drains undelivered terminal tasks into a user system-reminder.
// Only for top-level parent turns (depth 0). Returns true if a message was appended.
maybe_inject_bg_completions :: proc(
	msgs: ^[dynamic]Chat_Message,
	allocator := context.allocator,
) -> bool {
	if !auto_wake_enabled() {
		return false
	}
	if g_subagent_depth != 0 {
		return false
	}
	items := bg_drain_undelivered(context.temp_allocator)
	if len(items) == 0 {
		return false
	}
	// Own strings for the message; drain used temp_allocator for completion structs —
	// re-drain with real allocator for durable content.
	// NOTE: items already marked delivered; rebuild reminder from item clones on temp.
	text := format_bg_completion_reminder(items, allocator)
	// Free completion clones if they used temp — destroy only if not temp
	// items allocated on temp_allocator: don't free individual (temp will reset)
	if text == "" {
		return false
	}
	append(
		msgs,
		Chat_Message {
			role    = .User,
			content = text,
		},
	)
	return true
}

// try_idle_auto_wake starts a synthetic parent turn when undelivered completions exist.
// Returns ran=true when a turn was executed (code is run_agent_turn exit code).
try_idle_auto_wake :: proc(
	creds: Credentials,
	model: string,
	msgs: ^[dynamic]Chat_Message,
	opts: Turn_Options,
	allocator := context.allocator,
) -> (ran: bool, code: int) {
	if !auto_wake_enabled() {
		return false, 0
	}
	if g_subagent_depth != 0 {
		return false, 0
	}
	if !bg_has_undelivered() && !monitor_has_pending_events() && !scheduler_has_due() {
		return false, 0
	}
	// Drain scheduler fires, monitor lines, and/or completions, then run a full turn.
	inj_sched := maybe_inject_scheduler_fires(msgs, allocator)
	inj_mon := maybe_inject_monitor_events(msgs, allocator)
	inj_bg := maybe_inject_bg_completions(msgs, allocator)
	if !inj_sched && !inj_mon && !inj_bg {
		return false, 0
	}
	if !opts.quiet {
		fmt.eprintf("aether: auto-wake — background task(s) completed\n")
	}
	if opts.on_status != nil {
		opts.on_status("auto-wake: bg completed…")
	}
	if opts.on_history != nil {
		opts.on_history()
	}
	// Mid-turn inject at start of run_agent_turn will no-op (already delivered).
	text, c := run_agent_turn(creds, model, msgs, opts)
	if text != "" {
		delete(text)
	}
	return true, c
}

// bg_free_task_msgs clears archived transcript on a task (under caller lock or exclusive access).
bg_free_task_msgs :: proc(task: ^Bg_Task) {
	if len(task.msgs) > 0 {
		destroy_messages(task.msgs[:])
		task.msgs = make([dynamic]Chat_Message, 0, 0, context.allocator)
	}
}

// bg_evict_oldest_archives drops msgs from oldest terminal subagents when over soft cap.
// Caller must hold g_bg_mu.
bg_evict_oldest_archives :: proc() {
	// Count terminal subagents that still hold transcripts.
	count := 0
	for t in g_bg_tasks {
		if t.task_kind == .Subagent && t.status != .Running && len(t.msgs) > 0 {
			count += 1
		}
	}
	for count > MAX_SUBAGENT_ARCHIVES {
		evicted := false
		for t in g_bg_tasks {
			if t.task_kind == .Subagent && t.status != .Running && len(t.msgs) > 0 {
				destroy_messages(t.msgs[:])
				t.msgs = make([dynamic]Chat_Message, 0, 0, context.allocator)
				count -= 1
				evicted = true
				break
			}
		}
		if !evicted {
			break
		}
	}
}

// bg_finish_subagent stores result, status, and a deep-cloned transcript for resume_from.
bg_finish_subagent :: proc(
	task: ^Bg_Task,
	status: Bg_Task_Status,
	result: string,
	msgs: []Chat_Message,
	model: string,
	was_running_slot: bool,
) {
	// SubagentStop hook (sync + background complete)
	if task != nil && task.task_kind == .Subagent {
		st_s := "completed"
		exit_c := 0
		switch status {
		case .Completed:
			st_s = "completed"
			exit_c = 0
		case .Failed:
			st_s = "error"
			exit_c = 1
		case .Cancelled:
			st_s = "cancelled"
			exit_c = 4
		case .Running:
			st_s = "running"
		}
		cwd := task.worktree_path
		if cwd == "" {
			cwd = g_hooks_cwd if g_hooks_cwd != "" else "."
		}
		hooks.run_subagent_stop_hooks(
			cwd,
			subagent_type_string(task.sub_type),
			task.id,
			st_s,
			exit_c,
		)
	}

	cloned := clone_messages(msgs, context.allocator)
	sync.mutex_lock(&g_bg_mu)
	// Replace any prior archive / result
	if len(task.msgs) > 0 {
		destroy_messages(task.msgs[:])
	}
	task.msgs = cloned
	if task.result != "" {
		delete(task.result)
	}
	task.result = result
	task.status = status
	if model != "" {
		if task.model != "" {
			delete(task.model)
		}
		task.model = strings.clone(model, context.allocator)
	}
	if was_running_slot {
		g_bg_running -= 1
		if g_bg_running < 0 {
			g_bg_running = 0
		}
	}
	bg_evict_oldest_archives()
	sync.mutex_unlock(&g_bg_mu)
	// Desktop notify for background subagents (was_running_slot) only
	if was_running_slot {
		maybe_notify_bg_task(task)
	}
}

// Resume_Source is a cloned snapshot for resume (caller owns msgs).
Resume_Source :: struct {
	id:            string,
	kind:          Subagent_Type,
	model:         string,
	worktree_path: string,
	msgs:          [dynamic]Chat_Message,
}

// bg_lookup_for_resume clones a terminal subagent transcript for resume_from.
// On error, err is non-empty and msgs is empty.
bg_lookup_for_resume :: proc(
	resume_id: string,
	allocator := context.allocator,
) -> (src: Resume_Source, err: string) {
	rid := strings.trim_space(resume_id)
	if rid == "" {
		return {}, strings.clone("error: resume_from is empty", allocator)
	}
	sync.mutex_lock(&g_bg_mu)
	defer sync.mutex_unlock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.id != rid {
			continue
		}
		if t.task_kind != .Subagent {
			return {}, fmt.aprintf(
				"error: resume_from %q is not a subagent (shell tasks cannot be resumed)",
				rid,
				allocator = allocator,
			)
		}
		if t.status == .Running {
			return {}, fmt.aprintf(
				"error: resume_from %q is still running; wait with get_task_output",
				rid,
				allocator = allocator,
			)
		}
		if len(t.msgs) == 0 {
			return {}, fmt.aprintf(
				"error: resume_from %q has no stored transcript (evicted or incomplete)",
				rid,
				allocator = allocator,
			)
		}
		src.id = strings.clone(t.id, allocator)
		src.kind = t.sub_type
		src.model = strings.clone(t.model, allocator)
		src.worktree_path = strings.clone(t.worktree_path, allocator)
		src.msgs = clone_messages(t.msgs[:], allocator)
		return src, ""
	}
	return {}, fmt.aprintf("error: unknown resume_from id %q", rid, allocator = allocator)
}

// format_subagent_result builds model-facing completion text with resume footer.
format_subagent_result :: proc(
	id: string,
	kind: Subagent_Type,
	status_word: string, // "completed" | "stopped" | "cancelled" | "failed"
	body: string,
	extra_label: string, // e.g. "max turns" for stopped; may be empty
	worktree_path := "",
	allocator := context.allocator,
) -> string {
	label := subagent_type_string(kind)
	head: string
	if extra_label != "" {
		head = fmt.aprintf(
			"subagent [%s] %s (%s):\n\n%s",
			label,
			status_word,
			extra_label,
			body,
			allocator = context.temp_allocator,
		)
	} else if body != "" {
		head = fmt.aprintf(
			"subagent [%s] %s:\n\n%s",
			label,
			status_word,
			body,
			allocator = context.temp_allocator,
		)
	} else {
		head = fmt.aprintf(
			"subagent [%s] %s",
			label,
			status_word,
			allocator = context.temp_allocator,
		)
	}
	meta := fmt.tprintf("id=%s, type=%s", id, label)
	if worktree_path != "" {
		meta = fmt.tprintf("%s, worktree=%s", meta, worktree_path)
	}
	wt_line := ""
	if worktree_path != "" {
		wt_line = fmt.tprintf(
			"worktree_path: %s\n(worktree preserved; merge/cherry-pick into the parent tree manually if needed)\n",
			worktree_path,
		)
	}
	return fmt.aprintf(
		"%s\n\n<subagent_meta>%s</subagent_meta>\n\n<subagent_result>\nsubagent_id: %s\nsubagent_type: %s\n%sTo continue this subagent's conversation, use resume_from=\"%s\".\n</subagent_result>",
		head,
		meta,
		id,
		label,
		wt_line,
		id,
		allocator = allocator,
	)
}

// resolve_subagent_workspace picks parent workspace, inherited worktree, or creates a new one.
// Returns effective workspace (do not free if same as parent_ws), owned worktree_path (may be ""), and err.
resolve_subagent_workspace :: proc(
	parent_ws: string,
	isolation: Isolation_Mode,
	inherit_worktree: string,
	task_id: string,
	allocator := context.allocator,
) -> (workspace: string, worktree_path: string, err: string) {
	if inherit_worktree != "" {
		if !os.is_directory(inherit_worktree) {
			return "", "", fmt.aprintf(
				"error: resume worktree path missing or not a directory: %s",
				inherit_worktree,
				allocator = allocator,
			)
		}
		wt := strings.clone(inherit_worktree, allocator)
		return wt, wt, ""
	}
	if isolation == .Worktree {
		path, e := create_subagent_worktree(parent_ws, task_id, allocator)
		if e != "" {
			return "", "", e
		}
		return path, path, ""
	}
	return parent_ws, "", ""
}

// spawn_subagent_background starts a worker thread; returns model-facing notice.
spawn_subagent_background :: proc(
	creds: Credentials,
	model: string,
	prompt: string,
	kind: Subagent_Type,
	description: string,
	parent: Turn_Options,
	allocator := context.allocator,
	isolation: Isolation_Mode = .None,
	inherit_worktree := "",
	persona_instructions := "",
) -> string {
	return spawn_subagent_background_seeded(
		creds,
		model,
		prompt,
		kind,
		description,
		parent,
		{},
		false,
		allocator,
		isolation,
		inherit_worktree,
		persona_instructions,
	)
}

// spawn_subagent_background_seeded: has_seed transfers ownership of seed_msgs to the worker.
spawn_subagent_background_seeded :: proc(
	creds: Credentials,
	model: string,
	prompt: string,
	kind: Subagent_Type,
	description: string,
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
	if strings.trim_space(prompt) == "" {
		if has_seed {
			destroy_messages(seed_msgs[:])
		}
		return strings.clone("error: prompt is required", allocator)
	}

	if !bg_try_begin() {
		if has_seed {
			destroy_messages(seed_msgs[:])
		}
		return fmt.aprintf(
			"error: max concurrent background tasks (%d) reached; wait or kill_task",
			MAX_BG_TASKS,
			allocator = allocator,
		)
	}

	desc_src := description if description != "" else prompt
	task := bg_new_subagent_task(kind, desc_src, model, context.allocator)
	hooks.run_subagent_start_hooks(
		parent.workspace,
		subagent_type_string(kind),
		desc_src,
		true,
	)

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
		bg_end_running()
		return strings.clone(werr, allocator)
	}
	if wt != "" {
		task.worktree_path = wt
	}

	work := new(Bg_Work)
	work.task = task
	work.creds = clone_credentials(creds, context.allocator)
	work.model = strings.clone(model, context.allocator)
	work.prompt = strings.clone(prompt, context.allocator)
	// Child workspace is worktree or parent
	if wt != "" {
		work.workspace = strings.clone(wt, context.allocator)
	} else {
		work.workspace = strings.clone(parent.workspace, context.allocator)
	}
	_ = ws
	work.kind = kind
	work.mcp_enabled = parent.mcp_enabled
	work.skills_enabled = parent.skills_enabled
	work.max_turns = 12
	if parent.max_turns > 0 && parent.max_turns < work.max_turns {
		work.max_turns = parent.max_turns
	}
	if has_seed {
		work.seed_msgs = seed_msgs
		work.has_seed = true
	}
	if persona_instructions != "" {
		work.persona_instructions = strings.clone(persona_instructions, context.allocator)
	}

	_ = thread.create_and_start_with_poly_data(work, bg_worker_proc, nil, .Normal, true)

	label := subagent_type_string(kind)
	resume_note := ""
	if has_seed {
		resume_note = " (resumed)"
	}
	wt_line := ""
	if task.worktree_path != "" {
		wt_line = fmt.tprintf("\nworktree: %s", task.worktree_path)
	}
	return fmt.aprintf(
		"Subagent started in background%s.\nsubagent_id: %s\ntype: %s\ndescription: %s%s\n\nUse get_task_output with task_ids=[\"%s\"] and optional timeout_ms to wait for results. Use kill_task to cancel.",
		resume_note,
		task.id,
		label,
		task.description,
		wt_line,
		task.id,
		allocator = allocator,
	)
}

// handle_bash_background starts a shell command on a worker thread (after permission).
handle_bash_background :: proc(
	arguments_json: string,
	opts: Turn_Options,
	allocator := context.allocator,
) -> string {
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	command := strings.trim_space(tools.jstr(obj, "command"))
	if command == "" {
		return strings.clone("error: command is required", allocator)
	}
	// timeout: 0 or omitted → no wall-clock limit for background shell
	timeout_ms := 0
	if _, has := obj["timeout"]; has {
		timeout_ms = tools.jint(obj, "timeout", 0)
		if timeout_ms < 0 {
			timeout_ms = 0
		}
	}
	desc := tools.jstr(obj, "description")
	if desc == "" {
		desc = command
	}
	if len(desc) > 80 {
		desc = desc[:80]
	}

	if !bg_try_begin() {
		return fmt.aprintf(
			"error: max concurrent background tasks (%d) reached; wait or kill_task",
			MAX_BG_TASKS,
			allocator = allocator,
		)
	}

	id := generate_bg_task_id("bash", context.allocator)
	task := new(Bg_Task)
	task.id = id
	task.task_kind = .Shell
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

	log_path := bash_log_path(id, context.allocator)

	work := new(Bg_Shell_Work)
	work.task = task
	work.command = strings.clone(command, context.allocator)
	work.workspace = strings.clone(opts.workspace, context.allocator)
	work.timeout_ms = timeout_ms
	work.log_path = strings.clone(log_path, context.allocator)
	work.allocator = context.allocator

	// nil init_context: worker gets its own temp allocator (thread-safe).
	// Heap allocs use work.allocator (set at top of bg_shell_worker_proc).
	// Passing the parent context shared the test/main temp arena across threads
	// and caused complete→kill SIGSEGV under the tracking allocator.
	_ = thread.create_and_start_with_poly_data(work, bg_shell_worker_proc, nil, .Normal, true)

	preview := command
	if len(preview) > 120 {
		preview = preview[:120]
	}
	return fmt.aprintf(
		"Background shell started.\ntask_id: %s\ncommand: %s\nlog: %s\n\nUse get_task_output with task_ids=[\"%s\"] and optional timeout_ms to wait for results. Use kill_task to stop; read_file on the log for full output.",
		id,
		preview,
		log_path,
		id,
		allocator = allocator,
	)
}

bg_shell_worker_proc :: proc(work: ^Bg_Shell_Work) {
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
		bg_free_shell_work(work)
		return
	}
	stderr_r, stderr_w, perr2 := os.pipe()
	if perr2 != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		bg_finish_shell(task, .Failed, fmt.aprintf("error: pipe stderr: %v", perr2, allocator = alloc))
		bg_free_shell_work(work)
		return
	}

	child, serr := os.process_start(
		{
			command = {"sh", "-c", command},
			working_dir = workspace,
			stdout = stdout_w,
			stderr = stderr_w,
		},
	)
	os.close(stdout_w)
	os.close(stderr_w)
	if serr != nil {
		os.close(stdout_r)
		os.close(stderr_r)
		bg_finish_shell(task, .Failed, fmt.aprintf("error: failed to start command: %v", serr, allocator = alloc))
		bg_free_shell_work(work)
		return
	}

	sync.mutex_lock(&g_bg_mu)
	task.process = child
	task.has_process = true
	sync.mutex_unlock(&g_bg_mu)

	stdout_b := make([dynamic]byte, 0, 4096, alloc)
	stderr_b := make([dynamic]byte, 0, 1024, alloc)
	defer delete(stdout_b)
	defer delete(stderr_b)
	buf: [4096]u8
	start_t := time.now()
	timeout_dur := time.Duration(timeout_ms) * time.Millisecond

	stdout_done := false
	stderr_done := false
	timed_out := false
	cancelled := false
	exit_code := 0

	for !stdout_done || !stderr_done {
		if task.cancel {
			cancelled = true
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, 2 * time.Second)
			// drain remaining
			for !stdout_done {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					append(&stdout_b, ..buf[:n])
				}
				if rerr != nil || n == 0 {
					stdout_done = true
				}
			}
			for !stderr_done {
				n, rerr := os.read(stderr_r, buf[:])
				if n > 0 {
					append(&stderr_b, ..buf[:n])
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
					append(&stdout_b, ..buf[:n])
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
					append(&stderr_b, ..buf[:n])
				}
				if rerr == .EOF || rerr == .Broken_Pipe {
					stderr_done = true
				}
			}
		}

		state, werr := os.process_wait(child, 0)
		if werr == nil && state.exited {
			exit_code = state.exit_code
			for !stdout_done {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					append(&stdout_b, ..buf[:n])
				}
				if rerr != nil || n == 0 {
					stdout_done = true
				}
			}
			for !stderr_done {
				n, rerr := os.read(stderr_r, buf[:])
				if n > 0 {
					append(&stderr_b, ..buf[:n])
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

	os.close(stdout_r)
	os.close(stderr_r)

	sync.mutex_lock(&g_bg_mu)
	task.has_process = false
	sync.mutex_unlock(&g_bg_mu)

	// Persist full stdout/stderr under session terminal/
	if work.log_path != "" {
		if dir := filepath.dir(work.log_path); dir != "" {
			_ = core.ensure_dir(dir)
		}
		log_body := tools.format_cmd_output(
			stdout_b[:],
			stderr_b[:],
			exit_code,
			timed_out,
			context.temp_allocator,
		)
		_ = os.write_entire_file(work.log_path, transmute([]byte)log_body)
	}

	out := tools.format_cmd_output(
		stdout_b[:],
		stderr_b[:],
		exit_code,
		timed_out,
		alloc,
	)
	capped := tools.cap_output(out, tools.DEFAULT_BASH_CAP, alloc)
	delete(out)

	status: Bg_Task_Status
	result: string
	log_hint := ""
	if work.log_path != "" {
		log_hint = fmt.tprintf("\n\nFull log: %s", work.log_path)
	}
	if cancelled || task.cancel {
		status = .Cancelled
		result = fmt.aprintf("shell cancelled:\n\n%s%s", capped, log_hint, allocator = alloc)
		delete(capped)
	} else if timed_out {
		status = .Failed
		result = fmt.aprintf("shell timed out:\n\n%s%s", capped, log_hint, allocator = alloc)
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
	bg_free_shell_work(work)
}

bg_finish_shell :: proc(task: ^Bg_Task, status: Bg_Task_Status, result: string) {
	sync.mutex_lock(&g_bg_mu)
	task.result = result
	task.status = status
	task.has_process = false
	g_bg_running -= 1
	if g_bg_running < 0 {
		g_bg_running = 0
	}
	sync.mutex_unlock(&g_bg_mu)
	maybe_notify_bg_task(task)
}

bg_free_shell_work :: proc(work: ^Bg_Shell_Work) {
	delete(work.command)
	delete(work.workspace)
	delete(work.log_path)
	free(work)
}

bg_worker_proc :: proc(work: ^Bg_Work) {
	task := work.task

	sync.mutex_lock(&g_depth_mu)
	g_subagent_depth += 1
	sync.mutex_unlock(&g_depth_mu)
	defer {
		sync.mutex_lock(&g_depth_mu)
		g_subagent_depth -= 1
		sync.mutex_unlock(&g_depth_mu)
	}

	deny := deny_tools_for_subagent(work.kind)
	catalog := ""
	if work.skills_enabled {
		catalog = skills_catalog_text(context.temp_allocator)
	}

	msgs: [dynamic]Chat_Message
	if work.has_seed {
		// Resume: seed already has history; refresh system + append user prompt.
		msgs = work.seed_msgs
		work.has_seed = false
		work.seed_msgs = {}
		refresh_subagent_system_prompt(
			&msgs,
			work.kind,
			work.workspace,
			catalog,
			context.allocator,
			work.persona_instructions,
		)
		append(
			&msgs,
			Chat_Message {
				role    = .User,
				content = strings.clone(work.prompt),
			},
		)
	} else {
		msgs = make([dynamic]Chat_Message, 0, 16)
		append(
			&msgs,
			Chat_Message {
				role    = .System,
				content = subagent_system_prompt(
					work.kind,
					work.workspace,
					catalog,
					context.allocator,
					work.persona_instructions,
				),
			},
		)
		append(
			&msgs,
			Chat_Message {
				role    = .User,
				content = strings.clone(work.prompt),
			},
		)
	}
	// Archive before destroy — finish clones msgs
	defer destroy_messages(msgs[:])

	// No TUI callbacks from background thread; Always_Approve + deny_tools policy
	child_opts := Turn_Options {
		workspace         = work.workspace,
		max_turns         = work.max_turns,
		quiet             = true,
		verbose           = false,
		permission_mode   = .Always_Approve,
		permission_live   = nil,
		on_status         = nil,
		on_history        = nil,
		on_ask            = nil,
		cancel            = &task.cancel,
		on_poll           = nil,
		mcp_enabled       = work.mcp_enabled,
		skills_enabled    = work.skills_enabled,
		subagents_enabled = false,
		deny_tools        = deny,
	}

	text, code := run_agent_turn(work.creds, work.model, &msgs, child_opts)

	result: string
	status: Bg_Task_Status

	wt_path := task.worktree_path
	if task.cancel || code == 4 {
		status = .Cancelled
		body := text if text != "" else ""
		result = format_subagent_result(
			task.id,
			work.kind,
			"cancelled",
			body,
			"",
			wt_path,
			context.allocator,
		)
		if text != "" {
			delete(text)
		}
	} else if code == 0 {
		status = .Completed
		body := text if text != "" else "(empty report)"
		result = format_subagent_result(
			task.id,
			work.kind,
			"completed",
			body,
			"",
			wt_path,
			context.allocator,
		)
		if text != "" {
			delete(text)
		}
	} else {
		status = .Failed
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
		if partial != "" {
			result = format_subagent_result(
				task.id,
				work.kind,
				"stopped",
				partial,
				err_label,
				wt_path,
				context.allocator,
			)
		} else {
			result = format_subagent_result(
				task.id,
				work.kind,
				"failed",
				"",
				err_label,
				wt_path,
				context.allocator,
			)
		}
		if text != "" {
			delete(text)
		}
	}

	bg_finish_subagent(task, status, result, msgs[:], work.model, true)

	destroy_credentials(&work.creds)
	delete(work.model)
	delete(work.prompt)
	delete(work.workspace)
	delete(work.persona_instructions)
	if work.has_seed {
		destroy_messages(work.seed_msgs[:])
	}
	free(work)
}

// is_background_arg reports whether run_terminal_cmd requested background execution.
is_background_arg :: proc(arguments_json: string) -> bool {
	return extract_json_bool_field_agent(arguments_json, "is_background")
}

// Grok wait_tasks / multi get_task_output limits.
DEFAULT_WAIT_TIMEOUT_MS :: 30_000
MAX_MULTI_WAIT_IDS :: 20

Wait_Mode :: enum {
	Wait_All,
	Wait_Any,
}

// wait_tasks_impl: shared multi-id poll/wait.
// timeout_ms <= 0: snapshot once (get_task_output default).
// timeout_ms > 0: wait until done or deadline.
// wait_any: return as soon as any id is non-running (or timeout); still report all.
wait_tasks_impl :: proc(
	ids: []string,
	timeout_ms: int,
	mode: Wait_Mode,
	allocator := context.allocator,
) -> string {
	if len(ids) == 0 {
		return strings.clone("error: task_ids required (array of background task ids)", allocator)
	}
	if len(ids) > MAX_MULTI_WAIT_IDS {
		return fmt.aprintf(
			"error: task_ids exceeds maximum of %d entries",
			MAX_MULTI_WAIT_IDS,
			allocator = allocator,
		)
	}

	start := time.now()
	timeout := time.Duration(timeout_ms) * time.Millisecond

	// wait_any: poll until any finishes, then snapshot all
	if mode == .Wait_Any && timeout_ms > 0 {
		for {
			any_done := false
			for id in ids {
				st, _, found := bg_task_snapshot(id, context.temp_allocator)
				if !found || st != .Running {
					any_done = true
					break
				}
			}
			if any_done || time.since(start) >= timeout {
				break
			}
			time.sleep(80 * time.Millisecond)
		}
		return format_task_snapshots(ids, 0, start, allocator)
	}

	return format_task_snapshots(ids, timeout_ms, start, allocator)
}

format_task_snapshots :: proc(
	ids: []string,
	timeout_ms: int,
	start: time.Time,
	allocator := context.allocator,
) -> string {
	timeout := time.Duration(timeout_ms) * time.Millisecond
	b := strings.builder_make(allocator)
	for id, i in ids {
		if i > 0 {
			strings.write_string(&b, "\n\n")
		}
		for {
			st, res, found := bg_task_snapshot(id, context.temp_allocator)
			if !found {
				strings.write_string(
					&b,
					fmt.tprintf(
						"task_id: %s\nstatus: not_found\n---\nerror: unknown task id",
						id,
					),
				)
				break
			}
			if st != .Running {
				strings.write_string(
					&b,
					fmt.tprintf(
						"task_id: %s\nstatus: %s\n---\n%s",
						id,
						bg_status_string(st),
						res,
					),
				)
				break
			}
			if timeout_ms <= 0 {
				strings.write_string(
					&b,
					fmt.tprintf(
						"task_id: %s\nstatus: running\n---\n(still running; pass timeout_ms to wait)",
						id,
					),
				)
				break
			}
			if time.since(start) >= timeout {
				strings.write_string(
					&b,
					fmt.tprintf(
						"task_id: %s\nstatus: running\n---\n(timeout after %d ms; still running)",
						id,
						timeout_ms,
					),
				)
				break
			}
			time.sleep(80 * time.Millisecond)
		}
	}
	return strings.to_string(b)
}

handle_get_task_output :: proc(arguments_json: string, allocator := context.allocator) -> string {
	ids := parse_task_ids(arguments_json, context.temp_allocator)
	timeout_ms := 0
	if obj, ok := tools.json_obj(arguments_json); ok {
		timeout_ms = tools.jint(obj, "timeout_ms", 0)
	}
	return wait_tasks_impl(ids, timeout_ms, .Wait_All, allocator)
}

// handle_wait_tasks: Grok wait_tasks / wait_commands_or_subagents.
// Default timeout 30s when omit/0 (always blocks).
handle_wait_tasks :: proc(arguments_json: string, allocator := context.allocator) -> string {
	ids := parse_task_ids(arguments_json, context.temp_allocator)
	timeout_ms := DEFAULT_WAIT_TIMEOUT_MS
	mode := Wait_Mode.Wait_All
	if obj, ok := tools.json_obj(arguments_json); ok {
		if _, has := obj["timeout_ms"]; has {
			t := tools.jint(obj, "timeout_ms", 0)
			if t > 0 {
				timeout_ms = t
			}
			// omit or 0 → keep default 30s
		}
		m := strings.to_lower(tools.jstr(obj, "mode"), context.temp_allocator)
		if m == "wait_any" || m == "any" {
			mode = .Wait_Any
		}
	}
	return wait_tasks_impl(ids, timeout_ms, mode, allocator)
}

handle_kill_task :: proc(arguments_json: string, allocator := context.allocator) -> string {
	id := extract_json_string_field_agent(arguments_json, "task_id")
	if id == "" {
		ids := parse_task_ids(arguments_json, context.temp_allocator)
		if len(ids) > 0 {
			id = ids[0]
		}
	}
	if id == "" {
		return strings.clone("error: task_id is required", allocator)
	}

	proc_to_kill: os.Process
	do_kill := false
	found := false
	finished_status: Bg_Task_Status
	already_done := false
	is_shell := false

	sync.mutex_lock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.id != id {
			continue
		}
		found = true
		if t.status != .Running {
			already_done = true
			finished_status = t.status
			break
		}
		t.cancel = true
		is_shell = t.task_kind == .Shell || t.task_kind == .Monitor
		if (t.task_kind == .Shell || t.task_kind == .Monitor) && t.has_process {
			proc_to_kill = t.process
			t.has_process = false
			do_kill = true
		}
		break
	}
	sync.mutex_unlock(&g_bg_mu)

	if !found {
		return fmt.aprintf("error: unknown task_id %s", id, allocator = allocator)
	}
	if already_done {
		return fmt.aprintf(
			"task_id: %s already finished (status=%s)",
			id,
			bg_status_string(finished_status),
			allocator = allocator,
		)
	}
	if do_kill {
		_ = os.process_kill(proc_to_kill)
		return fmt.aprintf(
			"kill requested for task_id: %s (process signalled; wait with get_task_output)",
			id,
			allocator = allocator,
		)
	}
	_ = is_shell
	return fmt.aprintf(
		"cancel requested for task_id: %s (cooperative; wait with get_task_output)",
		id,
		allocator = allocator,
	)
}

bg_task_snapshot :: proc(
	id: string,
	allocator := context.allocator,
) -> (status: Bg_Task_Status, result: string, found: bool) {
	sync.mutex_lock(&g_bg_mu)
	defer sync.mutex_unlock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.id == id {
			return t.status, strings.clone(t.result, allocator), true
		}
	}
	return .Failed, "", false
}

parse_task_ids :: proc(arguments_json: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return out[:]
	}
	if v, has := obj["task_ids"]; has {
		if arr, is_arr := v.(json.Array); is_arr {
			for item in arr {
				if s, is_s := item.(json.String); is_s && string(s) != "" {
					append(&out, strings.clone(string(s), allocator))
				}
			}
			return out[:]
		}
		if s, is_s := v.(json.String); is_s && string(s) != "" {
			append(&out, strings.clone(string(s), allocator))
			return out[:]
		}
	}
	s := tools.jstr(obj, "task_id")
	if s != "" {
		append(&out, strings.clone(s, allocator))
	}
	return out[:]
}

// extract_json_bool_field: true if key is boolean true or string "true"/"1"
extract_json_bool_field_agent :: proc(raw: string, key: string) -> bool {
	if obj, ok := tools.json_obj(raw); ok {
		return tools.jbool(obj, key, false)
	}
	return false
}

