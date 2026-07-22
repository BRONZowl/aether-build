// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tui

import "core:strings"
import "core:testing"
import "aether:agent"

@(test)
test_format_context_chip_empty :: proc(t: ^testing.T) {
	// empty session still shows used/window (Grok-style, always visible)
	c := format_context_chip(nil, "", false)
	testing.expect(t, strings.contains(c, "/"), c)
	testing.expect(t, strings.contains(c, "0"), c)
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
	testing.expect(t, strings.contains(c, " / "), c) // "12 / 131K" style
	cc := format_context_chip(msgs, "", true)
	testing.expect(t, strings.contains(cc, "/"), cc)
	testing.expect(t, !strings.contains(cc, " / ") || strings.contains(cc, "/"), cc)
	// live draft should still produce a chip with slash
	live := "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
	c2 := format_context_chip(msgs, live, false)
	testing.expect(t, c2 != "")
	testing.expect(t, strings.contains(c2, "/"), c2)
}
