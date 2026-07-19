package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:tools"

@(test)
test_is_no_reply_and_headers :: proc(t: ^testing.T) {
	testing.expect(t, is_no_reply("NO_REPLY"))
	testing.expect(t, is_no_reply("no reply"))
	testing.expect(t, is_no_reply("No-Reply"))
	testing.expect(t, is_no_reply("noreply"))
	testing.expect(t, !is_no_reply("no reply needed"))
	testing.expect(t, !is_no_reply("I have things to store"))

	testing.expect(t, has_markdown_headers("## Topic"))
	testing.expect(t, has_markdown_headers("# Title\n\nBody"))
	testing.expect(t, !has_markdown_headers("plain text without headers"))
	testing.expect(t, !has_markdown_headers("#hashtag without space"))
}

@(test)
test_process_flush_response :: proc(t: ^testing.T) {
	k, c, r := process_flush_response("NO_REPLY", FLUSH_MAX_WRITE_CHARS, context.allocator)
	defer delete(c)
	defer delete(r)
	testing.expect(t, k == .Nothing)

	k2, c2, r2 := process_flush_response("plain no structure", FLUSH_MAX_WRITE_CHARS, context.allocator)
	defer delete(c2)
	defer delete(r2)
	testing.expect(t, k2 == .Rejected)

	k3, c3, r3 := process_flush_response(
		"## Decisions & rationale\n\n- Ship A2.1\n",
		FLUSH_MAX_WRITE_CHARS,
		context.allocator,
	)
	defer delete(c3)
	defer delete(r3)
	testing.expect(t, k3 == .Accepted)
	testing.expect(t, strings.contains(c3, "Ship A2.1"))
}

@(test)
test_flush_heuristic_writes_session_log :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/aether-flush-test-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	// Point memory root via env (tools package override is private).
	prev_env := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator)
	os.set_env("AETHER_MEMORY_DIR", root)
	defer {
		if prev_env != "" {
			os.set_env("AETHER_MEMORY_DIR", prev_env)
		} else {
			os.unset_env("AETHER_MEMORY_DIR")
		}
	}

	dir := fmt.aprintf("/tmp/aether-flush-sess-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	append(
		&sess.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone("We decided to implement memory append under sessions/YYYY-MM-DD.md"),
		},
	)
	append(
		&sess.msgs,
		Chat_Message {
			role    = .Assistant,
			content = strings.clone(
				"Agreed. Write API uses memory_append_session_log with --- flush separators.",
			),
		},
	)

	out := run_memory_flush(&sess, "test-model", true /* force_heuristic */, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "flushed"), "got: %s", out)
	testing.expect(t, strings.contains(out, "heuristic"))
	testing.expect(t, strings.contains(out, "sessions"))

	// Second flush should still work (append)
	out2 := run_memory_flush(&sess, "test-model", true, context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "flushed"))
}

@(test)
test_memory_slash_status :: proc(t: ^testing.T) {
	root := fmt.aprintf("/tmp/aether-mem-slash-%d", os.get_pid())
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

	// isolate process override from other tests
	tools.memory_clear_process_override()
	defer tools.memory_clear_process_override()

	st := handle_memory_slash("status", "/tmp/proj", context.allocator)
	defer delete(st)
	testing.expectf(t, strings.contains(st, root), "got: %s", st)
	testing.expect(t, strings.contains(st, "enabled") || strings.contains(st, "DISABLED"))

	path := handle_memory_slash("path", "/tmp/proj", context.allocator)
	defer delete(path)
	testing.expect(t, strings.contains(path, root))

	help := handle_memory_slash("help", "/tmp/proj", context.allocator)
	defer delete(help)
	testing.expect(t, strings.contains(help, "/flush"))
	testing.expect(t, strings.contains(help, "/remember"))
	testing.expect(t, strings.contains(help, "on|off"))

	// B32 /remember
	usage := handle_remember_slash("/tmp/proj", "", context.allocator)
	defer delete(usage)
	testing.expect(t, strings.contains(usage, "Usage: /remember"))

	ok_rem := handle_remember_slash("/tmp/proj", "staging uses eu-west", context.allocator)
	defer delete(ok_rem)
	testing.expectf(t, strings.contains(ok_rem, "remembered"), "got: %s", ok_rem)
	testing.expect(t, strings.contains(ok_rem, "eu-west"))
	// file should exist under root
	testing.expect(t, strings.contains(ok_rem, root) || strings.contains(ok_rem, "sessions"))

	off := handle_memory_slash("off", "/tmp/proj", context.allocator)
	defer delete(off)
	testing.expect(t, strings.contains(off, "memory = off"), off)
	testing.expect(t, !tools.memory_enabled())

	on := handle_memory_slash("on", "/tmp/proj", context.allocator)
	defer delete(on)
	testing.expect(t, strings.contains(on, "memory = on") || strings.contains(on, "DISABLED"), on)
	// without AETHER_NO_MEMORY, process on should enable
	prev_no := os.get_env("AETHER_NO_MEMORY", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_MEMORY")
	defer {
		if prev_no != "" {
			_ = os.set_env("AETHER_NO_MEMORY", prev_no)
		}
	}
	_ = tools.memory_set_process_enabled(true)
	testing.expect(t, tools.memory_enabled())
	_ = tools.memory_set_process_enabled(false)
	testing.expect(t, !tools.memory_enabled())
	tools.memory_clear_process_override()
}
