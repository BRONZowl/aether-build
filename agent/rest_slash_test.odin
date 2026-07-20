package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"
import "aether:tools"

@(test)
test_rest_slash_docs_cd_tasks_recap :: proc(t: ^testing.T) {
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

	dir := fmt.tprintf("/tmp/aether-rest-slash-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	// nested target for /cd
	sub, _ := strings.concatenate({dir, "/sub"}, context.temp_allocator)
	_ = os.make_directory_all(sub)

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

	model := strings.clone("m")
	cwd := strings.clone(dir)
	defer delete(model)
	defer delete(cwd)

	lines := make([dynamic]string, 0, 16)
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
	perm := core.Permission_Mode.Always_Approve

	// /docs
	clear_lines :: proc(lines: ^[dynamic]string) {
		for s in lines {
			delete(s)
		}
		clear(lines)
	}
	act := run_slash(&sess, "/docs", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "docs") || strings.contains(joined, "/help"))
	clear_lines(&lines)

	// /cd
	act = run_slash(&sess, fmt.tprintf("/cd %s", sub), opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "cwd") || strings.contains(joined, sub))
	testing.expect(t, strings.contains(cwd, "sub") || cwd == sub)
	clear_lines(&lines)

	// bare /cd status
	act = run_slash(&sess, "/cd", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "cwd"))
	clear_lines(&lines)

	// /tasks
	act = run_slash(&sess, "/tasks", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "tasks") || strings.contains(joined, "Background"))
	clear_lines(&lines)

	// /queue
	act = run_slash(&sess, "/queue", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(strings.to_lower(joined, context.temp_allocator), "queue"))
	clear_lines(&lines)

	// /recap
	act = run_slash(&sess, "/recap", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "recap") || strings.contains(joined, "hello"))
	clear_lines(&lines)

	// /privacy
	act = run_slash(&sess, "/privacy", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(strings.to_lower(joined, context.temp_allocator), "privacy"))
	clear_lines(&lines)

	// /terminal-setup
	act = run_slash(&sess, "/terminal-setup", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "TERM") || strings.contains(joined, "terminal"))
	clear_lines(&lines)

	// /share
	act = run_slash(&sess, "/share", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "export") || strings.contains(joined, "share"))
	clear_lines(&lines)

	// /voice
	act = run_slash(&sess, "/voice", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Continue)
	joined = strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "not available") || strings.contains(joined, "voice"))
	clear_lines(&lines)

	// /home → new session
	act = run_slash(&sess, "/home", opts, &model, &cwd, &perm, out)
	testing.expect(t, act == .Session_Changed)
	// system-only after new
	user_n := 0
	for m in sess.msgs {
		if m.role == .User {
			user_n += 1
		}
	}
	testing.expect(t, user_n == 0)
	_ = tools.todo_open_count()
}

@(test)
test_rest_slash_transcript_export :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-transcript-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

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
