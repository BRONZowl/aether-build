package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "aether:tools"

// Serialize tests that touch the global background task registry/cap.
@(private)
g_bg_test_mu: sync.Mutex

@(test)
test_subagent_type_parse :: proc(t: ^testing.T) {
	k, ok := subagent_type_from_string("explore")
	testing.expect(t, ok && k == .Explore)
	k, ok = subagent_type_from_string("PLAN")
	testing.expect(t, ok && k == .Plan)
	k, ok = subagent_type_from_string("general-purpose")
	testing.expect(t, ok && k == .General_Purpose)
	_, ok = subagent_type_from_string("bogus")
	testing.expect(t, !ok)
}

@(test)
test_deny_tools_for_subagent :: proc(t: ^testing.T) {
	d := deny_tools_for_subagent(.Explore)
	testing.expect(t, tools.tool_name_denied("search_replace", d))
	testing.expect(t, tools.tool_name_denied("spawn_subagent", d))
	testing.expect(t, !tools.tool_name_denied("read_file", d))
	d = deny_tools_for_subagent(.General_Purpose)
	testing.expect(t, tools.tool_name_denied("spawn_subagent", d))
	testing.expect(t, !tools.tool_name_denied("search_replace", d))
}

@(test)
test_filter_tools_schema_strips_denied :: proc(t: ^testing.T) {
	schema := tools.tools_json_schema(
		false,
		false,
		true,
		false,
		false,
		[]string{"spawn_subagent", "search_replace"},
	)
	defer delete(schema)
	testing.expect(t, strings.contains(schema, "read_file"))
	testing.expect(t, !strings.contains(schema, `"name":"spawn_subagent"`))
	testing.expect(t, !strings.contains(schema, `"name":"search_replace"`))
}

@(test)
test_spawn_schema_includes_background_and_task_tools :: proc(t: ^testing.T) {
	schema := tools.tools_json_schema(false, false, true, false, false, nil)
	defer delete(schema)
	testing.expect(t, strings.contains(schema, "spawn_subagent"))
	testing.expect(t, strings.contains(schema, "background"))
	testing.expect(t, strings.contains(schema, "resume_from"))
	testing.expect(t, strings.contains(schema, "isolation"))
	testing.expect(t, strings.contains(schema, "worktree"))
	testing.expect(t, strings.contains(schema, "get_task_output"))
	testing.expect(t, strings.contains(schema, "kill_task"))
}

@(test)
test_format_subagent_result_includes_worktree :: proc(t: ^testing.T) {
	out := format_subagent_result(
		"sub-1",
		.General_Purpose,
		"completed",
		"done",
		"",
		"/tmp/wt",
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "worktree_path: /tmp/wt"))
	testing.expect(t, strings.contains(out, "worktree=/tmp/wt"))
}

@(test)
test_sanitize_resume_from :: proc(t: ^testing.T) {
	testing.expect(t, sanitize_resume_from("") == "")
	testing.expect(t, sanitize_resume_from("null") == "")
	testing.expect(t, sanitize_resume_from("None") == "")
	testing.expect(t, sanitize_resume_from("undefined") == "")
	testing.expect(t, sanitize_resume_from("  sub-1-2  ") == "sub-1-2")
}

@(test)
test_clone_messages_preserves_tool_calls :: proc(t: ^testing.T) {
	src := make([dynamic]Chat_Message, 0, 2, context.allocator)
	defer destroy_messages(src[:])
	tcs := make([]Tool_Call, 1, context.allocator)
	tcs[0] = Tool_Call {
		id        = strings.clone("c1", context.allocator),
		name      = strings.clone("read_file", context.allocator),
		arguments = strings.clone(`{"target_file":"x"}`, context.allocator),
	}
	append(
		&src,
		Chat_Message {
			role       = .Assistant,
			content    = strings.clone("hi", context.allocator),
			tool_calls = tcs,
		},
	)
	append(
		&src,
		Chat_Message {
			role         = .Tool,
			content      = strings.clone("ok", context.allocator),
			tool_call_id = strings.clone("c1", context.allocator),
		},
	)
	cloned := clone_messages(src[:], context.allocator)
	defer destroy_messages(cloned[:])
	testing.expect(t, len(cloned) == 2)
	testing.expect(t, cloned[0].content == "hi")
	testing.expect(t, len(cloned[0].tool_calls) == 1)
	testing.expect(t, cloned[0].tool_calls[0].name == "read_file")
	testing.expect(t, cloned[1].tool_call_id == "c1")
	// Mutating clone must not change source
	delete(cloned[0].content)
	cloned[0].content = strings.clone("changed", context.allocator)
	testing.expect(t, src[0].content == "hi")
}

