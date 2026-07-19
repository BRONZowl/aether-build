package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:tools"

@(test)
test_is_scaffold_and_process_dream :: proc(t: ^testing.T) {
	testing.expect(
		t,
		is_scaffold_template(
			"# Project Memory\n\n> Auto-populated by dream consolidation. Edit freely.\n",
		),
	)
	testing.expect(t, !is_scaffold_template("## Real content\n\nLots of durable notes here that exceed scaffold and have no marker strings at all for sure"))

	c, ok, r := process_dream_response("NO_REPLY", MAX_DREAM_CHARS, context.allocator)
	defer delete(c)
	defer delete(r)
	testing.expect(t, !ok)

	c2, ok2, r2 := process_dream_response("no headers here", MAX_DREAM_CHARS, context.allocator)
	defer delete(c2)
	defer delete(r2)
	testing.expect(t, !ok2)

	c3, ok3, r3 := process_dream_response(
		"## Decisions\n\n- Keep A2.2 thin\n",
		MAX_DREAM_CHARS,
		context.allocator,
	)
	defer delete(c3)
	defer delete(r3)
	testing.expect(t, ok3)
	testing.expect(t, strings.contains(c3, "A2.2"))
}

@(test)
test_dream_heuristic_writes_memory_md :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/aether-dream-run-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev_env := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	defer {
		if prev_env != "" {
			os.set_env("AETHER_MEMORY_DIR", prev_env)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
	}

	dir := fmt.aprintf("/tmp/aether-dream-sess-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	// Seed old session log (force mtime old via write then leave; recency may skip cleanup)
	_, aerr := tools.memory_append_session_log(
		dir,
		"## Decisions & rationale\n\n- Use dream to merge UniqueDreamToken into MEMORY.md\n",
		context.allocator,
	)
	testing.expectf(t, aerr == "", "append: %s", aerr)

	// Existing scaffold should not block
	_, werr := tools.memory_write_workspace_md(
		dir,
		"# Project Memory\n\n> Auto-populated by dream consolidation. Edit freely.\n",
		context.allocator,
	)
	testing.expect(t, werr == "")

	out := run_memory_dream(&sess, "test-model", true, true /* heuristic */, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "dream complete"), "got: %s", out)
	testing.expect(t, strings.contains(out, "heuristic"))

	md := tools.memory_read_workspace_md(dir, context.allocator)
	defer delete(md)
	testing.expectf(t, strings.contains(md, "UniqueDreamToken") || strings.contains(md, "Workspace memory"), "md: %s", md)
	testing.expect(t, strings.contains(md, "##"))

	// Search should find durable note
	search := tools.tool_memory_search(
		`{"query":"UniqueDreamToken"}`,
		dir,
		context.allocator,
	)
	defer delete(search)
	// May hit session log still present (recency) or MEMORY.md
	testing.expectf(
		t,
		strings.contains(search, "UniqueDreamToken") || strings.contains(search, "Found"),
		"search: %s",
		search,
	)

	// Status
	st := dream_status_text(dir, context.allocator)
	defer delete(st)
	testing.expect(t, strings.contains(st, "dream:"))
	testing.expect(t, strings.contains(st, "sessions:"))
}

@(test)
test_dream_slash_help_and_empty :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-dream-slash-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	root := fmt.aprintf("/tmp/aether-dream-slash-mem-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	prev_env := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	defer {
		if prev_env != "" {
			os.set_env("AETHER_MEMORY_DIR", prev_env)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
	}

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	help := handle_dream_slash(&sess, "m", "help", context.allocator)
	defer delete(help)
	testing.expect(t, strings.contains(help, "/dream"))

	empty := handle_dream_slash(&sess, "m", "heuristic", context.allocator)
	defer delete(empty)
	testing.expect(t, strings.contains(empty, "no session") || strings.contains(empty, "nothing"))
}
