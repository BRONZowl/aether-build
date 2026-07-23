// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "aether:agent"
import "aether:core"

// Stream / mid-turn UI context for agent callbacks (on_ask, on_poll, stream deltas).
// One active turn at a time — bind at turn start, clear at turn end.

Stream_Ctx :: struct {
	cancel:         bool,
	perm:           ^core.Permission_Mode,
	perm_before:    ^core.Permission_Mode,
	st:             ^App_State,
	term:           ^Term_State,
	status_st:      ^App_State,
	status_term:    ^Term_State,
	sess:           ^agent.Session,
	slash_st:       ^App_State,
	last_poll_ns:   i64, // throttle peek_turn_keys during fast SSE
	render_depth:   int, // reentrancy guard (peek may paint mid stream_delta)
}

// Package-level active context (callbacks have no user-data slot).
@(private)
g_rt: Stream_Ctx

// Async SIGINT cancel while a turn is bound. Only writes a bool (async-signal-safe).
// Handler is installed for the whole TUI session (see stream_install_sigint);
// never restore SIG_DFL mid-session — that made Ctrl+C exit the process.
@(private)
g_sigint_cancel: ^bool

@(private)
g_sigint_installed: bool

@(private)
stream_sigint_handler :: proc "c" (sig: posix.Signal) {
	_ = sig
	// Mid-turn only: set cooperative cancel. Idle: ignore (never exit).
	if g_sigint_cancel != nil {
		g_sigint_cancel^ = true
	}
}

// stream_install_sigint: session-long SIGINT → cancel flag (sigaction + SA_RESTART).
// Call from term_enter. Safe if called more than once.
stream_install_sigint :: proc() {
	if g_sigint_installed {
		return
	}
	act: posix.sigaction_t
	act.sa_handler = stream_sigint_handler
	act.sa_flags = {.RESTART} // do not SA_RESETHAND — handler must stay for whole session
	_ = posix.sigemptyset(&act.sa_mask)
	if posix.sigaction(.SIGINT, &act, nil) == .OK {
		g_sigint_installed = true
	} else {
		// Fallback: classic signal() still better than default terminate mid-turn
		_ = posix.signal(.SIGINT, stream_sigint_handler)
		g_sigint_installed = true
	}
}

// stream_uninstall_sigint: restore default only when leaving the TUI.
stream_uninstall_sigint :: proc() {
	if !g_sigint_installed {
		return
	}
	g_sigint_cancel = nil
	act: posix.sigaction_t
	act.sa_handler = auto_cast posix.SIG_DFL
	act.sa_flags = {}
	_ = posix.sigemptyset(&act.sa_mask)
	_ = posix.sigaction(.SIGINT, &act, nil)
	g_sigint_installed = false
}

// stream_bind wires UI + permission pointers for an agent turn / slash status.
stream_bind :: proc(
	st: ^App_State,
	term: ^Term_State,
	sess: ^agent.Session,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
) {
	g_rt.st = st
	g_rt.term = term
	g_rt.status_st = st
	g_rt.status_term = term
	g_rt.sess = sess
	g_rt.perm = perm
	g_rt.perm_before = perm_before
	g_rt.cancel = false
	g_rt.last_poll_ns = 0
	g_rt.render_depth = 0
	// Mid-turn cancel target for the session-long SIGINT handler.
	// Dual path:
	//   1) ISIG on → kernel maps VINTR (0x03) → SIGINT → handler sets cancel
	//      (classic terminals; works even when not reading stdin yet)
	//   2) peek_turn_keys also scans 0x03 + Kitty CSI-u Ctrl+C (ESC [ 99;5 u)
	// SIGINT disposition is session-long (never SIG_DFL mid-TUI) so this cannot exit.
	g_sigint_cancel = &g_rt.cancel
	stream_install_sigint()
	if term != nil {
		term_set_isig(term, true)
	}
}

// stream_clear drops all turn pointers (safe after turn ends).
// Does **not** restore SIGINT to SIG_DFL — that caused Ctrl+C to exit Aether.
stream_clear :: proc() {
	if g_rt.term != nil {
		// Belt-and-suspenders: never leave ISIG on after a turn
		term_set_isig(g_rt.term, false)
	}
	g_sigint_cancel = nil
	g_rt = {}
}

// stream_bind_slash / stream_clear_slash: notice callback during slash handling.
stream_bind_slash :: proc(st: ^App_State) {
	g_rt.slash_st = st
}

