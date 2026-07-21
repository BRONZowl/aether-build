// Package tui — fullscreen chat UI (Grok Build key bindings + parity).
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:terminal"
import "core:time"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"

// Mid-stream full paints are expensive (markdown/mermaid flatten of live draft).
// ~12 fps is enough for tokens; 16ms (~60fps) starved curl + made the TUI feel frozen.
STREAM_REDRAW_NS :: i64(80_000_000) // ~80ms
// Key peek during stream_delta / xferinfo: don't tcsetattr every token.
STREAM_POLL_NS :: i64(40_000_000) // ~40ms


// run starts the fullscreen TUI.
// Input commands mirror Grok Build (03-keyboard-shortcuts.md).
run :: proc(opts: agent.Headless_Options) -> int {
	if !terminal.is_terminal(os.stdout) || !terminal.is_terminal(os.stdin) {
		fmt.eprintln("aether tui: requires a TTY (stdout+stdin). Use REPL or -p instead.")
		return 1
	}

	cfg := core.load_runtime_config(opts.model, opts.cwd, opts.max_turns, opts.permission_mode)
	defer core.destroy_runtime_config(&cfg)
	agent.apply_config_reasoning_effort(cfg.reasoning_effort)

	_ = agent.maybe_start_mcp(opts.no_mcp, true) // TUI quiet MCP connect messages
	defer agent.maybe_stop_mcp(nil) // always stop global (safe after /mcp reconnect)
	agent.maybe_start_hooks(cfg.cwd, true)
	defer agent.maybe_stop_hooks("exit")
	sreg := agent.maybe_start_skills(cfg.cwd, true)
	defer agent.maybe_stop_skills(sreg)

	creds, aerr := agent.resolve_credentials()
	if aerr != "" {
		fmt.eprintf("aether: %s\n", aerr)
		return 1
	}
	defer agent.destroy_credentials(&creds)

	auto_save := !opts.no_autosave
	sess, serr := open_session(opts, cfg.model, cfg.cwd, auto_save, cfg.permission_mode)
	if serr != "" {
		fmt.eprintf("aether: %s\n", serr)
		return 1
	}
	defer agent.destroy_session(&sess)

	model := sess.model if sess.model != "" else cfg.model
	cwd := sess.cwd if sess.cwd != "" else cfg.cwd
	perm := cfg.permission_mode
	// Last non-yolo mode for Ctrl+O toggle restore
	perm_before_yolo := perm if perm != .Always_Approve else core.Permission_Mode.Ask

	term: Term_State
	if !term_enter(&term) {
		fmt.eprintln("aether tui: failed to enter raw mode")
		return 1
	}
	defer term_leave(&term)

	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.model = strings.clone(model)
	state_set_cwd(&st, cwd)
	state_set_session_meta(&st, sess.id, sess.title)
	st.perm = strings.clone(core.permission_mode_string(perm))
	state_set_status(&st, "ready")
	// B55: discover notice only when transcript already has content.
	// Empty sessions get tips under brand art in flatten_blocks (V1).
	if len(sess.msgs) > 0 {
		state_add_notice(&st, core.brand_resume_tips_notice(context.temp_allocator))
	}
	rebuild_blocks(&st, sess.msgs[:])
	seed_prompt_history(&st, sess.msgs[:])

	dirty := true

	for !st.quit {
		// Keep top-bar location in sync (session /cd, /new, load).
		state_set_cwd(&st, cwd)
		if st.model != model {
			delete(st.model)
			st.model = strings.clone(model)
		}
		if dirty {
			render(&term, &st)
			dirty = false
		}

		// Window resize (SIGWINCH and/or size re-query): reflow without a keypress.
		if term_poll_resize(&term) {
			dirty = true
			continue
		}

		// Idle auto-wake: when safe, surface finished bg tasks without a user prompt
		if tui_can_auto_wake(&st) && agent.auto_wake_enabled() && agent.bg_has_undelivered() {
			if tui_run_auto_wake(
				&st,
				&sess,
				&term,
				&cfg,
				&creds,
				&model,
				&cwd,
				&perm,
				&perm_before_yolo,
				opts,
			) {
				dirty = true
				continue
			}
		}

		// Timed wait so SIGWINCH / size changes are noticed while idle.
		// (Blocking read would leave the layout stale until the next key.)
		// Auto-wake path uses 500ms; otherwise 200ms is snappy enough for resize.
		key: Key
		wait_ds: u8 = 5 if (tui_can_auto_wake(&st) && agent.auto_wake_enabled()) else 2
		b, ok := read_byte_timeout(wait_ds)
		if !ok {
			// timeout: check resize again and loop
			if term_poll_resize(&term) {
				dirty = true
			}
			continue
		}
		one := [1]u8{b}
		push_bytes(one[:])
		key = read_key()
		now := time.now()._nsec

		if st.esc_first_ns != 0 && now - st.esc_first_ns > ESC_CLEAR_NS {
			st.esc_first_ns = 0
		}
		if st.quit_first_ns != 0 && now - st.quit_first_ns > QUIT_CONFIRM_NS {
			st.quit_first_ns = 0
			if st.status == "press again to quit" {
				state_set_status(&st, "ready")
				dirty = true
			}
		}
		if st.new_first_ns != 0 && now - st.new_first_ns > QUIT_CONFIRM_NS {
			st.new_first_ns = 0
			if st.status == "press again for new session" {
				state_set_status(&st, "ready")
				dirty = true
			}
		}

		// Modals steal keys (Wave 0 overlay_kind order)
		if st.picker.active {
			if handle_picker_key(
				&st,
				&sess,
				&term,
				key,
				&model,
				&cwd,
				perm,
				opts,
			) {
				dirty = true
			}
			continue
		}
		if st.model_picker.active {
			if handle_model_picker_key(&st, &sess, &term, key, &model) {
				dirty = true
			}
			continue
		}
		if st.rewind_picker.active {
			if handle_rewind_picker_key(&st, &sess, &term, key) {
				dirty = true
			}
			continue
		}
		if st.settings_modal.active {
			if handle_settings_modal_key(&st, &perm, key) {
				dirty = true
			}
			continue
		}
		if st.queue_pane_active {
			if handle_queue_pane_key(&st, key) {
				dirty = true
			}
			continue
		}
		if st.extensions_hub.active {
			if handle_extensions_hub_key(&st, key) {
				dirty = true
			}
			continue
		}
		if st.dashboard.active {
			if handle_dashboard_key(&st, &sess, &term, key, &model, &cwd) {
				dirty = true
			}
			continue
		}
		if st.command_palette.active {
			if handle_command_palette_key(&st, key) {
				dirty = true
			}
			continue
		}
		if st.docs_picker.active {
			if handle_docs_picker_key_term(&st, &term, key) {
				dirty = true
			}
			continue
		}
		if st.personas_modal.active {
			if handle_personas_modal_key(&st, &term, key) {
				dirty = true
			}
			continue
		}
		if st.fork_modal.active {
			if handle_fork_modal_key(
				&st,
				&sess,
				&term,
				key,
				&model,
				&cwd,
				&perm,
				&perm_before_yolo,
				opts,
			) {
				dirty = true
			}
			continue
		}
		// Scrollback find mode
		if st.search.active {
			if handle_search_key(&st, key) {
				// ensure selected match visible
				if st.selected_block >= 0 {
					// body height approx via render path; call ensure after paint sizing
				}
				dirty = true
				// re-render with ensure: render handles ensure_block_visible
				continue
			}
			// fall through for scroll keys (handle_search returned false)
		}

		#partial switch key.kind {
		case .Ctrl_F:
			// Open scrollback search (not over ask modal; ok while idle/streaming)
			if !st.ask_active {
				search_open(&st, "")
				dirty = true
			}

		case .Tab:
			// B20 slash menu/complete · B22 @path · else Grok focus toggle
			if st.focus == .Prompt && try_slash_tab_complete(&st) {
				dirty = true
			} else if st.focus == .Prompt && try_path_tab_complete(&st, cwd) {
				dirty = true
			} else if st.focus == .Prompt {
				focus_scrollback(&st)
				state_set_status(&st, "scrollback")
				dirty = true
			} else {
				focus_prompt(&st)
				state_set_status(&st, "ready")
				dirty = true
			}

		case .Ctrl_C:
			st.esc_first_ns = 0
			st.quit_first_ns = 0
			st.new_first_ns = 0
			if st.streaming {
				stream_set_cancel()
				state_set_status(&st, "cancelling…")
				dirty = true
			} else if st.focus == .Scrollback {
				focus_prompt(&st)
				state_set_status(&st, "ready")
				dirty = true
			} else if len(st.input) > 0 {
				input_clear(&st)
				st.history_idx = -1
				state_set_status(&st, "ready")
				dirty = true
			} else {
				state_set_status(&st, "Ctrl+Q twice to quit")
				dirty = true
			}

		case .Ctrl_Q, .Ctrl_D:
			st.esc_first_ns = 0
			st.new_first_ns = 0
			if st.quit_first_ns != 0 && now - st.quit_first_ns <= QUIT_CONFIRM_NS {
				st.quit = true
			} else {
				st.quit_first_ns = now
				state_set_status(&st, "press again to quit")
				dirty = true
			}

		case .Ctrl_N:
			// Grok: double-press within 1s → new session (normal only; no worktree)
			st.esc_first_ns = 0
			st.quit_first_ns = 0
			if st.streaming {
				state_set_status(&st, "finish turn first")
				dirty = true
			} else if st.new_first_ns != 0 && now - st.new_first_ns <= QUIT_CONFIRM_NS {
				st.new_first_ns = 0
				if tui_new_session(&st, &sess, &model, &cwd, perm, opts) {
					state_set_status(&st, fmt.tprintf("new session %s", sess.id))
				}
				dirty = true
			} else {
				st.new_first_ns = now
				state_set_status(&st, "press again for new session")
				dirty = true
			}

		case .Ctrl_O:
			// Grok: toggle always-approve (YOLO). Live for subsequent tools mid-turn.
			toggle_yolo(&st, &perm, &perm_before_yolo)
			dirty = true

		case .Shift_Tab:
			// Slash menu: reverse highlight; else Grok mode cycle (ask→plan→…).
			if st.focus == .Prompt && slash_menu_navigate(&st, -1) {
				dirty = true
			} else {
				cycle_mode(&st, &perm, &perm_before_yolo, cwd)
				dirty = true
			}

		case .Ctrl_S:
			st.new_first_ns = 0
			if st.streaming {
				state_set_status(&st, "finish turn first")
				dirty = true
			} else {
				err := picker_open(&st.picker, sess.sessions_dir)
				if err != "" {
					state_set_status(&st, err)
				} else {
					state_set_status(&st, "session picker")
				}
				dirty = true
			}

		case .Esc:
			st.quit_first_ns = 0
			if st.focus == .Scrollback {
				focus_prompt(&st)
				state_set_status(&st, "ready")
				dirty = true
			} else if st.focus == .Prompt && slash_menu_dismiss(&st) {
				// First Esc closes live slash menu / clears slash token
				st.esc_first_ns = 0
				dirty = true
			} else if len(st.input) > 0 {
				if st.esc_first_ns != 0 && now - st.esc_first_ns <= ESC_CLEAR_NS {
					input_clear(&st)
					st.history_idx = -1
					st.esc_first_ns = 0
					state_set_status(&st, "ready")
					dirty = true
				} else {
					st.esc_first_ns = now
					state_set_status(&st, "press again to clear")
					dirty = true
				}
			} else {
				st.esc_first_ns = 0
			}

		case .Enter:
			if st.focus == .Scrollback {
				// Grok: Enter opens block viewer — we just ensure selection + fold hint
				if set_selected_tool_expand(&st, -1) {
					dirty = true
				}
				continue
			}
			if st.multiline_mode {
				input_insert_byte(&st, '\n')
				dirty = true
				continue
			}
			if input_apply_backslash_continuation(&st) {
				dirty = true
				continue
			}
			if handle_submit(&st, &sess, &term, &cfg, &creds, &model, &cwd, &perm, &perm_before_yolo, opts) {
				dirty = true
			}

		case .Mod_Enter:
			if st.focus == .Scrollback {
				continue
			}
			if st.multiline_mode {
				if handle_submit(&st, &sess, &term, &cfg, &creds, &model, &cwd, &perm, &perm_before_yolo, opts) {
					dirty = true
				}
			} else {
				input_insert_byte(&st, '\n')
				dirty = true
			}

		case .Ctrl_M:
			// Grok: prompt → multiline; scrollback → model picker
			if st.focus == .Prompt {
				st.multiline_mode = !st.multiline_mode
				state_set_status(&st, "multiline on" if st.multiline_mode else "multiline off")
				dirty = true
			} else if st.streaming {
				state_set_status(&st, "finish turn first")
				dirty = true
			} else {
				model_picker_open(&st.model_picker, model)
				state_set_status(&st, "model picker")
				dirty = true
			}

		case .Ctrl_U:
			stream_scroll_adjust(&st, max(1, term.rows / 2))
			dirty = true

		case .Ctrl_J:
			stream_scroll_adjust(&st, -1)
			dirty = true

		case .Ctrl_K:
			stream_scroll_adjust(&st, 1)
			dirty = true

		case .Backspace:
			if st.focus == .Scrollback {
				focus_prompt(&st)
			}
			input_backspace(&st)
			st.history_idx = -1
			dirty = true

		case .Left:
			if st.focus == .Scrollback {
				if set_selected_tool_expand(&st, 0) {
					dirty = true
				}
			} else {
				input_move_left(&st)
				dirty = true
			}

		case .Right:
			if st.focus == .Scrollback {
				if set_selected_tool_expand(&st, 1) {
					dirty = true
				}
			} else {
				input_move_right(&st)
				dirty = true
			}

		case .Home:
			if st.focus == .Prompt {
				input_home(&st)
				dirty = true
			}

		case .End:
			if st.focus == .Prompt {
				input_end(&st)
				dirty = true
			}

		case .Mouse_Wheel_Up:
			// Wheel: scroll toward older content (increase scroll offset)
			stream_scroll_adjust(&st, 3)
			dirty = true

		case .Mouse_Wheel_Down:
			stream_scroll_adjust(&st, -3)
			dirty = true

		case .Mouse_Click:
			// C2.3: left-click select block / focus prompt
			if overlay_is_open(&st) {
				// ignore over modals (picker/search keep keyboard)
				continue
			}
			if apply_mouse_click(&st, &term, key.mouse_x, key.mouse_y) {
				dirty = true
			}

		case .Mouse_Middle:
			// C2.5 / M1: middle-click → paste PRIMARY + image path attach
			if overlay_is_open(&st) {
				continue
			}
			if apply_middle_paste(&st) {
				dirty = true
			}

		case .Ctrl_V:
			// M1: Ctrl+V → clipboard image preferred, else text / path attach
			if overlay_is_open(&st) {
				continue
			}
			if apply_paste(&st, true) {
				dirty = true
			}

		case .Paste:
			// C2.6: bracketed paste (terminal multi-line) → bulk insert + image path attach
			if overlay_is_open(&st) {
				continue
			}
			if apply_bracketed_paste(&st, key.text) {
				dirty = true
			}

		case .Shift_Left:
			// C2.4: prev user turn (simple + vim; works from prompt too)
			if overlay_is_open(&st) {
				continue
			}
			if st.focus != .Scrollback {
				focus_scrollback(&st)
			}
			_ = scrollback_move_sel_kind(&st, -1, .User)
			dirty = true

		case .Shift_Right:
			// C2.4: next user turn
			if overlay_is_open(&st) {
				continue
			}
			if st.focus != .Scrollback {
				focus_scrollback(&st)
			}
			_ = scrollback_move_sel_kind(&st, 1, .User)
			dirty = true

		case .Char:
			// Space in scrollback → focus prompt (Grok)
			if st.focus == .Scrollback && key.ch == ' ' {
				focus_prompt(&st)
				state_set_status(&st, "ready")
				dirty = true
				continue
			}
			if st.focus == .Scrollback && key.ch == 'e' {
				if set_selected_tool_expand(&st, -1) {
					dirty = true
				}
				continue
			}
			// Grok: y / Y copy selected block (scrollback only)
			if st.focus == .Scrollback && (key.ch == 'y' || key.ch == 'Y') {
				msg := copy_selected_block(&st, key.ch == 'Y')
				state_set_status(&st, msg)
				dirty = true
				continue
			}
			// Vim mode (C2.2–4): j/k/g/G/i + H/L/J/K turn nav — no auto-focus on letters
			if st.focus == .Scrollback && core.vim_mode_enabled() {
				switch key.ch {
				case 'j':
					_ = scrollback_move_sel(&st, 1)
					dirty = true
				case 'k':
					_ = scrollback_move_sel(&st, -1)
					dirty = true
				case 'g':
					_ = scrollback_select_edge(&st, true)
					dirty = true
				case 'G':
					_ = scrollback_select_edge(&st, false)
					dirty = true
				case 'H':
					// prev user turn
					_ = scrollback_move_sel_kind(&st, -1, .User)
					dirty = true
				case 'L':
					// next user turn
					_ = scrollback_move_sel_kind(&st, 1, .User)
					dirty = true
				case 'K':
					// prev assistant
					_ = scrollback_move_sel_kind(&st, -1, .Assistant)
					dirty = true
				case 'J':
					// next assistant
					_ = scrollback_move_sel_kind(&st, 1, .Assistant)
					dirty = true
				case 'i':
					focus_prompt(&st)
					state_set_status(&st, "ready")
					dirty = true
				case:
					// swallow other chars in vim scrollback (do not type into prompt)
				}
				continue
			}
			// Simple mode: typing focuses prompt and inserts
			if st.focus == .Scrollback {
				focus_prompt(&st)
			}
			if key.ch == 'e' && len(st.input) == 0 && st.focus == .Prompt {
				if toggle_last_tool_expand(&st) {
					dirty = true
				}
				continue
			}
			// editing resets Tab LCP cycle; menu recompute uses live prefix
			if st.slash_comp_prefix != "" {
				slash_complete_reset(&st)
			}
			// typing resets highlight unless still navigating same list
			prev_pref, _ := slash_token_prefix(input_text(&st), st.cursor)
			input_insert_rune(&st, key.ch)
			st.history_idx = -1
			new_pref, okp := slash_token_prefix(input_text(&st), st.cursor)
			if !okp || new_pref != prev_pref {
				// keep sel if still prefix-extending (e.g. /h → /he)
				if !(okp && strings.has_prefix(new_pref, prev_pref) && prev_pref != "") {
					st.slash_menu_sel = 0
				}
			}
			dirty = true

		case .PgUp:
			stream_scroll_adjust(&st, max(1, term.rows / 2))
			dirty = true

		case .PgDn:
			stream_scroll_adjust(&st, -max(1, term.rows / 2))
			dirty = true

		case .Up:
			// Live slash menu navigation (before history / scrollback)
			if st.focus == .Prompt && slash_menu_navigate(&st, -1) {
				dirty = true
				continue
			}
			if st.focus == .Scrollback {
				_ = scrollback_move_sel(&st, -1)
				dirty = true
				continue
			}
			if len(st.input) == 0 || st.history_idx >= 0 {
				if history_up(&st) {
					dirty = true
					continue
				}
			}
			if len(st.input) > 0 && strings.contains_rune(input_text(&st), '\n') {
				input_home(&st)
				if st.cursor > 0 {
					input_move_left(&st)
					input_home(&st)
				}
			} else if st.history_idx < 0 {
				stream_scroll_adjust(&st, 1)
			}
			dirty = true

		case .Down:
			if st.focus == .Prompt && slash_menu_navigate(&st, 1) {
				dirty = true
				continue
			}
			if st.focus == .Scrollback {
				_ = scrollback_move_sel(&st, 1)
				dirty = true
				continue
			}
			if st.history_idx >= 0 {
				if history_down(&st) {
					dirty = true
					continue
				}
			}
			if len(st.input) > 0 && strings.contains_rune(input_text(&st), '\n') {
				input_end(&st)
				if st.cursor < len(st.input) {
					input_move_right(&st)
					input_end(&st)
				}
			} else {
				stream_scroll_adjust(&st, -1)
			}
			dirty = true
		}
	}

	if sess.auto_save {
		_ = agent.session_save(&sess)
	}
	return 0
}




// tui_can_auto_wake: idle, empty compose, no modals.





