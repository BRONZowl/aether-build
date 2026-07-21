// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build !linux
package tui

import "core:c"
import "core:sys/posix"

// Non-Linux: TIOCGWINSZ via libc ioctl (Darwin/BSD). Falls back to env in
// term_update_size when ioctl fails.

when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
	// Darwin/BSD: TIOCGWINSZ = 0x40087468
	TIOCGWINSZ_OTHER :: 0x40087468

	Win_Size :: struct {
		row, col, xpixel, ypixel: u16,
	}

	foreign import libc "system:c"

	foreign libc {
		ioctl :: proc(fd: c.int, req: c.ulong, #c_vararg args: ..any) -> c.int ---
	}

	term_query_winsize :: proc() -> (rows, cols: int, ok: bool) {
		ws: Win_Size
		if ioctl(0, c.ulong(TIOCGWINSZ_OTHER), &ws) == 0 {
			if ws.row > 0 && ws.col > 0 {
				return int(ws.row), int(ws.col), true
			}
		}
		return 0, 0, false
	}
} else {
	term_query_winsize :: proc() -> (rows, cols: int, ok: bool) {
		_ = posix.STDIN_FILENO
		return 0, 0, false
	}
}
