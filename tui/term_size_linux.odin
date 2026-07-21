// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux
package tui

import "core:sys/linux"

// term_query_winsize uses TIOCGWINSZ on Linux.
term_query_winsize :: proc() -> (rows, cols: int, ok: bool) {
	// struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }
	Win :: struct {
		row, col, xpixel, ypixel: u16,
	}
	ws: Win
	// TIOCGWINSZ = 0x5413 on Linux
	if linux.ioctl(linux.Fd(0), 0x5413, uintptr(&ws)) >= 0 {
		return int(ws.row), int(ws.col), true
	}
	return 0, 0, false
}
