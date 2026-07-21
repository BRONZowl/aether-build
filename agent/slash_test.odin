// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"
import "aether:tools"

// test harness sink target
g_test_slash_lines: ^[dynamic]string

@(test)
test_slash_help_and_unknown :: proc(t: ^testing.T) {
	// Isolate global skills registry (other tests may install/free it).
	defer maybe_stop_skills(nil)
	prev_sk := os.get_env("AETHER_NO_SKILLS", context.temp_allocator)
	_ = os.set_env("AETHER_NO_SKILLS", "1")
	defer {
		if prev_sk != "" {
			_ = os.set_env("AETHER_NO_SKILLS", prev_sk)
		} else {
			_ = os.unset_env("AETHER_NO_SKILLS")
		}
	}

	dir := fmt.tprintf("/tmp/aether-slash-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	model := strings.clone("test-model")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)

	lines := make([dynamic]string, 0, 8)
	defer {
		for s in lines {
			delete(s)
		}
		delete(lines)
	}
	g_test_slash_lines = &lines
	defer g_test_slash_lines = nil
	out :: proc(line: string) {
		if g_test_slash_lines != nil {
			append(g_test_slash_lines, strings.clone(line))
		}
	}

	opts := Headless_Options {
		quiet = true,
	}
	perm := core.Permission_Mode.Always_Approve
	act := run_slash(&sess, "/help", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue, "help continues")
	testing.expect(t, len(lines) > 0, "help emits lines")
	// free help lines before next command
	for s in lines {
		delete(s)
	}
	clear(&lines)

	act = run_slash(&sess, "/nosuch", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue, "unknown continues")
	testing.expect(t, len(lines) > 0, "unknown emits")
	for s in lines {
		delete(s)
	}
	clear(&lines)

	act = run_slash(&sess, "/exit", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Exit, "exit")
}

@(test)
test_slash_todos_list_and_clear :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-slash-todos-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	model := strings.clone("test-model")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)

	lines := make([dynamic]string, 0, 8)
	defer {
		for s in lines {
			delete(s)
		}
		delete(lines)
	}
	g_test_slash_lines = &lines
	defer g_test_slash_lines = nil
	out :: proc(line: string) {
		if g_test_slash_lines != nil {
			append(g_test_slash_lines, strings.clone(line))
		}
	}

	opts := Headless_Options {
		quiet = true,
	}
	tools.todo_clear()
	perm := core.Permission_Mode.Always_Approve
	act := run_slash(&sess, "/todos", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "No tasks"))
	for s in lines {
		delete(s)
	}
	clear(&lines)

	_ = tools.tool_todo_write(
		`{"merge":false,"todos":[{"id":"1","content":"Ship it","status":"pending"}]}`,
		context.temp_allocator,
	)
	act = run_slash(&sess, "/todos", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Ship it"))
	for s in lines {
		delete(s)
	}
	clear(&lines)

	act = run_slash(&sess, "/todos clear", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "cleared"))
	testing.expect(t, tools.todo_open_count() == 0)
	tools.todo_clear()
}

@(test)
test_slash_always_approve_and_btw :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-slash-perm-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	sess := new_session("m", dir, dir, false, .Ask)
	defer destroy_session(&sess)
	model := strings.clone("m")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)

	lines := make([dynamic]string, 0, 8)
	defer {
		for s in lines {
			delete(s)
		}
		delete(lines)
	}
	g_test_slash_lines = &lines
	defer g_test_slash_lines = nil
	out :: proc(line: string) {
		if g_test_slash_lines != nil {
			append(g_test_slash_lines, strings.clone(line))
		}
	}
	opts := Headless_Options{quiet = true}
	perm := core.Permission_Mode.Ask

	act := run_slash(&sess, "/always-approve on", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	testing.expect(t, perm == .Always_Approve)

	for s in lines {
		delete(s)
	}
	clear(&lines)

	act = run_slash(&sess, "/always-approve off", opts, &model, &cwd, &perm, out)
	testing.expect(t, perm == .Ask)

	for s in lines {
		delete(s)
	}
	clear(&lines)

	// Force offline /btw path so unit tests never hit the network
	prev_key := os.get_env("XAI_API_KEY", context.temp_allocator)
	prev_gkey := os.get_env("GROK_CODE_XAI_API_KEY", context.temp_allocator)
	prev_auth := os.get_env("GROK_AUTH", context.temp_allocator)
	prev_path := os.get_env("GROK_AUTH_PATH", context.temp_allocator)
	_ = os.unset_env("XAI_API_KEY")
	_ = os.unset_env("GROK_CODE_XAI_API_KEY")
	_ = os.unset_env("GROK_AUTH")
	_ = os.set_env("GROK_AUTH_PATH", "/tmp/aether-no-auth-btw-test")
	defer {
		if prev_key != "" {
			_ = os.set_env("XAI_API_KEY", prev_key)
		}
		if prev_gkey != "" {
			_ = os.set_env("GROK_CODE_XAI_API_KEY", prev_gkey)
		}
		if prev_auth != "" {
			_ = os.set_env("GROK_AUTH", prev_auth)
		}
		if prev_path != "" {
			_ = os.set_env("GROK_AUTH_PATH", prev_path)
		} else {
			_ = os.unset_env("GROK_AUTH_PATH")
		}
	}

	n_before := len(sess.msgs)
	act = run_slash(&sess, "/btw remember the auth path", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	testing.expect(t, len(sess.msgs) == n_before, "btw must not mutate session history")
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "btw:"))
	testing.expect(t, strings.contains(joined, "auth path"))
}