stream_clear_slash :: proc() {
	g_rt.slash_st = nil
}

// stream_cancel_ptr: address for Turn_Options.cancel (set true to abort).
stream_cancel_ptr :: proc() -> ^bool {
	return &g_rt.cancel
}

// stream_set_cancel marks cooperative cancel (Ctrl+C mid-turn).
stream_set_cancel :: proc() {
	g_rt.cancel = true
}

// stream_is_cancel reports cancel flag.
stream_is_cancel :: proc() -> bool {
	return g_rt.cancel
}

// stream_sess / stream_st / stream_term accessors for modals & mode.
// Prefer App_State.live_sess for idle chrome; g_rt.sess is only set mid-turn.
stream_sess :: proc() -> ^agent.Session {
	return g_rt.sess
}

// live_session returns the TUI's idle session pointer (App_State.live_sess), or nil.
live_session :: proc(s: ^App_State) -> ^agent.Session {
	if s == nil || s.live_sess == nil {
		return nil
	}
	return cast(^agent.Session)s.live_sess
}

// set_live_session stores a non-owning session pointer for chrome (context bar).
set_live_session :: proc(s: ^App_State, sess: ^agent.Session) {
	if s == nil {
		return
	}
	s.live_sess = sess
}

// tui_abort_turn_ui: after /clear|/new (or cancel), drop mid-turn chrome so the
// empty session can show welcome and accept input again.
tui_abort_turn_ui :: proc(s: ^App_State) {
	if s == nil {
		return
	}
	if s.streaming {
		stream_set_cancel()
	}
	s.streaming = false
	strings.builder_reset(&s.live_assist)
	s.spinner_tick = 0
	s.last_spinner_ns = 0
}

stream_st :: proc() -> ^App_State {
	return g_rt.st
}

stream_term :: proc() -> ^Term_State {
	return g_rt.term
}

// stream_notice_slash delivers a notice to the bound slash UI state.
stream_notice_slash :: proc(msg: string) {
	if g_rt.slash_st != nil {
		state_add_notice(g_rt.slash_st, msg)
	}
}

// stream_status_cb: Turn_Options.on_status — peek keys, status line, live clear.
// Single path for agent turns (handle_submit + auto-wake).
stream_status_cb :: proc(text: string) {
	peek_turn_keys()
	if g_rt.status_st == nil {
		return
	}
	// When tools start, drop live stream so it doesn't double with history
	if text == "" || text == "ready" || strings.has_prefix(text, "tool:") {
		strings.builder_reset(&g_rt.status_st.live_assist)
	}
	state_set_status(g_rt.status_st, text)
	_ = stream_spinner_tick(g_rt.status_st, true)
	if g_rt.status_term != nil {
		render(g_rt.status_term, g_rt.status_st)
	}
}

// stream_spinner_tick advances the braille frame while streaming (not during ask).
// force=true always bumps the frame (status/tool transitions).
// Returns true if the frame advanced (caller may re-render).
stream_spinner_tick :: proc(st: ^App_State, force := false) -> bool {
	if st == nil || !st.streaming || st.ask_active {
		return false
	}
	now := time.now()._nsec
	if !force && st.last_spinner_ns != 0 && (now - st.last_spinner_ns) < SPINNER_NS {
		return false
	}
	st.spinner_tick += 1
	st.last_spinner_ns = now
	return true
}

// stream_tool_done_cb: Turn_Options.on_history — rebuild blocks after tool finish.
stream_tool_done_cb :: proc() {
	peek_turn_keys()
	if g_rt.st == nil || g_rt.sess == nil {
		return
	}
	rebuild_blocks(g_rt.st, g_rt.sess.msgs[:])
	stream_maybe_pin_bottom(g_rt.st)
	if g_rt.term != nil {
		render(g_rt.term, g_rt.st)
	}
}

// Non-blocking peek during long turns: Ctrl+C cancel, Ctrl+O yolo, Shift+Tab cycle,
// and B31 scroll keys (so stream_follow can detach while tokens/tools still run).
// Also used as agent on_poll during in-flight HTTP (must stay proc() for Poll_Handler).
peek_turn_keys :: proc() {
	peek_turn_keys_impl(true)
}

// Throttled peek for stream_delta (avoid tcsetattr every token).
peek_turn_keys_throttled :: proc() {
	peek_turn_keys_impl(false)
}

