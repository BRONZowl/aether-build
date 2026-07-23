// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
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

@(test)
test_free_scroll_clears_ensure_sel :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	// Selection change requests ensure; free scroll must cancel it so wheel
	// is not snapped back to the selected (often last) block every paint.
	st.ensure_sel_visible = true
	stream_scroll_adjust(&st, 3)
	testing.expect(t, !st.ensure_sel_visible, "wheel/PgUp clears ensure_sel_visible")
	testing.expect(t, st.scroll == 3)
	testing.expect(t, !st.stream_follow)

	// Selection movers re-arm ensure
	state_add_block(&st, .User, "a")
	state_add_block(&st, .Assistant, "b")
	st.selected_block = 0
	st.ensure_sel_visible = false
	testing.expect(t, scrollback_move_sel(&st, 1))
	testing.expect(t, st.ensure_sel_visible, "move selection arms ensure")
}

@(test)
test_scroll_changes_visible_window :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	// many blocks so content exceeds typical body height
	for i in 0 ..< 40 {
		state_add_block(&st, .User, fmt.tprintf("user line %d with enough text", i))
		state_add_block(&st, .Assistant, fmt.tprintf("assistant reply %d more words here", i))
	}
	lines := make([dynamic]string, 0, 256, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 256, context.temp_allocator)
	block_idxs := make([dynamic]int, 0, 256, context.temp_allocator)
	flatten_blocks(&st, 80, &lines, &styles, &block_idxs, context.temp_allocator, 40)
	total := len(lines)
	body_h := 15
	testing.expect(t, total > body_h, fmt.tprintf("need overflow total=%d", total))
	max_scroll := total - body_h
	// at bottom
	start0 := max(0, total - body_h - 0)
	// scroll up
	stream_scroll_adjust(&st, 10)
	scroll := st.scroll
	if scroll > max_scroll {
		scroll = max_scroll
	}
	start1 := max(0, total - body_h - scroll)
	testing.expect(t, start1 < start0, fmt.tprintf("scroll should show older: start0=%d start1=%d scroll=%d", start0, start1, scroll))
	testing.expect(t, !st.stream_follow)
}
