// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_format_block_hhmm_respects_flag :: proc(t: ^testing.T) {
	core.set_timestamps(false)
	testing.expect(t, format_block_hhmm(1_700_000_000) == "")

	core.set_timestamps(true)
	defer core.set_timestamps(false)
	s := format_block_hhmm(1_700_000_000)
	// "HH:MM " — 6 chars with trailing space
	testing.expect(t, len(s) == 6, s)
	testing.expect(t, s[2] == ':', s)
	testing.expect(t, s[5] == ' ', s)
	testing.expect(t, format_block_hhmm(0) == "")
}

@(test)
test_state_add_block_stamps_time :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	state_add_block(&st, .User, "hello")
	testing.expect(t, len(st.blocks) == 1)
	testing.expect(t, st.blocks[0].time_unix > 0)
}

@(test)
test_block_stamp_key_stable :: proc(t: ^testing.T) {
	a := block_stamp_key(.User, "same", "", context.allocator)
	defer delete(a)
	b := block_stamp_key(.User, "same", "", context.allocator)
	defer delete(b)
	testing.expect(t, a == b)
	c := block_stamp_key(.Assistant, "same", "", context.allocator)
	defer delete(c)
	testing.expect(t, a != c)
	_ = strings.has_prefix(a, "") // silence unused if any
}
