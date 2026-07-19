#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:sys/posix"

Term_State :: struct {
	orig:   posix.termios,
	active: bool,
	rows:   int,
	cols:   int,
}

// term_enter enables raw mode + alternate screen + keyboard enhancement when available.
term_enter :: proc(t: ^Term_State) -> bool {
	fd := posix.FD(posix.STDIN_FILENO)
	if posix.tcgetattr(fd, &t.orig) != .OK {
		return false
	}
	raw := t.orig
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN}
	raw.c_iflag -= {.IXON, .ICRNL, .BRKINT, .INPCK, .ISTRIP}
	raw.c_cflag += {.CS8}
	// disable output post-processing so we control all newlines
	raw.c_oflag -= {.OPOST}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(fd, .TCSANOW, &raw) != .OK {
		return false
	}
	t.active = true
	// alt screen, clear, home, hide cursor
	// Kitty keyboard progressive enhancement: disambiguate Escape (flag 1)
	// so Ctrl+M / Shift+Enter are distinct from bare Enter when supported.
	// Mouse: button tracking (1000) + SGR extended (1006) for wheel (C2.2).
	// Bracketed paste (2004): multi-line paste as one event (C2.6 / M1).
	fmt.print("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[=1u\x1b[?1000h\x1b[?1006h\x1b[?2004h")
	term_update_size(t)
	return true
}

term_leave :: proc(t: ^Term_State) {
	if !t.active {
		return
	}
	// disable bracketed paste, mouse, pop keyboard mode, show cursor, leave alt screen
	fmt.print("\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[=0u\x1b[?25h\x1b[0m\x1b[?1049l")
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &t.orig)
	t.active = false
}

term_update_size :: proc(t: ^Term_State) {
	t.rows = 24
	t.cols = 80
	if r, c, ok := term_query_winsize(); ok {
		if r > 0 {
			t.rows = r
		}
		if c > 0 {
			t.cols = c
		}
		return
	}
	if c := os.get_env("LINES", context.temp_allocator); c != "" {
		if n, ok := parse_pos_int(c); ok && n > 0 {
			t.rows = n
		}
	}
	if c := os.get_env("COLUMNS", context.temp_allocator); c != "" {
		if n, ok := parse_pos_int(c); ok && n > 0 {
			t.cols = n
		}
	}
}

parse_pos_int :: proc(s: string) -> (int, bool) {
	n := 0
	if len(s) == 0 {
		return 0, false
	}
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n * 10 + int(ch - '0')
	}
	return n, true
}
