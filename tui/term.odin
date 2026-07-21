#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:sys/posix"

Term_State :: struct {
	orig:          posix.termios,
	active:        bool,
	rows:          int,
	cols:          int,
	mouse_enabled: bool, // SGR mouse capture (toggle via /toggle-mouse-reporting)
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
	t.mouse_enabled = true
	// alt screen, clear, home, hide cursor
	// Kitty keyboard progressive enhancement: disambiguate Escape (flag 1)
	// so Ctrl+M / Shift+Enter are distinct from bare Enter when supported.
	// Mouse: button tracking (1000) + SGR extended (1006) for wheel (C2.2).
	// Bracketed paste (2004): multi-line paste as one event (C2.6 / M1).
	fmt.print("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[=1u\x1b[?1000h\x1b[?1006h\x1b[?2004h")
	term_install_resize_handler()
	term_update_size(t)
	return true
}

term_leave :: proc(t: ^Term_State) {
	if !t.active {
		return
	}
	term_uninstall_resize_handler()
	// disable bracketed paste, mouse, pop keyboard mode, show cursor, leave alt screen
	fmt.print("\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[=0u\x1b[?25h\x1b[0m\x1b[?1049l")
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &t.orig)
	t.active = false
	t.mouse_enabled = false
}

// term_set_mouse enables or disables SGR mouse reporting while still in raw mode.
term_set_mouse :: proc(t: ^Term_State, on: bool) {
	if !t.active {
		return
	}
	if on {
		fmt.print("\x1b[?1000h\x1b[?1006h")
	} else {
		fmt.print("\x1b[?1006l\x1b[?1000l")
	}
	t.mouse_enabled = on
}

// term_toggle_mouse flips SGR mouse capture; returns new enabled state.
term_toggle_mouse :: proc(t: ^Term_State) -> bool {
	term_set_mouse(t, !t.mouse_enabled)
	return t.mouse_enabled
}

// term_set_isig: mid-turn Ctrl+C → SIGINT (async cancel) while keeping raw mode.
// Idle TUI keeps ISIG off so Ctrl+C is a normal key event.
term_set_isig :: proc(t: ^Term_State, enable: bool) {
	if t == nil || !t.active {
		return
	}
	fd := posix.FD(posix.STDIN_FILENO)
	tio: posix.termios
	if posix.tcgetattr(fd, &tio) != .OK {
		return
	}
	if enable {
		tio.c_lflag += {.ISIG}
	} else {
		tio.c_lflag -= {.ISIG}
	}
	// Keep non-canonical raw reads
	tio.c_lflag -= {.ECHO, .ICANON, .IEXTEN}
	tio.c_cc[.VMIN] = 1
	tio.c_cc[.VTIME] = 0
	_ = posix.tcsetattr(fd, .TCSANOW, &tio)
}

// term_suspend_for_pager: leave alt screen + raw so $PAGER can run; caller restores via term_resume_after_pager.
term_suspend_for_pager :: proc(t: ^Term_State) {
	if !t.active {
		return
	}
	// show cursor, leave alt screen, disable mouse/paste/kkp — keep raw? less needs cooked
	fmt.print("\x1b[?2004l\x1b[?1006l\x1b[?1000l\x1b[=0u\x1b[?25h\x1b[0m\x1b[?1049l")
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &t.orig)
}

// term_resume_after_pager: re-enter raw + alt screen after pager exits.
term_resume_after_pager :: proc(t: ^Term_State) {
	if !t.active {
		return
	}
	fd := posix.FD(posix.STDIN_FILENO)
	raw := t.orig
	raw.c_lflag -= {.ECHO, .ICANON, .ISIG, .IEXTEN}
	raw.c_iflag -= {.IXON, .ICRNL, .BRKINT, .INPCK, .ISTRIP}
	raw.c_cflag += {.CS8}
	raw.c_oflag -= {.OPOST}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	_ = posix.tcsetattr(fd, .TCSANOW, &raw)
	mouse := "\x1b[?1000h\x1b[?1006h" if t.mouse_enabled else ""
	fmt.printf("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[=1u%s\x1b[?2004h", mouse)
	term_update_size(t)
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