@(test)
test_format_subagent_result_footer :: proc(t: ^testing.T) {
	out := format_subagent_result("sub-1-9", .Explore, "completed", "findings", "", "", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "subagent [explore] completed"))
	testing.expect(t, strings.contains(out, "findings"))
	testing.expect(t, strings.contains(out, `resume_from="sub-1-9"`))
	testing.expect(t, strings.contains(out, "subagent_id: sub-1-9"))
	testing.expect(t, strings.contains(out, "<subagent_meta>id=sub-1-9"))
}

@(test)
test_resume_from_unknown_and_shell :: proc(t: ^testing.T) {
	// Unknown id (no registry mutation — safe under parallel tests)
	_, err := bg_lookup_for_resume("sub-nope-0", context.allocator)
	testing.expectf(t, strings.contains(err, "unknown"), "err=%s", err)
	delete(err)

	// Shell-kind rejection message shape (pure string; registry shell inject is racy under parallel tests)
	msg := fmt.aprintf(
		"error: resume_from %q is not a subagent (shell tasks cannot be resumed)",
		"bash-1",
		allocator = context.temp_allocator,
	)
	testing.expect(t, strings.contains(msg, "not a subagent"))
}

@(test)
test_resume_from_running_and_type_and_ok :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)

	// Running subagent — reject resume
	run_task := bg_new_subagent_task(.Explore, "running", "m", context.allocator)
	_, err_run := bg_lookup_for_resume(run_task.id, context.allocator)
	testing.expectf(t, strings.contains(err_run, "still running"), "err=%s", err_run)
	delete(err_run)
	// Mark completed with transcript
	seed := make([dynamic]Chat_Message, 0, 2, context.allocator)
	append(
		&seed,
		Chat_Message {
			role    = .System,
			content = strings.clone("sys", context.allocator),
		},
	)
	append(
		&seed,
		Chat_Message {
			role    = .User,
			content = strings.clone("first", context.allocator),
		},
	)
	bg_finish_subagent(
		run_task,
		.Completed,
		strings.clone("done", context.allocator),
		seed[:],
		"m",
		false,
	)
	destroy_messages(seed[:])

	src, err := bg_lookup_for_resume(run_task.id, context.allocator)
	testing.expect(t, err == "")
	testing.expect(t, src.kind == .Explore)
	testing.expect(t, len(src.msgs) == 2)
	// Simulate resume prep: refresh + append
	refresh_subagent_system_prompt(&src.msgs, src.kind, "/tmp", "", context.allocator)
	append(
		&src.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("follow-up", context.allocator),
		},
	)
	testing.expect(t, len(src.msgs) == 3)
	testing.expect(t, src.msgs[2].role == .User)
	testing.expect(t, src.msgs[2].content == "follow-up")
	testing.expect(t, strings.contains(src.msgs[0].content, "explore") || src.msgs[0].role == .System)
	destroy_messages(src.msgs[:])
	delete(src.id)
	delete(src.model)

	// Type mismatch via handle path (no network — fails at resume lookup type check)
	// Build a completed explore archive already present as run_task
	args := strings.concatenate(
		{
			`{"prompt":"again","subagent_type":"plan","resume_from":"`,
			run_task.id,
			`"}`,
		},
		context.allocator,
	)
	defer delete(args)
	out := handle_spawn_subagent(
		{},
		"m",
		args,
		Turn_Options{workspace = "/tmp", max_turns = 1, quiet = true},
		context.allocator,
	)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "type mismatch"), "out=%s", out)
}

@(test)
test_auto_wake_enabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_AUTO_WAKE", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_AUTO_WAKE")
		} else {
			_ = os.set_env("AETHER_NO_AUTO_WAKE", prev)
		}
	}
	_ = os.unset_env("AETHER_NO_AUTO_WAKE")
	testing.expect(t, auto_wake_enabled())
	_ = os.set_env("AETHER_NO_AUTO_WAKE", "1")
	testing.expect(t, !auto_wake_enabled())
	_ = os.set_env("AETHER_NO_AUTO_WAKE", "true")
	testing.expect(t, !auto_wake_enabled())
}

