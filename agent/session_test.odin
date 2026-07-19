package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_session_round_trip :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-sess-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	s := new_session("grok-test", "/tmp/ws", dir, true, .Always_Approve)
	defer destroy_session(&s)

	append(
		&s.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("hello"),
		},
	)
	tc := Tool_Call {
		id        = strings.clone("call_1"),
		name      = strings.clone("list_dir"),
		arguments = strings.clone(`{"target_directory":"."}`),
	}
	tcs := make([]Tool_Call, 1)
	tcs[0] = tc
	append(
		&s.msgs,
		Chat_Message {
			role       = .Assistant,
			content    = strings.clone(""),
			tool_calls = tcs,
		},
	)
	append(
		&s.msgs,
		Chat_Message {
			role         = .Tool,
			content      = strings.clone("file.txt"),
			tool_call_id = strings.clone("call_1"),
		},
	)
	append(
		&s.msgs,
		Chat_Message {
			role    = .Assistant,
			content = strings.clone("done"),
		},
	)
	delete(s.title)
	s.title = strings.clone("unit-test")

	// session_save snapshots global plan flag — isolate from parallel plan tests
	prev_plan := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev_plan)
	clear_plan_mode_for_new_session()
	s.plan_mode = false

	err := session_save(&s)
	testing.expectf(t, err == "", "save: %s", err)
	testing.expect(t, os.exists(s.path), "file exists")

	loaded, lerr := session_load_file(s.path, true)
	testing.expectf(t, lerr == "", "load: %s", lerr)
	defer destroy_session(&loaded)

	testing.expect(t, loaded.id == s.id, "id")
	testing.expect(t, loaded.title == "unit-test", "title")
	testing.expect(t, len(loaded.msgs) == len(s.msgs), "msg count")
	testing.expect(t, loaded.msgs[1].role == .User, "user role")
	testing.expect(t, loaded.msgs[1].content == "hello", "user content")
	testing.expect(t, loaded.msgs[2].role == .Assistant, "asst role")
	testing.expect(t, len(loaded.msgs[2].tool_calls) == 1, "tool_calls")
	testing.expect(t, loaded.msgs[2].tool_calls[0].name == "list_dir", "tool name")
	testing.expect(t, loaded.msgs[3].role == .Tool, "tool role")
	testing.expect(t, loaded.msgs[3].tool_call_id == "call_1", "tool_call_id")
	testing.expect(t, loaded.msgs[4].content == "done", "final content")
	testing.expect(t, !loaded.plan_mode, "plan_mode false when saved off")
}

@(test)
test_session_plan_mode_persist :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()

	dir := fmt.tprintf("/tmp/aether-sess-plan-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	s := new_session("grok-test", "/tmp/ws", dir, true, .Always_Approve)
	defer destroy_session(&s)

	g_plan.state = .Active
	g_plan.was_previously_active = true
	s.plan_mode = true
	err := session_save(&s)
	testing.expectf(t, err == "", "save: %s", err)

	// Clear before load
	clear_plan_mode_for_new_session()

	loaded, lerr := session_load_file(s.path, true)
	testing.expectf(t, lerr == "", "load: %s", lerr)
	defer destroy_session(&loaded)

	testing.expect(t, loaded.plan_mode == true, "loaded plan_mode")
	testing.expect(t, plan_mode_is_active(), "global restored")
	testing.expect(t, g_plan.resume_activation, "resume re-brief armed")
}

@(test)
test_sanitize_session_key :: proc(t: ^testing.T) {
	s := sanitize_session_key("My Session!/../x", context.temp_allocator)
	for i in 0 ..< len(s) {
		testing.expect(t, s[i] != '/', "no slash")
		testing.expect(t, s[i] != '!', "no bang")
	}
	testing.expect(t, len(s) > 0, "non-empty")
}