@(test)
test_slash_new_session_changed :: proc(t: ^testing.T) {
	defer maybe_stop_skills(nil)
	prev_sk := os.get_env("AETHER_NO_SKILLS", context.temp_allocator)
	_ = os.set_env("AETHER_NO_SKILLS", "1")
	defer {
		if prev_sk != "" {
			_ = os.set_env("AETHER_NO_SKILLS", prev_sk)
		} else {
			_ = os.unset_env("AETHER_NO_SKILLS")
		}
	}

	dir := fmt.tprintf("/tmp/aether-slash-new-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	sess := new_session("m1", dir, dir, false, .Ask)
	defer destroy_session(&sess)
	// dirty history so /new is meaningful
	append(
		&sess.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("hi"),
		},
	)
	old_count := len(sess.msgs)
	old_path := strings.clone(sess.path)
	defer delete(old_path)

	model := strings.clone("m1")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)

	opts := Headless_Options {
		quiet = true,
	}
	perm := core.Permission_Mode.Ask
	act := run_slash(&sess, "/new", opts, &model, &cwd, &perm, nil)
	testing.expect(t, act == .Session_Changed, "new session")
	testing.expect(t, len(sess.msgs) == 1, "fresh system-only history")
	testing.expect(t, old_count > 1, "had user msg before")
	// path should still be under sessions dir; id may collide in same second
	testing.expect(t, len(sess.id) > 0, "has id")
	testing.expect(t, sess.path != "" , "has path")
	_ = old_path
}

@(test)
test_conversation_rewind_turns :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-rewind-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	append(&sess.msgs, Chat_Message{role = .User, content = strings.clone("u1")})
	append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone("a1")})
	append(&sess.msgs, Chat_Message{role = .User, content = strings.clone("u2")})
	append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone("a2")})
	// system + 2 turns
	testing.expect(t, count_user_turns(sess.msgs[:]) == 2)
	before := len(sess.msgs)
	removed, err := conversation_rewind_turns(&sess, 1)
	testing.expect(t, err == "", err)
	testing.expect(t, removed == 1)
	testing.expect(t, len(sess.msgs) == before - 2) // dropped user+assistant
	testing.expect(t, count_user_turns(sess.msgs[:]) == 1)
	// remaining last user is u1
	last_user := ""
	for i := len(sess.msgs) - 1; i >= 0; i -= 1 {
		if sess.msgs[i].role == .User {
			last_user = sess.msgs[i].content
			break
		}
	}
	testing.expect(t, last_user == "u1")
}

@(test)
test_slash_model_effort_auto_rewind :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-slash-b3-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	sess := new_session("m0", dir, dir, false, .Ask)
	defer destroy_session(&sess)
	append(&sess.msgs, Chat_Message{role = .User, content = strings.clone("hi")})
	append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone("hello there")})

	model := strings.clone("m0")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)
	// reset effort from other tests
	_ = set_reasoning_effort("off")

	lines := make([dynamic]string, 0, 8)
	defer {
		for s in lines {
			delete(s)
		}
		delete(lines)
	}
	g_test_slash_lines = &lines
	defer g_test_slash_lines = nil
	out :: proc(line: string) {
		if g_test_slash_lines != nil {
			append(g_test_slash_lines, strings.clone(line))
		}
	}

	opts := Headless_Options {
		quiet = true,
	}
	perm := core.Permission_Mode.Ask

	act := run_slash(&sess, "/model grok-4.5", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	testing.expect(t, model == "grok-4.5")
	testing.expect(t, sess.model == "grok-4.5")

	act = run_slash(&sess, "/effort high", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	testing.expect(t, reasoning_effort_current() == "high")

	act = run_slash(&sess, "/auto", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	testing.expect(t, perm == .Auto)

	act = run_slash(&sess, "/auto", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	testing.expect(t, perm == .Ask)

	// conversation rewind
	before := len(sess.msgs)
	act = run_slash(&sess, "/rewind", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Session_Changed)
	testing.expect(t, len(sess.msgs) < before)
	testing.expect(t, count_user_turns(sess.msgs[:]) == 0)

	// copy with no assistant left → message
	for s in lines {
		delete(s)
	}
	clear(&lines)
	act = run_slash(&sess, "/copy", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined := ""
	for s in lines {
		joined = fmt.tprintf("%s\n%s", joined, s)
	}
	testing.expect(t, strings.contains(joined, "no assistant"))

	_ = set_reasoning_effort("off")
}
