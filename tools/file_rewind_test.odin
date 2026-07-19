package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_file_rewind_write_create_and_undo :: proc(t: ^testing.T) {
	file_rewind_clear()
	defer file_rewind_clear()
	os.unset_env("AETHER_NO_FILE_REWIND")

	dir := fmt.aprintf("/tmp/aether-rewind-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	path, _ := filepath.join({dir, "n.txt"}, context.temp_allocator)
	// create via write tool
	args := fmt.tprintf(`{{"file_path":%q,"content":"hello"}}`, path)
	out := tool_write(args, dir, context.temp_allocator)
	testing.expect(t, strings.contains(out, "created") || strings.contains(out, "Wrote"))
	testing.expect(t, os.exists(path))
	testing.expect(t, file_rewind_count() == 1)

	msg := file_rewind_undo(context.temp_allocator)
	testing.expect(t, strings.contains(msg, "rewound"))
	testing.expect(t, !os.exists(path), "create should be undone by delete")
	testing.expect(t, file_rewind_count() == 0)
}

@(test)
test_file_rewind_edit_restore :: proc(t: ^testing.T) {
	file_rewind_clear()
	defer file_rewind_clear()
	os.unset_env("AETHER_NO_FILE_REWIND")

	dir := fmt.aprintf("/tmp/aether-rewind-e-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	path, _ := filepath.join({dir, "e.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("alpha beta")) == nil)

	args := fmt.tprintf(
		`{{"file_path":%q,"old_string":"beta","new_string":"gamma"}}`,
		path,
	)
	out := tool_search_replace(args, dir, context.temp_allocator)
	testing.expect(t, strings.contains(out, "updated") || strings.contains(out, "replaced"))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, string(data) == "alpha gamma")

	msg := file_rewind_undo(context.temp_allocator)
	testing.expect(t, strings.contains(msg, "rewound"))
	data2, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, string(data2) == "alpha beta")
}

@(test)
test_file_rewind_delete_restore :: proc(t: ^testing.T) {
	file_rewind_clear()
	defer file_rewind_clear()
	os.unset_env("AETHER_NO_FILE_REWIND")

	dir := fmt.aprintf("/tmp/aether-rewind-d-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	path, _ := filepath.join({dir, "gone.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("keep-me")) == nil)

	args := fmt.tprintf(`{{"target_file":%q}}`, path)
	out := tool_delete_file(args, dir, context.temp_allocator)
	testing.expect(t, strings.contains(out, "Deleted"))
	testing.expect(t, !os.exists(path))

	msg := file_rewind_undo(context.temp_allocator)
	testing.expect(t, strings.contains(msg, "rewound"))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, string(data) == "keep-me")
}

@(test)
test_file_rewind_disabled :: proc(t: ^testing.T) {
	file_rewind_clear()
	defer file_rewind_clear()
	os.set_env("AETHER_NO_FILE_REWIND", "1")
	defer os.unset_env("AETHER_NO_FILE_REWIND")

	dir := fmt.aprintf("/tmp/aether-rewind-off-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	path, _ := filepath.join({dir, "x.txt"}, context.temp_allocator)
	args := fmt.tprintf(`{{"file_path":%q,"content":"z"}}`, path)
	_ = tool_write(args, dir, context.temp_allocator)
	testing.expect(t, file_rewind_count() == 0)
	msg := file_rewind_undo(context.temp_allocator)
	testing.expect(t, strings.contains(msg, "disabled"))
}

@(test)
test_grep_denies_outside_workspace :: proc(t: ^testing.T) {
	// absolute path outside workspace
	args := `{"pattern":"x","path":"/etc"}`
	out := tool_grep(args, "/tmp", context.temp_allocator)
	testing.expect(t, strings.contains(out, "outside workspace") || strings.contains(out, "denied"))
}