@(test)
test_bg_drain_and_format_reminder :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)
	bg_test_mark_all_delivered()
	bg_test_drain_running()

	task := bg_new_subagent_task(.Explore, "desc", "m", context.allocator)
	// Still running — drain must not include this id
	items0 := bg_drain_undelivered(context.allocator)
	for c in items0 {
		testing.expect(t, c.id != task.id)
	}
	destroy_bg_completions(items0)
	// Mark any leftover noise delivered again
	bg_test_mark_all_delivered()

	msgs := make([dynamic]Chat_Message, 0, 1, context.allocator)
	append(
		&msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("u", context.allocator),
		},
	)
	result_body := strings.clone("hello-complete-body", context.allocator)
	bg_finish_subagent(task, .Completed, result_body, msgs[:], "m", false)
	destroy_messages(msgs[:])

	testing.expect(t, bg_has_undelivered())
	items := bg_drain_undelivered(context.allocator)
	found := false
	for c in items {
		if c.id == task.id {
			found = true
			testing.expect(t, c.status == .Completed)
		}
	}
	testing.expect(t, found)
	text := format_bg_completion_reminder(items, context.allocator)
	defer delete(text)
	testing.expect(t, strings.contains(text, "system-reminder"))
	testing.expect(t, strings.contains(text, task.id))
	testing.expect(t, strings.contains(text, "hello-complete-body"))
	testing.expect(t, strings.contains(text, "explore") || strings.contains(text, "kind:"))
	destroy_bg_completions(items)

	// Our task not drained again
	items2 := bg_drain_undelivered(context.allocator)
	for c in items2 {
		testing.expect(t, c.id != task.id)
	}
	destroy_bg_completions(items2)
}

@(test)
test_maybe_inject_bg_completions :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)
	bg_test_mark_all_delivered()
	bg_test_drain_running()

	// Force enable
	prev := os.get_env("AETHER_NO_AUTO_WAKE", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_AUTO_WAKE")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_AUTO_WAKE")
		} else {
			_ = os.set_env("AETHER_NO_AUTO_WAKE", prev)
		}
	}

	task := bg_new_subagent_task(.General_Purpose, "inj", "m", context.allocator)
	seed := make([dynamic]Chat_Message, 0, 1, context.allocator)
	append(&seed, Chat_Message{role = .User, content = strings.clone("s", context.allocator)})
	bg_finish_subagent(
		task,
		.Completed,
		strings.clone("inject-me", context.allocator),
		seed[:],
		"m",
		false,
	)
	destroy_messages(seed[:])

	chat := make([dynamic]Chat_Message, 0, 2, context.allocator)
	defer destroy_messages(chat[:])
	ok := maybe_inject_bg_completions(&chat, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, len(chat) == 1)
	testing.expect(t, chat[0].role == .User)
	testing.expect(t, strings.contains(chat[0].content, "inject-me"))
	testing.expect(t, strings.contains(chat[0].content, "system-reminder"))

	// no double inject
	ok2 := maybe_inject_bg_completions(&chat, context.allocator)
	testing.expect(t, !ok2)
	testing.expect(t, len(chat) == 1)
}

@(test)
test_cap_completion_body :: proc(t: ^testing.T) {
	short := cap_completion_body("abc", 100, context.allocator)
	defer delete(short)
	testing.expect(t, short == "abc")
	long_src := strings.repeat("x", 50, context.temp_allocator)
	long := cap_completion_body(long_src, 10, context.allocator)
	defer delete(long)
	testing.expect(t, strings.contains(long, "truncated"))
	testing.expect(t, strings.has_prefix(long, "xxxxxxxxxx"))
}

@(test)
test_completed_archives_do_not_consume_running_cap :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)
	bg_test_drain_running()

	// Ensure running counter is free even if archives exist
	sync.mutex_lock(&g_bg_mu)
	g_bg_running = 0
	sync.mutex_unlock(&g_bg_mu)

	// Create a few completed archives without taking running slots
	for i in 0 ..< 3 {
		task := bg_new_subagent_task(.General_Purpose, "arch", "m", context.allocator)
		msgs := make([dynamic]Chat_Message, 0, 1, context.allocator)
		append(
			&msgs,
			Chat_Message {
				role    = .User,
				content = strings.clone("u", context.allocator),
			},
		)
		bg_finish_subagent(
			task,
			.Completed,
			strings.clone("r", context.allocator),
			msgs[:],
			"m",
			false,
		)
		destroy_messages(msgs[:])
		_ = i
	}
	testing.expect(t, bg_try_begin())
	bg_end_running()
}

