// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_isolation_from_string :: proc(t: ^testing.T) {
	m, ok := isolation_from_string("")
	testing.expect(t, ok && m == .None)
	m, ok = isolation_from_string("none")
	testing.expect(t, ok && m == .None)
	m, ok = isolation_from_string("worktree")
	testing.expect(t, ok && m == .Worktree)
	m, ok = isolation_from_string("WORKTREE")
	testing.expect(t, ok && m == .Worktree)
	_, ok = isolation_from_string("container")
	testing.expect(t, !ok)
}

@(test)
test_worktree_enabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_WORKTREE", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_WORKTREE")
		} else {
			_ = os.set_env("AETHER_NO_WORKTREE", prev)
		}
	}
	_ = os.unset_env("AETHER_NO_WORKTREE")
	testing.expect(t, worktree_enabled())
	_ = os.set_env("AETHER_NO_WORKTREE", "1")
	testing.expect(t, !worktree_enabled())
}

@(test)
test_repo_slug_from_path :: proc(t: ^testing.T) {
	s := repo_slug_from_path("/tmp/my repo!", context.allocator)
	defer delete(s)
	testing.expect(t, s == "my_repo_")
}

@(test)
test_create_subagent_worktree_temp_repo :: proc(t: ^testing.T) {
	if !worktree_enabled() {
		return
	}
	// Need git
	st, _, _, err := os.process_exec({command = {"git", "--version"}}, context.temp_allocator)
	if err != nil || st.exit_code != 0 {
		return // skip when git missing
	}

	tmp, terr := os.make_directory_temp("/tmp", "aether-wt-", context.allocator)
	testing.expect(t, terr == nil)
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	// Init repo with one commit
	run_git :: proc(args: []string, cwd: string) -> bool {
		state, _, _, e := os.process_exec({command = args, working_dir = cwd}, context.temp_allocator)
		return e == nil && state.exit_code == 0
	}
	testing.expect(t, run_git({"git", "init"}, tmp))
	testing.expect(t, run_git({"git", "config", "user.email", "t@t.com"}, tmp))
	testing.expect(t, run_git({"git", "config", "user.name", "t"}, tmp))
	f, _ := filepath.join({tmp, "hello.txt"}, context.temp_allocator)
	_ = os.write_entire_file(f, transmute([]byte)string("main-content\n"))
	testing.expect(t, run_git({"git", "add", "hello.txt"}, tmp))
	testing.expect(t, run_git({"git", "commit", "-m", "init"}, tmp))

	// Use temp base for worktrees
	prev_base := os.get_env("AETHER_WORKTREE_DIR", context.temp_allocator)
	wt_base, _ := filepath.join({tmp, "wts"}, context.temp_allocator)
	_ = os.set_env("AETHER_WORKTREE_DIR", wt_base)
	defer {
		if prev_base == "" {
			_ = os.unset_env("AETHER_WORKTREE_DIR")
		} else {
			_ = os.set_env("AETHER_WORKTREE_DIR", prev_base)
		}
	}

	path, cerr := create_subagent_worktree(tmp, "sub-test-1", context.allocator)
	testing.expectf(t, cerr == "", "create err: %s", cerr)
	defer delete(path)
	testing.expect(t, os.is_directory(path))
	// File from commit visible
	hf, _ := filepath.join({path, "hello.txt"}, context.temp_allocator)
	data, _ := os.read_entire_file(hf, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), "main-content"))

	// Edit only in worktree
	_ = os.write_entire_file(hf, transmute([]byte)string("worktree-only\n"))
	main_data, _ := os.read_entire_file(f, context.temp_allocator)
	testing.expect(t, strings.contains(string(main_data), "main-content"))
	testing.expect(t, !strings.contains(string(main_data), "worktree-only"))
}

@(test)
test_git_toplevel_not_repo :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("/tmp", "aether-nongit-", context.allocator)
	if terr != nil {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}
	_, err := git_toplevel(tmp, context.allocator)
	testing.expect(t, err != "")
	testing.expect(t, strings.has_prefix(err, "error:"))
	delete(err)
}

@(test)
test_create_worktree_disabled :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_WORKTREE", context.temp_allocator)
	_ = os.set_env("AETHER_NO_WORKTREE", "1")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_WORKTREE")
		} else {
			_ = os.set_env("AETHER_NO_WORKTREE", prev)
		}
	}
	_, err := create_subagent_worktree("/tmp", "x", context.allocator)
	testing.expect(t, strings.contains(err, "disabled"))
	delete(err)
}
