// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_peek_buf_has_ctrl_c_classic :: proc(t: ^testing.T) {
	testing.expect(t, peek_buf_has_ctrl_c([]u8{0x03}))
	testing.expect(t, peek_buf_has_ctrl_c([]u8{'a', 0x03, 'b'}))
	testing.expect(t, !peek_buf_has_ctrl_c([]u8{'a', 'b'}))
	testing.expect(t, !peek_buf_has_ctrl_c([]u8{}))
}

@(test)
test_peek_buf_has_ctrl_c_kitty_csi_u :: proc(t: ^testing.T) {
	// ESC [ 99 ; 5 u  — Kitty/xterm CSI-u Ctrl+C
	seq := []u8{0x1b, '[', '9', '9', ';', '5', 'u'}
	testing.expect(t, peek_buf_has_ctrl_c(seq), "CSI-u Ctrl+C")
	// with event type
	seq2 := []u8{0x1b, '[', '9', '9', ';', '5', ':', '1', 'u'}
	testing.expect(t, peek_buf_has_ctrl_c(seq2), "CSI-u Ctrl+C event")
	// bare 'c' without ctrl
	seq3 := []u8{0x1b, '[', '9', '9', ';', '1', 'u'}
	testing.expect(t, !peek_buf_has_ctrl_c(seq3), "no ctrl")
}

@(test)
test_peek_buf_has_ctrl_c_modother :: proc(t: ^testing.T) {
	// ESC [ 27 ; 5 ; 99 ~
	seq := []u8{0x1b, '[', '2', '7', ';', '5', ';', '9', '9', '~'}
	testing.expect(t, peek_buf_has_ctrl_c(seq), "modifyOtherKeys Ctrl+C")
}
