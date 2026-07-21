// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:tools"

@(test)
test_build_injection_from_workspace_md :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/aether-inject-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	defer {
		if prev != "" {
			os.set_env("AETHER_MEMORY_DIR", prev)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
	}

	cwd := "/tmp/inject-proj"
	_, werr := tools.memory_write_workspace_md(
		cwd,
		"## Decisions\n\n- InjectUniqueToken for first-turn memory\n",
		context.allocator,
	)
	testing.expect(t, werr == "")

	body := build_memory_injection_body(cwd, "hi", context.allocator)
	defer delete(body)
	testing.expectf(t, strings.contains(body, "InjectUniqueToken"), "got: %s", body)
	testing.expect(t, strings.contains(body, "Workspace MEMORY.md"))

	// Scaffold alone → empty
	_, _ = tools.memory_write_workspace_md(
		cwd,
		"# Project Memory\n\n> Auto-populated by dream consolidation. Edit freely.\n",
		context.allocator,
	)
	empty := build_memory_injection_body(cwd, "hi", context.allocator)
	defer delete(empty)
	testing.expect(t, strings.trim_space(empty) == "")
}

@(test)
test_ensure_memory_injection_latch :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/aether-inject-latch-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	// clear inject opt-out
	prev_inj := os.get_env("AETHER_NO_MEMORY_INJECT", context.temp_allocator)
	os.unset_env("AETHER_NO_MEMORY_INJECT")
	defer {
		if prev != "" {
			os.set_env("AETHER_MEMORY_DIR", prev)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
		if prev_inj != "" {
			os.set_env("AETHER_NO_MEMORY_INJECT", prev_inj)
		}
	}

	cwd := "/tmp/latch-proj"
	_, _ = tools.memory_write_workspace_md(
		cwd,
		"## Tech\n\n- LatchTokenAlpha\n",
		context.allocator,
	)

	msgs := make([dynamic]Chat_Message, 0, 4)
	defer destroy_messages(msgs[:])
	append(
		&msgs,
		Chat_Message{role = .System, content = strings.clone("You are a test agent.")},
	)
	append(&msgs, Chat_Message{role = .User, content = strings.clone("hello there friend")})

	latch := false
	ok := ensure_memory_injection_msgs(&msgs, cwd, "hello there friend", &latch)
	testing.expect(t, ok)
	testing.expect(t, latch)
	testing.expect(t, conversation_has_memory_context(msgs[:]))
	testing.expect(t, strings.contains(msgs[0].content, "LatchTokenAlpha"))

	// Second call no-ops
	ok2 := ensure_memory_injection_msgs(&msgs, cwd, "hello there friend", &latch)
	testing.expect(t, !ok2)
	// Only one marker
	n := 0
	rest := msgs[0].content
	for {
		idx := strings.index(rest, MEMORY_INJECT_MARKER)
		if idx < 0 {
			break
		}
		n += 1
		rest = rest[idx + len(MEMORY_INJECT_MARKER):]
	}
	testing.expect(t, n == 1)
}

@(test)
test_memory_inject_opt_out :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_MEMORY_INJECT", context.temp_allocator)
	os.set_env("AETHER_NO_MEMORY_INJECT", "1")
	defer {
		if prev != "" {
			os.set_env("AETHER_NO_MEMORY_INJECT", prev)
		} else {
			os.unset_env("AETHER_NO_MEMORY_INJECT")
		}
	}
	testing.expect(t, !memory_inject_enabled())
}

@(test)
test_maybe_auto_dream_silent_without_logs :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-autodream-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	root := fmt.aprintf("/tmp/aether-autodream-mem-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	prev := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	prev_auto := os.get_env("AETHER_NO_AUTO_DREAM", context.temp_allocator)
	os.unset_env("AETHER_NO_AUTO_DREAM")
	defer {
		if prev != "" {
			os.set_env("AETHER_MEMORY_DIR", prev)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
		if prev_auto != "" {
			os.set_env("AETHER_NO_AUTO_DREAM", prev_auto)
		}
	}

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	out := maybe_auto_dream(&sess, "m", context.allocator)
	defer delete(out)
	// No session logs → silent empty (or verbose would show skip; default quiet)
	testing.expect(t, out == "")
}

@(test)
test_maybe_auto_dream_with_enough_sessions :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-autodream2-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	root := fmt.aprintf("/tmp/aether-autodream2-mem-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	prev := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	prev_auto := os.get_env("AETHER_NO_AUTO_DREAM", context.temp_allocator)
	os.unset_env("AETHER_NO_AUTO_DREAM")
	// Force offline model path failure → heuristic inside run
	defer {
		if prev != "" {
			os.set_env("AETHER_MEMORY_DIR", prev)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
		if prev_auto != "" {
			os.set_env("AETHER_NO_AUTO_DREAM", prev_auto)
		}
	}

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	// Write 3 distinct session day files (min_sessions=3)
	_, _ = tools.memory_write_workspace_md(dir, "## seed\n\n- x\n", context.allocator)
	sess_dir := tools.memory_sessions_dir(dir, context.temp_allocator)
	_ = os.make_directory_all(sess_dir)
	days := [3]string{"2026-01-01", "2026-01-02", "2026-01-03"}
	for day in days {
		path, ok := tools.memory_session_file_path(dir, day, context.temp_allocator)
		testing.expect(t, ok)
		body := fmt.tprintf("## Session %s\n\n- AutoDreamToken%s\n", day, day)
		_ = os.write_entire_file(path, transmute([]byte)body)
	}

	// force=false path via maybe_auto_dream; may use model if creds - heuristic if not
	// Use run_memory_dream with force=false + heuristic to be deterministic
	out := run_memory_dream(&sess, "m", false, true, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "dream complete"), "got: %s", out)

	md := tools.memory_read_workspace_md(dir, context.allocator)
	defer delete(md)
	testing.expect(t, strings.contains(md, "AutoDreamToken") || strings.contains(md, "Workspace memory"))
}
