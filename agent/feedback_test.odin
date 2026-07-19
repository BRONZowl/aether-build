package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_append_session_feedback_jsonl :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-feedback-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	// Force path under temp dir
	delete(sess.path)
	sess.path = strings.clone(fmt.tprintf("%s/%s.json", dir, sess.id))

	p1, e1 := append_session_feedback(&sess, "  first note about lag  ", context.allocator)
	defer delete(p1)
	testing.expectf(t, e1 == "", "e1: %s", e1)
	testing.expect(t, strings.has_suffix(p1, "feedback.jsonl"))

	p2, e2 := append_session_feedback(&sess, "second note", context.allocator)
	defer delete(p2)
	testing.expect(t, e2 == "")
	testing.expect(t, p1 == p2)

	data, rerr := os.read_entire_file(p1, context.allocator)
	defer delete(data)
	testing.expect(t, rerr == nil)
	text := string(data)
	testing.expect(t, strings.contains(text, "first note about lag"))
	testing.expect(t, strings.contains(text, "second note"))
	testing.expect(t, strings.contains(text, sess.id))
	testing.expect(t, strings.contains(text, "user_feedback"))
	// two lines
	n := 0
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			n += 1
		}
	}
	testing.expect(t, n >= 2)

	_, e3 := append_session_feedback(&sess, "   ", context.allocator)
	testing.expect(t, e3 != "")
}

@(test)
test_feedback_slash_help_and_save :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-feedback-slash-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	delete(sess.path)
	sess.path = strings.clone(fmt.tprintf("%s/sess.json", dir))

	help := handle_feedback_slash(&sess, "help", context.allocator)
	defer delete(help)
	testing.expect(t, strings.contains(help, "Usage"))
	testing.expect(t, strings.contains(help, "feedback.jsonl"))

	n0 := len(sess.msgs)
	out := handle_feedback_slash(&sess, "ui feels snappy", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "feedback saved"))
	testing.expect(t, len(sess.msgs) == n0)

	path := feedback_jsonl_path(&sess, context.temp_allocator)
	testing.expect(t, os.exists(path))
	_ = filepath.base(path)
}
