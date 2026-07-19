#+build !linux
package tui

// Non-Linux: fall back to env / defaults (handled by term_update_size).
term_query_winsize :: proc() -> (rows, cols: int, ok: bool) {
	return 0, 0, false
}