@(private)
peek_turn_keys_impl :: proc(force: bool) {
	// SIGINT handler may have set cancel asynchronously — surface it immediately
	if g_rt.cancel {
		if g_rt.st != nil {
			state_set_status(g_rt.st, "cancelling…")
		}
		return
	}
	now := time.now()._nsec
	if !force && g_rt.last_poll_ns != 0 && (now - g_rt.last_poll_ns) < STREAM_POLL_NS {
		// Still advance spinner on throttled polls when due (HTTP wait with no keys).
		if g_rt.st != nil && stream_spinner_tick(g_rt.st, false) && g_rt.term != nil {
			stream_safe_render()
		}
		return
	}
	g_rt.last_poll_ns = now

	// Spinner tick even when stdin has no data (pre-token wait / tool gaps).
	spun := false
	if g_rt.st != nil {
		spun = stream_spinner_tick(g_rt.st, false)
	}

	old: posix.termios
	if posix.tcgetattr(posix.FD(posix.STDIN_FILENO), &old) != .OK {
		if spun && g_rt.term != nil {
			stream_safe_render()
		}
		return
	}
	raw := old
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &raw)
	buf: [64]u8
	n, _ := os.read(os.stdin, buf[:])
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &old)
	// SIGINT during the brief read window
	if g_rt.cancel {
		if g_rt.st != nil {
			state_set_status(g_rt.st, "cancelling…")
		}
		return
	}
	if n <= 0 {
		if spun && g_rt.term != nil {
			stream_safe_render()
		}
		return
	}
	// Cancel first: 0x03, Kitty CSI-u Ctrl+C, or modifyOtherKeys Ctrl+C
	if peek_buf_has_ctrl_c(buf[:n]) {
		g_rt.cancel = true
		if g_rt.st != nil {
			state_set_status(g_rt.st, "cancelling…")
		}
		if g_rt.term != nil && g_rt.st != nil {
			stream_safe_render()
		}
		return
	}
	if g_rt.st == nil {
		return
	}
	// Mode keys only when we have live permission + UI state
	if g_rt.perm != nil && g_rt.perm_before != nil {
		// Ctrl+O = 0x0f
		for i in 0 ..< n {
			if buf[i] == 0x0f {
				toggle_yolo(g_rt.st, g_rt.perm, g_rt.perm_before)
				if g_rt.term != nil {
					stream_safe_render()
				}
				return
			}
		}
		// Shift+Tab: ESC [ Z  or CSI-u 9;2u / modifyOtherKeys
		if peek_is_shift_tab(buf[:n]) {
			cwd := "."
			if g_rt.sess != nil && g_rt.sess.cwd != "" {
				cwd = g_rt.sess.cwd
			}
			cycle_mode(g_rt.st, g_rt.perm, g_rt.perm_before, cwd)
			if g_rt.term != nil {
				stream_safe_render()
			}
			return
		}
	}
	// B31: mid-turn scroll (Ctrl+U/J/K, arrows, PgUp/Dn, wheel)
	if peek_apply_stream_scroll(buf[:n]) {
		if g_rt.term != nil {
			stream_safe_render()
		}
		return
	}
	// Wave 1: mid-turn compose + queue (printable / Enter / Backspace)
	if peek_apply_stream_compose(buf[:n]) {
		if g_rt.term != nil {
			stream_safe_render()
		}
	}
}

// stream_safe_render: skip nested full paints (re-entry from peek during stream_delta).
stream_safe_render :: proc() {
	if g_rt.term == nil || g_rt.st == nil {
		return
	}
	if g_rt.render_depth > 0 {
		return
	}
	g_rt.render_depth += 1
	render(g_rt.term, g_rt.st)
	g_rt.render_depth -= 1
}

