package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_write_create_and_overwrite :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-write-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	out := tool_write(
		`{"file_path":"sub/nested.txt","content":"hello\n"}`,
		root,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "created") || strings.contains(out, "Wrote"))

	path, _ := filepath.join({root, "sub", "nested.txt"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, string(data) == "hello\n")

	out2 := tool_write(
		`{"file_path":"sub/nested.txt","content":"world"}`,
		root,
		context.allocator,
	)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "Wrote") || strings.contains(out2, "successfully"))
	data2, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, string(data2) == "world")
}

@(test)
test_write_outside_denied :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-write-ws-%d", os.get_pid())
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	out := tool_write(
		`{"file_path":"/etc/passwd","content":"x"}`,
		root,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "outside workspace") || strings.contains(out, "denied"))
}

@(test)
test_delete_file_ok_and_errors :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-del-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	p, _ := filepath.join({root, "gone.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "x")

	out := tool_delete_file(`{"target_file":"gone.txt"}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Deleted"))
	testing.expect(t, !os.exists(p))

	out2 := tool_delete_file(`{"file_path":"gone.txt"}`, root, context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "not found"))

	d, _ := filepath.join({root, "adir"}, context.temp_allocator)
	_ = os.make_directory_all(d)
	out3 := tool_delete_file(`{"target_file":"adir"}`, root, context.allocator)
	defer delete(out3)
	testing.expect(t, strings.contains(out3, "directory"))
}
