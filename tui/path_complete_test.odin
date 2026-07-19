package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_detect_path_token_at :: proc(t: ^testing.T) {
	tok, ok := detect_path_token("see @src/foo", 12)
	testing.expect(t, ok)
	testing.expect(t, tok.is_at)
	testing.expect(t, tok.path_part == "src/foo", tok.path_part)
	// email not at-complete
	_, ok2 := detect_path_token("user@example.com", 16)
	testing.expect(t, !ok2)
	// bare path with slash
	tok3, ok3 := detect_path_token("./a/b", 5)
	testing.expect(t, ok3 && !tok3.is_at)
	testing.expect(t, tok3.path_part == "./a/b")
}

@(test)
test_split_dir_base :: proc(t: ^testing.T) {
	d, b := split_dir_base("src/fo")
	testing.expect(t, d == "src" && b == "fo")
	d2, b2 := split_dir_base("src/")
	testing.expect(t, d2 == "src" && b2 == "")
	d3, b3 := split_dir_base("file")
	testing.expect(t, d3 == "" && b3 == "file")
}

@(test)
test_collect_path_matches_tmpdir :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-path-comp-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/alpha.txt", dir), transmute([]byte)string("a"))
	_ = os.write_entire_file(fmt.tprintf("%s/alpine.md", dir), transmute([]byte)string("b"))
	_ = os.make_directory_all(fmt.tprintf("%s/src", dir))

	ms := make([dynamic]string, 0, 8, context.allocator)
	defer {
		for m in ms {
			delete(m)
		}
		delete(ms)
	}
	collect_path_matches(dir, "alp", &ms, context.allocator)
	testing.expectf(t, len(ms) >= 2, "got %d", len(ms))
	joined := strings.join(ms[:], ",", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "alpha") || strings.contains(joined, "alpine"))

	for m in ms {
		delete(m)
	}
	clear(&ms)
	collect_path_matches(dir, "s", &ms, context.allocator)
	has_src := false
	for m in ms {
		if m == "src/" {
			has_src = true
		}
	}
	testing.expect(t, has_src)
}

@(test)
test_try_path_tab_complete_at :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-path-tab-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/readme.md", dir), transmute([]byte)string("hi"))

	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	input_set_text(&st, "@read")
	st.cursor = len(st.input)
	testing.expect(t, try_path_tab_complete(&st, dir))
	got := input_text(&st)
	testing.expectf(t, strings.contains(got, "readme"), "got %q", got)
}

@(test)
test_collect_workspace_path_matches_nested :: proc(t: ^testing.T) {
	// Needs rg; skip quietly if missing
	dir := fmt.tprintf("/tmp/aether-ws-path-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(fmt.tprintf("%s/nested/deep", dir))
	_ = os.write_entire_file(
		fmt.tprintf("%s/nested/deep/unique_b24_marker.odin", dir),
		transmute([]byte)string("x"),
	)
	ms := make([dynamic]string, 0, 8, context.allocator)
	defer {
		for m in ms {
			delete(m)
		}
		delete(ms)
	}
	ok := collect_workspace_path_matches(dir, "unique_b24", &ms, context.allocator)
	if !ok && len(ms) == 0 {
		// rg not installed — skip
		return
	}
	testing.expectf(t, len(ms) >= 1, "expected workspace hit, got %d", len(ms))
	joined := strings.join(ms[:], ",", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "unique_b24_marker"))
}