@(test)
test_session_title_from_text :: proc(t: ^testing.T) {
	got := session_title_from_text("  hello   world  \nnext", 60, context.temp_allocator)
	testing.expect(t, got == "hello world", got)
	long := session_title_from_text(
		"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ extra",
		20,
		context.temp_allocator,
	)
	testing.expect(t, strings.has_suffix(long, "…"), long)
	testing.expect(t, len(long) <= 24, long) // 20 runes + ellipsis-ish
}

@(test)
test_session_ensure_title_on_save :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-sess-title-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	s := new_session("m", "/tmp/ws", dir, true, .Always_Approve)
	defer destroy_session(&s)
	testing.expect(t, s.title == "", "starts empty")
	append(
		&s.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("Fix the flaky test in auth"),
		},
	)
	err := session_save(&s)
	testing.expectf(t, err == "", "save: %s", err)
	testing.expect(t, s.title == "Fix the flaky test in auth", s.title)

	// explicit title not overwritten
	delete(s.title)
	s.title = strings.clone("My Name")
	append(
		&s.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("other"),
		},
	)
	err = session_save(&s)
	testing.expectf(t, err == "", "save2: %s", err)
	testing.expect(t, s.title == "My Name", s.title)
}

@(test)
test_resolve_session_substring_and_ambiguous :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-sess-resolve-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	s1 := new_session("m", "/tmp/ws", dir, true, .Always_Approve)
	delete(s1.title)
	s1.title = strings.clone("ZebraAlphaOnly")
	// Force unique id/path (generator can collide within the same second + pid).
	delete(s1.id)
	delete(s1.path)
	s1.id = strings.clone("resolve-alpha-id")
	s1.path = fmt.aprintf("%s/%s.json", dir, s1.id)
	testing.expectf(t, session_save(&s1) == "", "save1")
	id1 := strings.clone(s1.id)
	path1 := strings.clone(s1.path)
	destroy_session(&s1)

	s2 := new_session("m", "/tmp/ws", dir, true, .Always_Approve)
	delete(s2.title)
	s2.title = strings.clone("ZebraBetaOnly")
	delete(s2.id)
	delete(s2.path)
	s2.id = strings.clone("resolve-beta-id")
	s2.path = fmt.aprintf("%s/%s.json", dir, s2.id)
	testing.expectf(t, session_save(&s2) == "", "save2")
	path2 := strings.clone(s2.path)
	destroy_session(&s2)

	testing.expect(t, os.exists(path1), "file1")
	testing.expect(t, os.exists(path2), "file2")

	list, lerr := list_sessions(dir, context.temp_allocator)
	testing.expectf(t, lerr == "", "list: %s", lerr)
	testing.expectf(t, len(list) == 2, "list len %d", len(list))
	// B14: dashboard line includes msg count field
	line := format_session_list_line(list[0], false, 1, context.allocator)
	defer delete(line)
	testing.expect(t, strings.contains(line, list[0].id) || len(line) > 10)

	// unique substring on title
	path, err := resolve_session_ref("AlphaOnly", dir, context.temp_allocator)
	testing.expectf(t, err == "", "unique: %s", err)
	testing.expect(t, path == path1 || strings.has_suffix(path, filepath.base(path1)), path)

	// case-insensitive title exact
	path, err = resolve_session_ref("zebraalphaonly", dir, context.temp_allocator)
	testing.expectf(t, err == "", "case title: %s", err)

	// full id
	path, err = resolve_session_ref(id1, dir, context.temp_allocator)
	testing.expectf(t, err == "", "by id: %s", err)

	// ambiguous: shared prefix in both titles
	path, err = resolve_session_ref("Zebra", dir, context.temp_allocator)
	testing.expect(t, err != "", "expect ambiguous")
	testing.expect(t, strings.contains(err, "ambiguous"), err)
	_ = path
	delete(id1)
	delete(path1)
	delete(path2)
}

