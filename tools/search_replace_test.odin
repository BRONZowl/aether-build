package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_search_replace_create_and_edit :: proc(t: ^testing.T) {
	ws := fmt.tprintf("/tmp/aether-sr-test-%d", os.get_pid())
	_ = os.remove_all(ws)
	err := os.make_directory(ws)
	testing.expect(t, err == nil, "mkdir workspace")
	defer os.remove_all(ws)

	create_args := `{"file_path":"hello.txt","old_string":"","new_string":"hello world"}`
	out := tool_search_replace(create_args, ws, context.allocator)
	testing.expectf(t, !starts_with_error(out), "create: %s", out)

	path, _ := filepath.join({ws, "hello.txt"}, context.allocator)
	defer delete(path)
	data, rerr := os.read_entire_file(path, context.allocator)
	testing.expect(t, rerr == nil, "read file after create")
	testing.expectf(t, string(data) == "hello world", "got %q", string(data))
	delete(data)

	edit_args := `{"file_path":"hello.txt","old_string":"hello","new_string":"hi"}`
	out2 := tool_search_replace(edit_args, ws, context.allocator)
	testing.expectf(t, !starts_with_error(out2), "edit: %s", out2)
	data2, rerr2 := os.read_entire_file(path, context.allocator)
	testing.expect(t, rerr2 == nil, "read after edit")
	testing.expectf(t, string(data2) == "hi world", "got %q", string(data2))
	delete(data2)
}

@(test)
test_search_replace_denies_outside_workspace :: proc(t: ^testing.T) {
	ws := fmt.tprintf("/tmp/aether-sr-deny-%d", os.get_pid())
	_ = os.remove_all(ws)
	err := os.make_directory(ws)
	testing.expect(t, err == nil, "mkdir")
	defer os.remove_all(ws)

	args := `{"file_path":"/etc/passwd","old_string":"","new_string":"nope"}`
	out := tool_search_replace(args, ws, context.allocator)
	testing.expect(t, starts_with_error(out), "should deny outside write")
}

@(test)
test_search_replace_all_and_not_unique :: proc(t: ^testing.T) {
	ws := fmt.tprintf("/tmp/aether-sr-all-%d", os.get_pid())
	_ = os.remove_all(ws)
	testing.expect(t, os.make_directory(ws) == nil)
	defer os.remove_all(ws)

	path, _ := filepath.join({ws, "m.txt"}, context.temp_allocator)
	_ = os.write_entire_file(path, "aa bb aa cc aa")

	// not unique without replace_all
	out := tool_search_replace(
		`{"file_path":"m.txt","old_string":"aa","new_string":"XX"}`,
		ws,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, starts_with_error(out))
	testing.expect(t, strings.contains(out, "not unique") || strings.contains(out, "replace_all"))

	out2 := tool_search_replace(
		`{"file_path":"m.txt","old_string":"aa","new_string":"XX","replace_all":true}`,
		ws,
		context.allocator,
	)
	defer delete(out2)
	testing.expect(t, !starts_with_error(out2))
	testing.expect(t, strings.contains(out2, "3"))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, string(data) == "XX bb XX cc XX")
}

starts_with_error :: proc(s: string) -> bool {
	return len(s) >= 6 && s[:6] == "error:"
}

@(test)
test_search_replace_flexible_case_and_newlines :: proc(t: ^testing.T) {
	ws := fmt.tprintf("/tmp/aether-sr-flex-%d", os.get_pid())
	_ = os.remove_all(ws)
	testing.expect(t, os.make_directory(ws) == nil)
	defer os.remove_all(ws)

	path, _ := filepath.join({ws, "f.txt"}, context.temp_allocator)

	// case-insensitive unique
	_ = os.write_entire_file(path, "Hello World")
	out := tool_search_replace(
		`{"file_path":"f.txt","old_string":"hello world","new_string":"Hi"}`,
		ws,
		context.allocator,
	)
	defer delete(out)
	testing.expectf(t, !starts_with_error(out), "ci: %s", out)
	testing.expect(t, strings.contains(out, "case-insensitive") || strings.contains(out, "updated"))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expectf(t, string(data) == "Hi", "got %q", string(data))

	// CRLF content + LF old_string
	_ = os.write_entire_file(path, "line1\r\nline2\r\n")
	out2 := tool_search_replace(
		`{"file_path":"f.txt","old_string":"line1\nline2","new_string":"X"}`,
		ws,
		context.allocator,
	)
	defer delete(out2)
	testing.expectf(t, !starts_with_error(out2), "nl: %s", out2)
	data2, err2 := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err2 == nil)
	// replaced span across CRLF; remainder may keep trailing \r\n
	testing.expect(t, strings.has_prefix(string(data2), "X"))
}

@(test)
test_find_old_string_span_helpers :: proc(t: ^testing.T) {
	i, n, how, err := find_old_string_span("abc", "nope")
	testing.expect(t, err != "")
	_ = i
	_ = n
	_ = how
	i2, n2, how2, err2 := find_old_string_span("AaBb", "aabb")
	testing.expect(t, err2 == "")
	testing.expect(t, how2 == "case-insensitive")
	testing.expect(t, i2 == 0 && n2 == 4)

	// whitespace-collapsed unique
	i3, n3, how3, err3 := find_old_string_span("foo   bar\tbaz", "foo bar baz")
	testing.expect(t, err3 == "")
	testing.expect(t, how3 == "whitespace-collapsed")
	testing.expect(t, i3 == 0 && n3 == len("foo   bar\tbaz"))
}

@(test)
test_search_replace_whitespace_collapsed :: proc(t: ^testing.T) {
	ws := fmt.tprintf("/tmp/aether-sr-ws-%d", os.get_pid())
	_ = os.remove_all(ws)
	testing.expect(t, os.make_directory(ws) == nil)
	defer os.remove_all(ws)
	path, _ := filepath.join({ws, "w.txt"}, context.temp_allocator)
	_ = os.write_entire_file(path, "alpha   beta\tgamma")
	out := tool_search_replace(
		`{"file_path":"w.txt","old_string":"alpha beta gamma","new_string":"OK"}`,
		ws,
		context.allocator,
	)
	defer delete(out)
	testing.expectf(t, !starts_with_error(out), "%s", out)
	testing.expect(t, strings.contains(out, "whitespace-collapsed") || strings.contains(out, "updated"))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expectf(t, string(data) == "OK", "got %q", string(data))
}