// peek_apply_stream_compose: type into prompt while agent runs; Enter queues
// (or empty Enter force-sends top of queue by cancelling the turn).
peek_apply_stream_compose :: proc(buf: []u8) -> bool {
	if g_rt.st == nil || len(buf) == 0 {
		return false
	}
	// Don't fight ask modal
	if g_rt.st.ask_active {
		return false
	}
	changed := false
	i := 0
	for i < len(buf) {
		b := buf[i]
		// Enter / LF / CR → queue or force-send
		if b == 0x0d || b == 0x0a {
			line := strings.trim_space(input_text(g_rt.st))
			if line != "" {
				if prompt_queue_push(g_rt.st, line) {
					input_clear(g_rt.st)
					state_set_status(
						g_rt.st,
						fmt.tprintf("queued (%d)", prompt_queue_len(g_rt.st)),
					)
					state_add_notice(
						g_rt.st,
						fmt.tprintf("aether: queued follow-up (%d in queue)", prompt_queue_len(g_rt.st)),
					)
				} else {
					state_set_status(g_rt.st, "queue full")
				}
				changed = true
			} else if prompt_queue_len(g_rt.st) > 0 {
				// Force-send: cancel current turn; drain after cancel
				g_rt.st.queue_force_send = true
				g_rt.cancel = true
				state_set_status(g_rt.st, "force-send: cancelling…")
				changed = true
			}
			i += 1
			continue
		}
		// Backspace
		if b == 0x7f || b == 0x08 {
			if g_rt.st.focus != .Prompt {
				focus_prompt(g_rt.st)
			}
			if len(g_rt.st.input) > 0 {
				input_backspace(g_rt.st)
				changed = true
			}
			i += 1
			continue
		}
		// Printable ASCII only (ESC sequences already handled by scroll path)
		if b >= 32 && b < 127 {
			if g_rt.st.focus != .Prompt {
				focus_prompt(g_rt.st)
			}
			input_insert_rune(g_rt.st, rune(b))
			changed = true
			i += 1
			continue
		}
		// Skip unknown / partial ESC
		if b == 0x1b {
			break
		}
		i += 1
	}
	return changed
}

// peek_apply_stream_scroll handles common scroll chords from a raw stdin peek buffer.
// Returns true if scroll/follow changed.
peek_apply_stream_scroll :: proc(buf: []u8) -> bool {
	if g_rt.st == nil || len(buf) == 0 {
		return false
	}
	half := 12
	if g_rt.term != nil {
		half = max(1, g_rt.term.rows / 2)
	}
	changed := false
	i := 0
	for i < len(buf) {
		b := buf[i]
		// Ctrl+U half-page up (older)
		if b == 0x15 {
			stream_scroll_adjust(g_rt.st, half)
			changed = true
			i += 1
			continue
		}
		// Ctrl+D half-page down (Grok)
		if b == 0x04 {
			stream_scroll_adjust(g_rt.st, -half)
			changed = true
			i += 1
			continue
		}
		// Ctrl+K line up
		if b == 0x0b {
			stream_scroll_adjust(g_rt.st, 1)
			changed = true
			i += 1
			continue
		}
		// Ctrl+J line down
		if b == 0x0a {
			stream_scroll_adjust(g_rt.st, -1)
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
					stream_scroll_adjust(g_rt.st, 1)
					changed = true
				case 'B':
					stream_scroll_adjust(g_rt.st, -1)
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
							stream_scroll_adjust(g_rt.st, 1)
							changed = true
						} else if fb == 'B' {
							stream_scroll_adjust(g_rt.st, -1)
							changed = true
						} else if fb == '~' {
							// ESC [ 5 ~ PgUp, ESC [ 6 ~ PgDn
							if ps == "5" {
								stream_scroll_adjust(g_rt.st, half)
								changed = true
							} else if ps == "6" {
								stream_scroll_adjust(g_rt.st, -half)
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
								if btn_n == 64 || btn_n == 68 || btn_n == 72 || btn_n == 80 || btn_n == 4 {
									stream_scroll_adjust(g_rt.st, 3)
									changed = true
								} else if btn_n == 65 || btn_n == 69 || btn_n == 73 || btn_n == 81 || btn_n == 5 {
									stream_scroll_adjust(g_rt.st, -3)
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
	if g_rt.st == nil {
		return
	}
	// Throttled poll so fast SSE does not tcsetattr/read every token
	peek_turn_keys_throttled()
	if g_rt.cancel {
		// Stop buffering once cancel is requested; curl aborts via xferinfo/write_cb
		state_set_status(g_rt.st, "cancelling…")
		return
	}
	strings.write_string(&g_rt.st.live_assist, text)
	g_rt.st.streaming = true
	now := time.now()._nsec
	if g_rt.term != nil && (now - g_rt.st.last_redraw_ns) >= STREAM_REDRAW_NS {
		g_rt.st.last_redraw_ns = now
		stream_safe_render()
	}
}
