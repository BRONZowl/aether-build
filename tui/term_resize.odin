#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:sys/posix"

// Window-resize support (SIGWINCH + size re-query).
// Without this, term_update_size only runs on render after a keypress, so the
// layout stays stale while the user drags the terminal.

@(private)
g_winch_flag: b32

// term_winch_handler: async-signal-safe flag set only.
term_winch_handler :: proc "c" (sig: posix.Signal) {
	g_winch_flag = true
}

// SIGWINCH number is 28 on Linux, Darwin, FreeBSD, OpenBSD, NetBSD.
TERM_SIGWINCH :: 28

// term_install_resize_handler installs SIGWINCH (idempotent enough for enter/leave).
term_install_resize_handler :: proc() {
	_ = posix.signal(posix.Signal(TERM_SIGWINCH), term_winch_handler)
	g_winch_flag = false
}

// term_uninstall_resize_handler restores default disposition.
term_uninstall_resize_handler :: proc() {
	_ = posix.signal(posix.Signal(TERM_SIGWINCH), auto_cast posix.SIG_DFL)
	g_winch_flag = false
}

// term_take_winch: true if a SIGWINCH arrived since last take.
term_take_winch :: proc() -> bool {
	if g_winch_flag {
		g_winch_flag = false
		return true
	}
	return false
}

// term_poll_resize: re-query winsize; return true if rows/cols changed.
// Also clears the winch flag. Call from the event loop on idle timeouts and
// before blocking work so the TUI reflows without requiring a keypress.
term_poll_resize :: proc(t: ^Term_State) -> bool {
	if t == nil {
		return false
	}
	_ = term_take_winch()
	old_r, old_c := t.rows, t.cols
	term_update_size(t)
	return t.rows != old_r || t.cols != old_c
}
