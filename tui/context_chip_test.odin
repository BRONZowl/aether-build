package tui

import "core:strings"
import "core:testing"
import "aether:agent"

@(test)
test_format_context_chip_empty :: proc(t: ^testing.T) {
	// empty session → empty chip
	c := format_context_chip(nil, "", false)
	testing.expect(t, c == "")
}

@(test)
test_format_context_chip_with_msgs :: proc(t: ^testing.T) {
	msgs := make([]agent.Chat_Message, 2, context.temp_allocator)
	msgs[0] = agent.Chat_Message {
		role    = .User,
		content = "hello world this is a prompt",
	}
	msgs[1] = agent.Chat_Message {
		role    = .Assistant,
		content = "response text here",
	}
	c := format_context_chip(msgs, "", false)
	testing.expect(t, strings.has_prefix(c, " ctx:"))
	testing.expect(t, strings.has_suffix(c, "%"))
	cc := format_context_chip(msgs, "", true)
	testing.expect(t, strings.has_suffix(cc, "%"))
	// live draft should still produce a chip
	live := "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	c2 := format_context_chip(msgs, live, false)
	testing.expect(t, c2 != "")
	testing.expect(t, strings.has_suffix(c2, "%"))
}