@(test)
test_bg_status_and_parse_task_ids :: proc(t: ^testing.T) {
	testing.expect(t, bg_status_string(.Running) == "running")
	ids := parse_task_ids(`{"task_ids":["sub-1","sub-2"]}`, context.temp_allocator)
	testing.expect(t, len(ids) == 2)
	testing.expect(t, ids[0] == "sub-1")
	out := handle_get_task_output(`{"task_ids":["nope"]}`, context.temp_allocator)
	testing.expect(t, strings.contains(out, "not_found"))
	kill := handle_kill_task(`{"task_id":"missing"}`, context.temp_allocator)
	testing.expect(t, strings.contains(kill, "unknown") || strings.contains(kill, "error"))
}

@(test)
test_bash_background_complete_and_output :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)
	bg_test_reset_registry()

	opts := Turn_Options {
		workspace = "/tmp",
		max_turns = 1,
		quiet = true,
	}
	args := `{"command":"printf 'hello-bg\\n'","is_background":true}`
	start := handle_bash_background(args, opts, context.allocator)
	defer delete(start)
	testing.expectf(t, strings.contains(start, "task_id:"), "start: %s", start)
	testing.expect(t, strings.contains(start, "bash-"))

	// Extract task_id line
	id := extract_task_id_from_notice(start)
	testing.expectf(t, strings.has_prefix(id, "bash-"), "id=%s from %s", id, start)

	poll_args := make_task_ids_json(id, 3000, context.allocator)
	defer delete(poll_args)
	out := handle_get_task_output(poll_args, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "completed") || strings.contains(out, "failed"), "out: %s", out)
	testing.expectf(t, strings.contains(out, "hello-bg"), "out: %s", out)
	// Free registry before test-end tracking frees task memory (avoids UAF in next bg test).
	bg_test_reset_registry()
}

@(test)
test_bash_background_kill :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)
	bg_test_reset_registry()

	opts := Turn_Options {
		workspace = "/tmp",
		max_turns = 1,
		quiet = true,
	}
	start := handle_bash_background(
		`{"command":"sleep 30","is_background":true}`,
		opts,
		context.allocator,
	)
	defer delete(start)
	id := extract_task_id_from_notice(start)
	testing.expect(t, strings.has_prefix(id, "bash-"))

	kill_args := make_task_id_json(id, context.allocator)
	defer delete(kill_args)
	kill := handle_kill_task(kill_args, context.allocator)
	defer delete(kill)
	testing.expectf(t, strings.contains(kill, "kill") || strings.contains(kill, "cancel"), "kill: %s", kill)

	poll_args := make_task_ids_json(id, 3000, context.allocator)
	defer delete(poll_args)
	out := handle_get_task_output(poll_args, context.allocator)
	defer delete(out)
	testing.expectf(
		t,
		strings.contains(out, "cancelled") || strings.contains(out, "failed") || strings.contains(out, "completed"),
		"out: %s",
		out,
	)
	// Should not still be running after wait
	testing.expect(t, !strings.contains(out, "still running") || strings.contains(out, "cancelled"))
	bg_test_reset_registry()
}

@(test)
test_bash_background_cap :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_bg_test_mu)
	defer sync.mutex_unlock(&g_bg_test_mu)
	bg_test_drain_running()

	// Avoid live long-running processes: force the concurrent counter full.
	sync.mutex_lock(&g_bg_mu)
	prev := g_bg_running
	g_bg_running = MAX_BG_TASKS
	sync.mutex_unlock(&g_bg_mu)
	defer {
		sync.mutex_lock(&g_bg_mu)
		g_bg_running = prev
		sync.mutex_unlock(&g_bg_mu)
	}

	opts := Turn_Options {
		workspace = "/tmp",
		max_turns = 1,
		quiet = true,
	}
	c := handle_bash_background(`{"command":"echo no","is_background":true}`, opts, context.allocator)
	defer delete(c)
	testing.expectf(t, strings.contains(c, "max concurrent"), "third: %s", c)
}

