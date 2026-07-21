// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_stream_follow_scroll_adjust :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	testing.expect(t, st.stream_follow, "follow on by default")
	testing.expect(t, st.scroll == 0, "scroll 0")

	stream_scroll_adjust(&st, 5)
	testing.expect(t, !st.stream_follow, "scroll up detaches follow")
	testing.expect(t, st.scroll == 5, "scroll offset")

	stream_scroll_adjust(&st, -2)
	testing.expect(t, !st.stream_follow, "still detached above bottom")
	testing.expect(t, st.scroll == 3, "partial scroll down")

	stream_scroll_adjust(&st, -10)
	testing.expect(t, st.stream_follow, "at bottom re-enables follow")
	testing.expect(t, st.scroll == 0, "clamped to 0")

	stream_scroll_adjust(&st, 1)
	stream_pin_bottom(&st)
	testing.expect(t, st.stream_follow, "pin restores follow")
	testing.expect(t, st.scroll == 0, "pin zero scroll")
}

@(test)
test_stream_maybe_pin_respects_follow :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	st.scroll = 7
	st.stream_follow = false
	stream_maybe_pin_bottom(&st)
	testing.expect(t, st.scroll == 7, "no pin when not following")

	st.stream_follow = true
	stream_maybe_pin_bottom(&st)
	testing.expect(t, st.scroll == 0, "pin when following")
}
