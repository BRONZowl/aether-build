package core

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_format_cwd_display_home_collapse :: proc(t: ^testing.T) {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return // skip when no home
	}
	got := format_cwd_display(home, context.allocator)
	defer delete(got)
	testing.expect(t, got == "~", got)

	sub, _ := filepath.join({home, "proj", "x"}, context.temp_allocator)
	got2 := format_cwd_display(sub, context.allocator)
	defer delete(got2)
	testing.expect(t, strings.has_prefix(got2, "~/"), got2)
	testing.expect(t, strings.contains(got2, "proj"), got2)
}

@(test)
test_git_branch_read_non_repo :: proc(t: ^testing.T) {
	// /tmp is usually not a git root of itself for empty path walk — use a fresh temp
	dir, err := os.make_directory_temp("/tmp", "aether-git-", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	b := git_branch_read(dir, context.allocator)
	defer delete(b)
	testing.expect(t, b == "", b)
}

@(test)
test_parse_git_head_ref :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-githead-", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "HEAD"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]byte)string("ref: refs/heads/feature/tui-chrome\n"))
	b := parse_git_head_file(path, context.allocator)
	defer delete(b)
	testing.expect(t, b == "feature/tui-chrome", b)
}
