// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"
import "aether:tools"

// Package-level helpers (avoid nested procs as Slash_Writer — flaky under CI).
@(private)
rest_test_clear_lines :: proc(lines: ^[dynamic]string) {
	for s in lines {
		delete(s)
	}
	clear(lines)
}

@(private)
rest_test_out :: proc(line: string) {
	if g_test_slash_lines != nil {
		append(g_test_slash_lines, strings.clone(line))
	}
}

@(test)
test_rest_slash_docs_cd_tasks_recap :: proc(t: ^testing.T) {
	// Earlier suite tests leave process-global bg tasks; wipe before /tasks walks them.
	bg_test_reset_registry()
	defer bg_test_reset_registry()

	// Isolate env so CI never hits network / GUI clipboard
	prev_sk := os.get_env("AETHER_NO_SKILLS", context.temp_allocator)
	prev_auth := os.get_env("GROK_AUTH_PATH", context.temp_allocator)
	prev_key := os.get_env("XAI_API_KEY", context.temp_allocator)
	prev_clip := os.get_env("AETHER_CLIPBOARD_FILE", context.temp_allocator)
	_ = os.set_env("AETHER_NO_SKILLS", "1")
	_ = os.set_env("GROK_AUTH_PATH", "/tmp/aether-no-auth-rest-slash")
	_ = os.unset_env("XAI_API_KEY")
	_ = os.unset_env("GROK_CODE_XAI_API_KEY")
	_ = os.set_env("AETHER_CLIPBOARD_FILE", "1")
	defer {
		if prev_sk != "" {
			_ = os.set_env("AETHER_NO_SKILLS", prev_sk)
		} else {
			_ = os.unset_env("AETHER_NO_SKILLS")
		}
		if prev_auth != "" {
			_ = os.set_env("GROK_AUTH_PATH", prev_auth)
		} else {
			_ = os.unset_env("GROK_AUTH_PATH")
		}
		if prev_key != "" {
			_ = os.set_env("XAI_API_KEY", prev_key)
		}
		if prev_clip != "" {
			_ = os.set_env("AETHER_CLIPBOARD_FILE", prev_clip)
		} else {
			_ = os.unset_env("AETHER_CLIPBOARD_FILE")
		}
	}

	dir := fmt.aprintf("/tmp/aether-rest-slash-%d", os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	sub := fmt.aprintf("%s/sub", dir)
	defer delete(sub)
	testing.expect(t, os.make_directory_all(sub) == nil)

	// --- unit handlers (no run_slash / no session mutation) ---
	docs := handle_docs_slash("", context.allocator)
	testing.expect(t, strings.contains(docs, "docs") || strings.contains(docs, "/help"), docs)
	delete(docs)

	msg, new_cwd := handle_cd_slash(sub, dir, context.allocator)
	testing.expect(t, strings.contains(msg, "cwd") || strings.contains(msg, "sub"), msg)
	testing.expect(t, new_cwd == sub || strings.contains(new_cwd, "sub"), new_cwd)
	delete(msg)
	delete(new_cwd)

	msg2, _ := handle_cd_slash("", dir, context.allocator)
	testing.expect(t, strings.contains(msg2, "cwd"), msg2)
	delete(msg2)

	tasks := handle_tasks_slash(context.allocator)
	testing.expect(
		t,
		strings.contains(tasks, "tasks") || strings.contains(tasks, "Background") || strings.contains(tasks, "bg"),
		tasks,
	)
	delete(tasks)

	queue := handle_queue_slash("", context.allocator)
	testing.expect(t, strings.contains(strings.to_lower(queue, context.temp_allocator), "queue"), queue)
	delete(queue)

	priv := handle_privacy_slash("", context.allocator)
	testing.expect(t, strings.contains(strings.to_lower(priv, context.temp_allocator), "privacy"), priv)
	delete(priv)

	term := handle_terminal_setup_slash(context.allocator)
	testing.expect(t, strings.contains(term, "TERM") || strings.contains(term, "terminal"), term)
	delete(term)

	voice := handle_voice_slash(context.allocator)
	testing.expect(
		t,
		strings.contains(voice, "not available") || strings.contains(voice, "voice"),
		voice,
	)
	delete(voice)

	// --- session-backed handlers ---
	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	append(
		&sess.msgs,
		Chat_Message{role = .User, content = strings.clone("hello world from user")},
	)
	append(
		&sess.msgs,
		Chat_Message{role = .Assistant, content = strings.clone("assistant reply about widgets")},
	)

	recap := handle_recap_slash(&sess, "m", context.allocator)
	testing.expect(t, strings.contains(recap, "recap") || strings.contains(recap, "hello"), recap)
	delete(recap)

	share := handle_share_slash(&sess, context.allocator)
	testing.expect(t, strings.contains(share, "share") || strings.contains(share, "transcript"), share)
	delete(share)

	// light run_slash smoke (no /cd chdir, no /home session wipe)
	lines := make([dynamic]string, 0, 8)
	defer rest_test_clear_lines(&lines)
	defer delete(lines)
	g_test_slash_lines = &lines
	defer g_test_slash_lines = nil

	model := strings.clone("m")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)
	opts := Headless_Options {
		quiet = true,
	}
	perm := core.Permission_Mode.Always_Approve

	act := run_slash(&sess, "/docs", opts, &model, &cwd, &perm, rest_test_out)
	testing.expect(t, act == .Continue)
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "docs") || strings.contains(joined, "/help"), joined)
	rest_test_clear_lines(&lines)

	_ = tools.todo_open_count()
}

@(test)
test_rest_slash_transcript_export :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-transcript-%d", os.get_pid())
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)
	defer delete(dir)

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	append(&sess.msgs, Chat_Message{role = .User, content = strings.clone("u")})
	append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone("a")})

	path, err := handle_transcript_export(sess, context.allocator)
	testing.expect(t, err == "", err)
	testing.expect(t, path != "")
	testing.expect(t, os.exists(path))
	delete(path)
}

@(test)
test_catalog_has_new_grok_cmds :: proc(t: ^testing.T) {
	need := []string {
		"/docs",
		"/home",
		"/transcript",
		"/expand",
		"/tasks",
		"/queue",
		"/logout",
		"/privacy",
		"/release-notes",
		"/cd",
		"/dashboard",
		"/marketplace",
		"/config-agents",
		"/import-claude",
		"/share",
		"/voice",
		"/recap",
		"/terminal-setup",
		"/toggle-mouse-reporting",
	}
	for n in need {
		d := core.slash_desc_for(n)
		testing.expect(t, d != "", n)
	}
	// order: docs before new, home before new
	rows := make([dynamic]core.Slash_Match, 0, 64, context.temp_allocator)
	core.slash_collect_match_rows("/", &rows)
	idx :: proc(list: []core.Slash_Match, name: string) -> int {
		for i in 0 ..< len(list) {
			if list[i].name == name {
				return i
			}
		}
		return -1
	}
	idocs := idx(rows[:], "/docs")
	ihome := idx(rows[:], "/home")
	inew := idx(rows[:], "/new")
	itrans := idx(rows[:], "/transcript")
	iexport := idx(rows[:], "/export")
	testing.expect(t, idocs >= 0 && ihome >= 0 && inew >= 0)
	testing.expect(t, idocs < inew)
	testing.expect(t, ihome < inew)
	testing.expect(t, iexport >= 0 && itrans > iexport)
}
