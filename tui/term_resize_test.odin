// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_term_poll_resize_clears_winch_flag :: proc(t: ^testing.T) {
	term: Term_State
	term.rows = 24
	term.cols = 80
	g_winch_flag = true
	_ = term_poll_resize(&term)
	// flag cleared by poll even if size unchanged
	testing.expect(t, g_winch_flag == false)
	testing.expect(t, !term_take_winch())
}

@(test)
test_term_take_winch_clears_flag :: proc(t: ^testing.T) {
	g_winch_flag = true
	testing.expect(t, term_take_winch())
	testing.expect(t, !term_take_winch())
}

@(test)
test_term_poll_resize_reports_size_change :: proc(t: ^testing.T) {
	term: Term_State
	// Set impossible size so real TIOCGWINSZ almost certainly differs
	term.rows = 1
	term.cols = 1
	changed := term_poll_resize(&term)
	// On a real TTY, ioctl should update; in CI without TTY may stay 1,1
	// Accept either: changed true OR size still 1 (no TTY)
	if term.rows != 1 || term.cols != 1 {
		testing.expect(t, changed)
		testing.expect(t, term.rows >= 1 && term.cols >= 1)
	}
}