@(test)
test_session_set_title_fork_delete_export :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-sess-b21-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)

	prev_plan := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev_plan)
	clear_plan_mode_for_new_session()

	s := new_session("grok-test", "/tmp/ws", dir, true, .Always_Approve)
	defer destroy_session(&s)
	append(
		&s.msgs,
		Chat_Message{role = .User, content = strings.clone("fork me please")},
	)
	append(
		&s.msgs,
		Chat_Message{role = .Assistant, content = strings.clone("ok forked")},
	)
	testing.expectf(t, session_save(&s) == "", "save parent")
	parent_path := strings.clone(s.path)
	defer delete(parent_path)
	parent_id := strings.clone(s.id)
	defer delete(parent_id)

	// rename
	testing.expectf(t, session_set_title(&s, "  My Title  ") == "", "set title")
	testing.expect(t, s.title == "My Title", s.title)
	loaded, lerr := session_load_file(s.path, true)
	testing.expectf(t, lerr == "", "reload: %s", lerr)
	testing.expect(t, loaded.title == "My Title")
	destroy_session(&loaded)

	// fork
	forked, ferr := session_fork(s, "child-fork", context.allocator)
	testing.expectf(t, ferr == "", "fork: %s", ferr)
	defer destroy_session(&forked)
	testing.expect(t, forked.id != s.id)
	testing.expect(t, forked.path != s.path)
	testing.expect(t, forked.title == "child-fork")
	testing.expect(t, len(forked.msgs) == len(s.msgs))
	testing.expect(t, os.exists(forked.path))
	testing.expect(t, os.exists(parent_path), "parent still on disk")

	// export markdown
	exp, eerr := session_export_markdown(s, "", context.allocator)
	testing.expectf(t, eerr == "", "export: %s", eerr)
	defer delete(exp)
	testing.expect(t, os.exists(exp))
	data, rerr := os.read_entire_file(exp, context.allocator)
	testing.expect(t, rerr == nil)
	defer delete(data)
	body := string(data)
	testing.expect(t, strings.contains(body, "fork me please"))
	testing.expect(t, strings.contains(body, "## user") || strings.contains(body, "## user\n"))

	// B27: export JSON
	jexp, jerr := session_export(s, "json", context.allocator)
	testing.expectf(t, jerr == "", "export json: %s", jerr)
	defer delete(jexp)
	testing.expect(t, strings.has_suffix(jexp, ".json") || strings.contains(jexp, "export"))
	testing.expect(t, os.exists(jexp))
	jdata, jrerr := os.read_entire_file(jexp, context.allocator)
	testing.expect(t, jrerr == nil)
	defer delete(jdata)
	jbody := string(jdata)
	testing.expect(t, strings.contains(jbody, `"messages"`))
	testing.expect(t, strings.contains(jbody, "fork me please"))

	// parse_export_arg
	f1, p1 := parse_export_arg("json /tmp/x.json")
	testing.expect(t, f1 == .Json && p1 == "/tmp/x.json")
	f2, p2 := parse_export_arg("out.json")
	testing.expect(t, f2 == .Json && p2 == "out.json")
	f3, p3 := parse_export_arg("md")
	testing.expect(t, f3 == .Markdown && p3 == "")

	// B29: import JSON export as new session
	imp, ierr := session_import_file(jexp, dir, true, context.allocator)
	testing.expectf(t, ierr == "", "import: %s", ierr)
	defer destroy_session(&imp)
	testing.expect(t, imp.id != s.id)
	testing.expect(t, imp.path != jexp)
	testing.expect(t, os.exists(imp.path))
	testing.expect(t, len(imp.msgs) == len(s.msgs))
	// source export still present
	testing.expect(t, os.exists(jexp))

	// delete fork by id; current is parent path
	testing.expectf(
		t,
		session_delete_by_ref(forked.id, dir, s.path) == "",
		"delete fork",
	)
	testing.expect(t, !os.exists(forked.path))

	// refuse delete current
	err := session_delete_by_ref(parent_id, dir, s.path)
	testing.expect(t, err != "")
	testing.expect(t, strings.contains(err, "current"))
}
