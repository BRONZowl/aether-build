#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"
import "aether:tools"

// Stream / mid-turn globals + peek handlers (extract from tui.odin).

// Cooperative cancel + live permission, visible to stream/status/HTTP poll callbacks.
// Cooperative cancel + live permission, visible to stream/status/HTTP poll callbacks.
@(private)
g_cancel: bool
@(private)
g_perm: ^core.Permission_Mode
@(private)
g_perm_before: ^core.Permission_Mode

g_slash_state:  ^App_State
g_stream_state: ^App_State
g_stream_term:  ^Term_State
g_status_state: ^App_State
g_status_term:  ^Term_State
g_sess:         ^agent.Session


// Non-blocking peek during long turns: Ctrl+C cancel, Ctrl+O yolo, Shift+Tab cycle,
// and B31 scroll keys (so stream_follow can detach while tokens/tools still run).
// Also used as agent on_poll during in-flight HTTP.
peek_turn_keys :: proc() {
	if g_cancel {
		return
	}
	old: posix.termios
	if posix.tcgetattr(posix.FD(posix.STDIN_FILENO), &old) != .OK {
		return
	}
	raw := old
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &raw)
	buf: [64]u8
	n, _ := os.read(os.stdin, buf[:])
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &old)
	if n <= 0 {
		return
	}
	// Scan for cancel first (any position)
	for i in 0 ..< n {
		if buf[i] == 0x03 { // Ctrl+C
			g_cancel = true
			if g_stream_state != nil {
				state_set_status(g_stream_state, "cancelling…")
			}
			return
		}
	}
	if g_stream_state == nil {
		return
	}
	// Mode keys only when we have live permission + UI state
	if g_perm != nil && g_perm_before != nil {
		// Ctrl+O = 0x0f
		for i in 0 ..< n {
			if buf[i] == 0x0f {
				toggle_yolo(g_stream_state, g_perm, g_perm_before)
				if g_stream_term != nil {
					render(g_stream_term, g_stream_state)
				}
				return
			}
		}
		// Shift+Tab: ESC [ Z  or  ESC [ 1 ; 2 Z  (and similar CSI ending in Z)
		if peek_is_shift_tab(buf[:n]) {
			cwd := "."
			if g_sess != nil && g_sess.cwd != "" {
				cwd = g_sess.cwd
			}
			cycle_mode(g_stream_state, g_perm, g_perm_before, cwd)
			if g_stream_term != nil {
				render(g_stream_term, g_stream_state)
			}
			return
		}
	}
	// B31: mid-turn scroll (Ctrl+U/J/K, arrows, PgUp/Dn, wheel)
	if peek_apply_stream_scroll(buf[:n]) {
		if g_stream_term != nil {
			render(g_stream_term, g_stream_state)
		}
	}
}

// peek_apply_stream_scroll handles common scroll chords from a raw stdin peek buffer.
// Returns true if scroll/follow changed.
peek_apply_stream_scroll :: proc(buf: []u8) -> bool {
	if g_stream_state == nil || len(buf) == 0 {
		return false
	}
	half := 12
	if g_stream_term != nil {
		half = max(1, g_stream_term.rows / 2)
	}
	changed := false
	i := 0
	for i < len(buf) {
		b := buf[i]
		// Ctrl+U half-page up (older)
		if b == 0x15 {
			stream_scroll_adjust(g_stream_state, half)
			changed = true
			i += 1
			continue
		}
		// Ctrl+K line up
		if b == 0x0b {
			stream_scroll_adjust(g_stream_state, 1)
			changed = true
			i += 1
			continue
		}
		// Ctrl+J line down
		if b == 0x0a {
			stream_scroll_adjust(g_stream_state, -1)
			changed = true
			i += 1
			continue
		}
		// ESC sequences
		if b == 0x1b && i + 1 < len(buf) {
			// SS3: ESC O A/B
			if buf[i + 1] == 'O' && i + 2 < len(buf) {
				switch buf[i + 2] {
				case 'A':
					stream_scroll_adjust(g_stream_state, 1)
					changed = true
				case 'B':
					stream_scroll_adjust(g_stream_state, -1)
					changed = true
				}
				i += 3
				continue
			}
			if buf[i + 1] == '[' {
				// Find CSI final in remaining buffer
				j := i + 2
				for j < len(buf) {
					fb := buf[j]
					if fb >= 0x40 && fb <= 0x7e {
						// final
						ps := string(buf[i + 2:j])
						if fb == 'A' {
							stream_scroll_adjust(g_stream_state, 1)
							changed = true
						} else if fb == 'B' {
							stream_scroll_adjust(g_stream_state, -1)
							changed = true
						} else if fb == '~' {
							// ESC [ 5 ~ PgUp, ESC [ 6 ~ PgDn
							if ps == "5" {
								stream_scroll_adjust(g_stream_state, half)
								changed = true
							} else if ps == "6" {
								stream_scroll_adjust(g_stream_state, -half)
								changed = true
							}
						} else if fb == 'M' || fb == 'm' {
							// SGR mouse wheel: ESC [ <64;x;y M
							if len(ps) > 0 && ps[0] == '<' {
								btn_str := ps[1:]
								// take digits until ;
								btn_n := 0
								for k in 0 ..< len(btn_str) {
									if btn_str[k] < '0' || btn_str[k] > '9' {
										break
									}
									btn_n = btn_n * 10 + int(btn_str[k] - '0')
								}
								if btn_n == 64 || btn_n == 68 || btn_n == 72 || btn_n == 80 {
									stream_scroll_adjust(g_stream_state, 3)
									changed = true
								} else if btn_n == 65 || btn_n == 69 || btn_n == 73 || btn_n == 81 {
									stream_scroll_adjust(g_stream_state, -3)
									changed = true
								}
							}
						}
						i = j + 1
						break
					}
					j += 1
				}
				if j >= len(buf) {
					// incomplete CSI — stop
					break
				}
				continue
			}
		}
		i += 1
	}
	return changed
}

// Keep old name as alias for any residual call sites.
peek_cancel_keys :: proc() {
	peek_turn_keys()
}

stream_delta :: proc(text: string) {
	if g_stream_state == nil {
		return
	}
	peek_turn_keys()
	strings.write_string(&g_stream_state.live_assist, text)
	g_stream_state.streaming = true
	now := time.now()._nsec
	if g_stream_term != nil && (now - g_stream_state.last_redraw_ns) >= STREAM_REDRAW_NS {
		g_stream_state.last_redraw_ns = now
		if g_cancel {
			state_set_status(g_stream_state, "cancelling…")
		}
		render(g_stream_term, g_stream_state)
	}
}