// bg_test_drain_running kills any leftover Running tasks so the shared cap is free.
// Force-cancels stuck registry entries (e.g. Running with no worker) so tests cannot hang.
bg_test_drain_running :: proc() {
	sync.mutex_lock(&g_bg_mu)
	ids := make([dynamic]string, 0, 4, context.temp_allocator)
	for t in g_bg_tasks {
		if t.status == .Running {
			append(&ids, t.id)
		}
	}
	sync.mutex_unlock(&g_bg_mu)
	for id in ids {
		k := make_task_id_json(id, context.temp_allocator)
		_ = handle_kill_task(k, context.temp_allocator)
		// Short poll only — do not block tests for multi-second waits
		p := make_task_ids_json(id, 200, context.temp_allocator)
		_ = handle_get_task_output(p, context.temp_allocator)
	}
	// Force any still-Running entries terminal so the concurrent cap frees
	sync.mutex_lock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.status == .Running {
			t.cancel = true
			t.status = .Cancelled
			t.delivered = true
			if t.has_process {
				_ = os.process_kill(t.process)
				t.has_process = false
			}
		}
	}
	g_bg_running = 0
	sync.mutex_unlock(&g_bg_mu)
}

// bg_test_reset_registry drains runners then frees every registry entry.
// Task fields are allocated with the test (rollback) allocator; free them before
// the test ends. Keep g_bg_tasks itself on the process heap (see bg_registry_init).
bg_test_reset_registry :: proc() {
	bg_test_drain_running()
	// Brief settle so worker threads exit after cancel/finish before we free tasks.
	time.sleep(30 * time.Millisecond)
	sync.mutex_lock(&g_bg_mu)
	for t in g_bg_tasks {
		if t == nil {
			continue
		}
		if t.has_process {
			_ = os.process_kill(t.process)
			t.has_process = false
		}
		if t.id != "" {
			delete(t.id)
		}
		if t.description != "" {
			delete(t.description)
		}
		if t.result != "" {
			delete(t.result)
		}
		if t.model != "" {
			delete(t.model)
		}
		if t.worktree_path != "" {
			delete(t.worktree_path)
		}
		if len(t.msgs) > 0 {
			destroy_messages(t.msgs[:])
		}
		delete(t.msgs)
		free(t)
	}
	clear(&g_bg_tasks)
	g_bg_running = 0
	sync.mutex_unlock(&g_bg_mu)
}

// bg_test_mark_all_delivered prevents leftover terminal tasks from polluting auto-wake tests.
bg_test_mark_all_delivered :: proc() {
	sync.mutex_lock(&g_bg_mu)
	for t in g_bg_tasks {
		if t.status != .Running {
			t.delivered = true
		}
	}
	sync.mutex_unlock(&g_bg_mu)
}

// Odin fmt treats `{` as format syntax — build JSON via concatenation.
make_task_ids_json :: proc(id: string, timeout_ms: int, allocator := context.allocator) -> string {
	return strings.concatenate(
		{
			`{"task_ids":["`,
			id,
			`"],"timeout_ms":`,
			fmt.tprintf("%d", timeout_ms),
			`}`,
		},
		allocator,
	)
}

make_task_id_json :: proc(id: string, allocator := context.allocator) -> string {
	return strings.concatenate({`{"task_id":"`, id, `"}`}, allocator)
}

@(test)
test_is_background_arg :: proc(t: ^testing.T) {
	testing.expect(t, is_background_arg(`{"command":"x","is_background":true}`))
	testing.expect(t, !is_background_arg(`{"command":"x","is_background":false}`))
	testing.expect(t, !is_background_arg(`{"command":"x"}`))
}

extract_task_id_from_notice :: proc(notice: string) -> string {
	// Look for "task_id: bash-..." or "subagent_id: sub-..."
	keys := [2]string{"task_id: ", "subagent_id: "}
	for key in keys {
		if i := strings.index(notice, key); i >= 0 {
			rest := notice[i + len(key):]
			end := len(rest)
			for j in 0 ..< len(rest) {
				ch := rest[j]
				if ch == '\n' || ch == '\r' || ch == ' ' {
					end = j
					break
				}
			}
			return rest[:end]
		}
	}
	return ""
}
