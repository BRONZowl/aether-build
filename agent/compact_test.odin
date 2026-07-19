package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_build_compact_prompt_includes_focus :: proc(t: ^testing.T) {
	p := build_compact_user_prompt("keep auth details", context.allocator)
	defer delete(p)
	testing.expect(t, strings.contains(p, "user_provided_context"))
	testing.expect(t, strings.contains(p, "keep auth details"))
	p2 := build_compact_user_prompt("", context.allocator)
	defer delete(p2)
	testing.expect(t, !strings.contains(p2, "user_provided_context"))
}

@(test)
test_extract_summary_block :: proc(t: ^testing.T) {
	s := extract_summary_block("preamble <summary>\n## Body\n\nok\n</summary> tail", context.allocator)
	defer delete(s)
	testing.expect(t, strings.contains(s, "## Body"))
	testing.expect(t, !strings.contains(s, "preamble"))
	s2 := extract_summary_block("## plain markdown", context.allocator)
	defer delete(s2)
	testing.expect(t, strings.contains(s2, "plain markdown"))
}

@(test)
test_compact_heuristic_rewrites_history :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-compact-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	// Pad history
	for i in 0 ..< 8 {
		append(
			&sess.msgs,
			Chat_Message {
				role    = .User,
				content = strings.clone(fmt.tprintf("user message number %d about feature X", i)),
			},
		)
		append(
			&sess.msgs,
			Chat_Message {
				role    = .Assistant,
				content = strings.clone(fmt.tprintf("assistant reply %d with details", i)),
			},
		)
	}
	before := len(sess.msgs)
	testing.expect(t, before > 5)

	out := run_session_compact(&sess, "test-model", "", true /* heuristic */, .Always_Approve, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "compacted"), "got: %s", out)
	testing.expect(t, len(sess.msgs) == 3)
	testing.expect(t, sess.msgs[0].role == .System)
	testing.expect(t, sess.msgs[1].role == .User)
	testing.expect(t, sess.msgs[2].role == .Assistant)
	testing.expect(t, strings.contains(sess.msgs[2].content, "Compacted") || strings.contains(sess.msgs[2].content, "User:"))
	testing.expect(t, !sess.memory_injected)
}

@(test)
test_should_auto_compact_threshold :: proc(t: ^testing.T) {
	prev_no := os.get_env("AETHER_NO_AUTO_COMPACT", context.temp_allocator)
	prev_pct := os.get_env("AETHER_AUTO_COMPACT_PCT", context.temp_allocator)
	prev_win := os.get_env("AETHER_CONTEXT_WINDOW", context.temp_allocator)
	os.unset_env("AETHER_NO_AUTO_COMPACT")
	os.set_env("AETHER_AUTO_COMPACT_PCT", "50")
	os.set_env("AETHER_CONTEXT_WINDOW", "100") // 100 tokens
	defer {
		if prev_no != "" {
			os.set_env("AETHER_NO_AUTO_COMPACT", prev_no)
		} else {
			os.unset_env("AETHER_NO_AUTO_COMPACT")
		}
		if prev_pct != "" {
			os.set_env("AETHER_AUTO_COMPACT_PCT", prev_pct)
		} else {
			os.unset_env("AETHER_AUTO_COMPACT_PCT")
		}
		if prev_win != "" {
			os.set_env("AETHER_CONTEXT_WINDOW", prev_win)
		} else {
			os.unset_env("AETHER_CONTEXT_WINDOW")
		}
	}

	// Too few messages
	small: [dynamic]Chat_Message
	defer destroy_messages(small[:])
	append(&small, Chat_Message{role = .System, content = strings.clone("sys")})
	append(&small, Chat_Message{role = .User, content = strings.clone("hi")})
	testing.expect(t, !should_auto_compact(small[:]))

	// Many large messages → over 50% of 100 tokens
	big: [dynamic]Chat_Message
	defer destroy_messages(big[:])
	append(&big, Chat_Message{role = .System, content = strings.clone("sys")})
	// 50 tokens * 4 = 200 chars minimum for 50%; need more for 50% of 100 = 50 tokens = 200 chars total
	// With min 6 non-system, pad
	pad_s, _ := strings.repeat("x", 80, context.temp_allocator)
	for i in 0 ..< 8 {
		append(&big, Chat_Message{role = .User, content = strings.clone(pad_s)})
		append(&big, Chat_Message{role = .Assistant, content = strings.clone(pad_s)})
		_ = i
	}
	testing.expect(t, should_auto_compact(big[:]))

	os.set_env("AETHER_NO_AUTO_COMPACT", "1")
	testing.expect(t, !should_auto_compact(big[:]))
}

@(test)
test_maybe_auto_compact_reduces :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-autocompact-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	prev_no := os.get_env("AETHER_NO_AUTO_COMPACT", context.temp_allocator)
	prev_pct := os.get_env("AETHER_AUTO_COMPACT_PCT", context.temp_allocator)
	prev_win := os.get_env("AETHER_CONTEXT_WINDOW", context.temp_allocator)
	os.unset_env("AETHER_NO_AUTO_COMPACT")
	os.set_env("AETHER_AUTO_COMPACT_PCT", "10")
	os.set_env("AETHER_CONTEXT_WINDOW", "200")
	defer {
		if prev_no != "" {
			os.set_env("AETHER_NO_AUTO_COMPACT", prev_no)
		} else {
			os.unset_env("AETHER_NO_AUTO_COMPACT")
		}
		if prev_pct != "" {
			os.set_env("AETHER_AUTO_COMPACT_PCT", prev_pct)
		} else {
			os.unset_env("AETHER_AUTO_COMPACT_PCT")
		}
		if prev_win != "" {
			os.set_env("AETHER_CONTEXT_WINDOW", prev_win)
		} else {
			os.unset_env("AETHER_CONTEXT_WINDOW")
		}
	}

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	pad, _ := strings.repeat("word ", 40, context.temp_allocator)
	for i in 0 ..< 10 {
		append(&sess.msgs, Chat_Message{role = .User, content = strings.clone(fmt.tprintf("%s %d", pad, i))})
		append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone(fmt.tprintf("reply %s %d", pad, i))})
	}
	before := len(sess.msgs)
	out := maybe_auto_compact(&sess, &sess.msgs, "m", .Always_Approve, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "auto-compact") || strings.contains(out, "compacted"), "got: %s", out)
	testing.expect(t, len(sess.msgs) < before)
	testing.expect(t, len(sess.msgs) == 3)
}

@(test)
test_compact_empty_history :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-compact-empty-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)

	out := run_session_compact(&sess, "m", "", true, .Always_Approve, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "nothing to compact"))
}
