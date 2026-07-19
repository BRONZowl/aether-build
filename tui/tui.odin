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

STREAM_REDRAW_NS :: i64(16_000_000) // ~16ms


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
	state_set_session_meta(&st, sess.id, sess.title)
	st.perm = strings.clone(core.permission_mode_string(perm))
	state_set_status(&st, "ready")
	// B55: discover notice only when transcript already has content.
	// Empty sessions get tips under brand art in flatten_blocks (V1).
	if len(sess.msgs) > 0 {
		state_add_notice(&st, "tips: /about · /keys · /tools · /help")
	}
	rebuild_blocks(&st, sess.msgs[:])
	seed_prompt_history(&st, sess.msgs[:])

	dirty := true

	for !st.quit {
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

		// Modals steal keys
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
				g_cancel = true
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
			if st.ask_active || st.picker.active || st.model_picker.active || st.search.active {
				// ignore over modals (picker/search keep keyboard)
				continue
			}
			if apply_mouse_click(&st, &term, key.mouse_x, key.mouse_y) {
				dirty = true
			}

		case .Mouse_Middle:
			// C2.5 / M1: middle-click → paste PRIMARY + image path attach
			if st.ask_active || st.picker.active || st.model_picker.active || st.search.active {
				continue
			}
			if apply_middle_paste(&st) {
				dirty = true
			}

		case .Ctrl_V:
			// M1: Ctrl+V → clipboard image preferred, else text / path attach
			if st.ask_active || st.picker.active || st.model_picker.active || st.search.active {
				continue
			}
			if apply_paste(&st, true) {
				dirty = true
			}

		case .Paste:
			// C2.6: bracketed paste (terminal multi-line) → bulk insert + image path attach
			if st.ask_active || st.picker.active || st.model_picker.active || st.search.active {
				continue
			}
			if apply_bracketed_paste(&st, key.text) {
				dirty = true
			}

		case .Shift_Left:
			// C2.4: prev user turn (simple + vim; works from prompt too)
			if st.ask_active || st.picker.active || st.model_picker.active || st.search.active {
				continue
			}
			if st.focus != .Scrollback {
				focus_scrollback(&st)
			}
			_ = scrollback_move_sel_kind(&st, -1, .User)
			dirty = true

		case .Shift_Right:
			// C2.4: next user turn
			if st.ask_active || st.picker.active || st.model_picker.active || st.search.active {
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

// handle_model_picker_key routes keys while model picker is open.
handle_model_picker_key :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	key: Key,
	model: ^string,
) -> bool {
	#partial switch key.kind {
	case .Esc, .Ctrl_C, .Ctrl_M:
		model_picker_close(&st.model_picker)
		state_set_status(st, "ready")
		return true
	case .Ctrl_Q, .Ctrl_D:
		model_picker_close(&st.model_picker)
		st.quit = true
		return true
	case .Up, .Ctrl_K:
		model_picker_move(&st.model_picker, -1)
		return true
	case .Down, .Ctrl_J:
		model_picker_move(&st.model_picker, 1)
		return true
	case .PgUp, .Ctrl_U:
		model_picker_move(&st.model_picker, -max(1, term.rows / 2))
		return true
	case .PgDn:
		model_picker_move(&st.model_picker, max(1, term.rows / 2))
		return true
	case .Enter:
		chosen := model_picker_selected(&st.model_picker)
		if chosen == "" {
			state_set_status(st, "no model selected")
			return true
		}
		// apply to runtime model + session + header + user config
		delete(model^)
		model^ = strings.clone(chosen)
		delete(st.model)
		st.model = strings.clone(chosen)
		delete(sess.model)
		sess.model = strings.clone(chosen)
		if sess.auto_save {
			_ = agent.session_save(sess)
		}
		_ = core.persist_default_model(chosen)
		model_picker_close(&st.model_picker)
		state_set_status(st, fmt.tprintf("model: %s", chosen))
		state_add_notice(st, fmt.tprintf("model set to %s", chosen))
		return true
	case .Backspace:
		if len(st.model_picker.filter) > 0 {
			resize(&st.model_picker.filter, len(st.model_picker.filter) - 1)
			model_picker_refilter(&st.model_picker)
			return true
		}
		return false
	case .Char:
		if key.ch >= 32 && key.ch < 127 {
			append(&st.model_picker.filter, u8(key.ch))
			model_picker_refilter(&st.model_picker)
			return true
		}
	}
	return false
}

// handle_picker_key routes keys while session picker is open. Returns dirty.
handle_picker_key :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	key: Key,
	model: ^string,
	cwd: ^string,
	perm: core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		picker_close(&st.picker)
		state_set_status(st, "ready")
		return true
	case .Ctrl_Q, .Ctrl_D:
		// allow quit even from picker
		picker_close(&st.picker)
		st.quit = true
		return true
	case .Ctrl_S:
		// toggle close
		picker_close(&st.picker)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		picker_move(&st.picker, -1)
		return true
	case .Down, .Ctrl_J:
		picker_move(&st.picker, 1)
		return true
	case .PgUp, .Ctrl_U:
		picker_move(&st.picker, -max(1, term.rows / 2))
		return true
	case .PgDn:
		picker_move(&st.picker, max(1, term.rows / 2))
		return true
	case .Enter:
		path := picker_selected_path(&st.picker)
		id := picker_selected_id(&st.picker)
		if path == "" {
			state_set_status(st, "no session selected")
			return true
		}
		if tui_load_session_path(st, sess, path, model, cwd) {
			picker_close(&st.picker)
			state_set_status(st, fmt.tprintf("loaded %s", id))
		}
		return true
	case .Backspace:
		if len(st.picker.filter) > 0 {
			// pop last byte (ASCII filter)
			resize(&st.picker.filter, len(st.picker.filter) - 1)
			picker_refilter(&st.picker)
			return true
		}
		return false
	case .Char:
		if key.ch >= 32 && key.ch < 127 {
			append(&st.picker.filter, u8(key.ch))
			picker_refilter(&st.picker)
			return true
		}
	}
	return false
}

// tui_new_session creates a fresh session (same as /new) and refreshes UI.
tui_new_session :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	model: ^string,
	cwd: ^string,
	perm: core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	g_slash_state = st
	defer g_slash_state = nil
	slash_out :: proc(msg: string) {
		if g_slash_state != nil {
			state_add_notice(g_slash_state, msg)
		}
	}
	// perm is by-value here; use stack pointer for slash mutability
	perm_mut := perm
	action := agent.run_slash(sess, "/new", opts, model, cwd, &perm_mut, slash_out)
	if action != .Session_Changed && action != .Continue {
		return false
	}
	delete(st.model)
	st.model = strings.clone(model^)
	state_set_session_meta(st, sess.id, sess.title)
	rebuild_blocks(st, sess.msgs[:])
	seed_prompt_history(st, sess.msgs[:])
	stream_pin_bottom(st)
	input_clear(st)
	st.history_idx = -1
	clamp_selected_block(st)
	focus_prompt(st)
	return true
}

// tui_load_session_path loads a session file into sess and refreshes UI state.
tui_load_session_path :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	path: string,
	model: ^string,
	cwd: ^string,
) -> bool {
	if sess.auto_save {
		if e := agent.session_save(sess); e != "" {
			state_add_notice(st, fmt.tprintf("autosave failed before load: %s", e))
		}
	}
	loaded, lerr := agent.session_load_file(path, sess.auto_save)
	if lerr != "" {
		state_set_status(st, lerr)
		state_add_notice(st, fmt.tprintf("load failed: %s", lerr))
		return false
	}
	old_auto := sess.auto_save
	agent.destroy_session(sess)
	sess^ = loaded
	sess.auto_save = old_auto
	if sess.model != "" {
		model^ = sess.model
	}
	if sess.cwd != "" {
		cwd^ = sess.cwd
	}
	delete(st.model)
	st.model = strings.clone(model^)
	state_set_session_meta(st, sess.id, sess.title)
	rebuild_blocks(st, sess.msgs[:])
	seed_prompt_history(st, sess.msgs[:])
	stream_pin_bottom(st)
	input_clear(st)
	st.history_idx = -1
	clamp_selected_block(st)
	focus_prompt(st)
	return true
}

history_up :: proc(s: ^App_State) -> bool {
	if len(s.prompt_history) == 0 {
		return false
	}
	if s.history_idx < 0 {
		s.history_idx = len(s.prompt_history) - 1
	} else if s.history_idx > 0 {
		s.history_idx -= 1
	} else {
		return true // already at oldest
	}
	input_set_text(s, s.prompt_history[s.history_idx])
	return true
}



history_down :: proc(s: ^App_State) -> bool {
	if s.history_idx < 0 {
		return false
	}
	if s.history_idx + 1 >= len(s.prompt_history) {
		// past newest → clear and leave history mode
		s.history_idx = -1
		input_clear(s)
		return true
	}
	s.history_idx += 1
	input_set_text(s, s.prompt_history[s.history_idx])
	return true
}

input_set_text :: proc(s: ^App_State, text: string) {
	clear(&s.input)
	for i in 0 ..< len(text) {
		append(&s.input, text[i])
	}
	s.cursor = len(s.input)
}

// seed_prompt_history: global durable history (B23) then this session's user turns.
// Oldest-first so Up from empty walks newest last entries first.
seed_prompt_history :: proc(s: ^App_State, msgs: []agent.Chat_Message) {
	for h in s.prompt_history {
		delete(h)
	}
	clear(&s.prompt_history)
	s.history_idx = -1
	// 1) global file (oldest → newest)
	global := core.load_prompt_history(context.allocator)
	defer core.destroy_prompt_history_list(global)
	for g in global {
		append(&s.prompt_history, strings.clone(g))
	}
	// 2) session user prompts (append; skip consecutive dups of last)
	for m in msgs {
		if m.role == .User && m.content != "" {
			if len(s.prompt_history) > 0 &&
			   s.prompt_history[len(s.prompt_history) - 1] == m.content {
				continue
			}
			append(&s.prompt_history, strings.clone(m.content))
		}
	}
	// cap
	for len(s.prompt_history) > core.PROMPT_HISTORY_MAX {
		delete(s.prompt_history[0])
		ordered_remove(&s.prompt_history, 0)
	}
}

input_apply_backslash_continuation :: proc(s: ^App_State) -> bool {
	text := input_text(s)
	end := len(text)
	for end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t') {
		end -= 1
	}
	if end == 0 || text[end - 1] != '\\' {
		return false
	}
	s.cursor = len(s.input)
	for len(s.input) > end - 1 {
		input_backspace(s)
	}
	input_insert_byte(s, '\n')
	return true
}

// copy_selected_block: y = full text; Y = tool metadata when possible.
copy_selected_block :: proc(st: ^App_State, meta: bool) -> string {
	i := st.selected_block
	if i < 0 || i >= len(st.blocks) {
		return "nothing selected"
	}
	b := st.blocks[i]
	text: string
	if meta && b.kind == .Tool {
		// tool name + first line of body (args preview)
		first := b.text
		if nl := strings.index_byte(first, '\n'); nl >= 0 {
			first = first[:nl]
		}
		name := b.tool_name if b.tool_name != "" else "tool"
		text = fmt.tprintf("%s\n%s", name, first)
	} else {
		text = b.text
	}
	if text == "" {
		return "empty block"
	}
	return copy_to_clipboard(text)
}


// tui_can_auto_wake: idle, empty compose, no modals.
tui_can_auto_wake :: proc(st: ^App_State) -> bool {
	if st.streaming || st.ask_active {
		return false
	}
	if st.picker.active || st.model_picker.active || st.search.active {
		return false
	}
	if len(st.input) > 0 {
		return false
	}
	return true
}

// tui_run_auto_wake runs a synthetic parent turn for undelivered bg completions.
tui_run_auto_wake :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	cfg: ^core.Runtime_Config,
	creds: ^agent.Credentials,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	state_set_status(st, "auto-wake…")
	state_add_notice(st, "background task completed — waking agent")
	strings.builder_reset(&st.live_assist)
	st.streaming = true
	stream_pin_bottom(st)
	g_cancel = false
	ask_turn_allow := false
	g_perm = perm
	g_perm_before = perm_before
	render(term, st)

	g_stream_state = st
	g_stream_term = term
	g_sess = sess
	agent.set_content_delta_handler(stream_delta)
	g_status_state = st
	g_status_term = term

	status_cb :: proc(text: string) {
		peek_turn_keys()
		if g_status_state != nil {
			if strings.has_prefix(text, "tool:") {
				strings.builder_reset(&g_status_state.live_assist)
			}
			state_set_status(g_status_state, text)
			if g_status_term != nil {
				render(g_status_term, g_status_state)
			}
		}
	}
	history_cb :: proc() {
		peek_turn_keys()
		if g_stream_state == nil || g_sess == nil {
			return
		}
		rebuild_blocks(g_stream_state, g_sess.msgs[:])
		// B31: only stick to bottom when follow is on
		stream_maybe_pin_bottom(g_stream_state)
		if g_stream_term != nil {
			render(g_stream_term, g_stream_state)
		}
	}

	turn := agent.Turn_Options {
		workspace         = cwd^,
		max_turns         = cfg.max_turns,
		quiet             = true,
		verbose           = opts.verbose,
		permission_mode   = perm^,
		permission_live   = perm,
		permission_allow  = cfg.permission_allow[:],
		permission_deny   = cfg.permission_deny[:],
		ask_turn_allow    = &ask_turn_allow,
		on_status         = status_cb,
		on_history        = history_cb,
		on_ask            = tui_ask_tool,
		on_ask_user       = tui_ask_user_question,
		on_plan_enter     = tui_plan_enter_ask,
		on_plan_exit      = tui_plan_exit_ask,
		cancel            = &g_cancel,
		on_poll           = peek_turn_keys,
		mcp_enabled       = agent.mcp_enabled_for_turn(),
		skills_enabled    = agent.skills_enabled_for_turn(),
		subagents_enabled = agent.subagents_enabled(),
	}
	ran, code := agent.try_idle_auto_wake(creds^, model^, &sess.msgs, turn)
	_ = code

	agent.set_content_delta_handler(nil)
	g_stream_state = nil
	g_stream_term = nil
	g_status_state = nil
	g_status_term = nil
	g_sess = nil
	g_perm = nil
	g_perm_before = nil

	st.streaming = false
	strings.builder_reset(&st.live_assist)
	if sess.auto_save {
		if e := agent.session_save(sess); e != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", e))
		}
	}
	state_set_session_meta(st, sess.id, sess.title)
	rebuild_blocks(st, sess.msgs[:])
	stream_pin_bottom(st)
	clamp_selected_block(st)
	g_cancel = false
	if ran {
		state_set_status(st, "ready")
	}
	return ran
}

// handle_submit: slash or agent turn. model/cwd may change via /load /new.
handle_submit :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	cfg: ^core.Runtime_Config,
	creds: ^agent.Credentials,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	line := strings.trim_space(input_text(st))
	if line == "" {
		return false
	}

	if strings.has_prefix(line, "/") {
		return handle_slash(st, sess, term, line, model, cwd, perm, perm_before, opts)
	}

	prompt := strings.clone(line)
	// UserPromptSubmit may block the turn
	if ok, why := agent.allow_user_prompt_notice(cwd^, prompt); !ok {
		delete(prompt)
		input_clear(st)
		state_add_notice(st, fmt.tprintf("prompt blocked by hook: %s", why if why != "" else "UserPromptSubmit"))
		state_set_status(st, "ready")
		return true
	}
	history_push(st, prompt)
	state_add_block(st, .User, prompt)
	append(
		&sess.msgs,
		agent.Chat_Message {
			role    = .User,
			content = prompt,
		},
	)
	input_clear(st)
	st.history_idx = -1
	st.esc_first_ns = 0
	st.quit_first_ns = 0
	state_set_status(st, "sampling…")
	strings.builder_reset(&st.live_assist)
	st.streaming = true
	stream_pin_bottom(st)
	g_cancel = false
	ask_turn_allow := false
	g_perm = perm
	g_perm_before = perm_before
	render(term, st)

	g_stream_state = st
	g_stream_term = term
	g_sess = sess
	agent.set_content_delta_handler(stream_delta)
	g_status_state = st
	g_status_term = term
	status_cb :: proc(text: string) {
		peek_turn_keys()
		if g_status_state != nil {
			// When tools start, drop live stream so it doesn't double with history
			if strings.has_prefix(text, "tool:") {
				strings.builder_reset(&g_status_state.live_assist)
			}
			state_set_status(g_status_state, text)
			if g_status_term != nil {
				render(g_status_term, g_status_state)
			}
		}
	}
	history_cb :: proc() {
		peek_turn_keys()
		if g_stream_state == nil || g_sess == nil {
			return
		}
		rebuild_blocks(g_stream_state, g_sess.msgs[:])
		// B31: stick to bottom only while stream_follow (user scrolled up → keep place)
		stream_maybe_pin_bottom(g_stream_state)
		if g_stream_term != nil {
			render(g_stream_term, g_stream_state)
		}
	}

	turn := agent.Turn_Options {
		workspace         = cwd^,
		max_turns         = cfg.max_turns,
		quiet             = true,
		verbose           = opts.verbose,
		permission_mode   = perm^,
		permission_live   = perm,
		permission_allow  = cfg.permission_allow[:],
		permission_deny   = cfg.permission_deny[:],
		ask_turn_allow    = &ask_turn_allow,
		on_status         = status_cb,
		on_history        = history_cb,
		on_ask            = tui_ask_tool,
		on_ask_user       = tui_ask_user_question,
		on_plan_enter     = tui_plan_enter_ask,
		on_plan_exit      = tui_plan_exit_ask,
		cancel            = &g_cancel,
		on_poll           = peek_turn_keys,
		mcp_enabled       = agent.mcp_enabled_for_turn(),
		skills_enabled    = agent.skills_enabled_for_turn(),
		subagents_enabled = agent.subagents_enabled(),
		memory_injected   = &sess.memory_injected,
		session           = sess,
	}
	final_text, code := agent.run_agent_turn(creds^, model^, &sess.msgs, turn)

	agent.set_content_delta_handler(nil)
	g_stream_state = nil
	g_stream_term = nil
	g_status_state = nil
	g_status_term = nil
	g_sess = nil
	g_perm = nil
	g_perm_before = nil

	st.streaming = false
	if len(strings.to_string(st.live_assist)) > 0 {
		render(term, st)
	}
	strings.builder_reset(&st.live_assist)

	// B19: turn-complete desktop notify (hooks always; desktop gated)
	agent.maybe_notify_agent_turn(code, sess.title, final_text, cwd^)

	// Autosave after any agent turn (user msg already appended) — success, max-turns, cancel, error.
	// session_save also auto-titles from first user prompt when title empty.
	save_err := ""
	if sess.auto_save {
		save_err = agent.session_save(sess)
	}
	state_set_session_meta(st, sess.id, sess.title)

	// Preserve last status if it already carries error detail
	last := st.status
	if code == 0 {
		delete(final_text)
		if save_err != "" {
			state_set_status(st, fmt.tprintf("autosave failed: %s", save_err))
			state_add_notice(st, st.status)
		} else {
			state_set_status(st, "ready")
		}
	} else if code == 2 {
		if !strings.has_prefix(last, "max turns") {
			state_set_status(st, "max turns — history kept")
		}
		state_add_notice(st, st.status)
		if save_err != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", save_err))
		}
	} else if code == 4 {
		if last != "cancelled" {
			state_set_status(st, "cancelled")
		}
		state_add_notice(st, "turn cancelled — history kept")
		if save_err != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", save_err))
		}
	} else {
		// code 3: prefer on_status "error: …" already set
		if !strings.has_prefix(last, "error") {
			state_set_status(st, "error")
		}
		state_add_notice(st, st.status)
		if save_err != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", save_err))
		}
	}
	rebuild_blocks(st, sess.msgs[:])
	stream_pin_bottom(st)
	clamp_selected_block(st)
	g_cancel = false
	return true
}

handle_slash :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	line: string,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	// Local TUI-only
	if line == "/yolo" {
		input_clear(st)
		toggle_yolo(st, perm, perm_before)
		return true
	}
	if line == "/find" || strings.has_prefix(line, "/find ") {
		input_clear(st)
		q := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			q = strings.trim_space(line[sp + 1:])
		}
		search_open(st, q)
		return true
	}
	if line == "/multiline" || line == "/ml" {
		// B36: /ml alias (Grok-shaped)
		input_clear(st)
		st.multiline_mode = !st.multiline_mode
		state_set_status(st, "multiline on" if st.multiline_mode else "multiline off")
		return true
	}
	// B40: bare /copy with a scrollback selection → copy that block (else agent Nth assistant)
	if line == "/copy" {
		if st.selected_block >= 0 && st.selected_block < len(st.blocks) {
			input_clear(st)
			msg := copy_selected_block(st, false)
			state_set_status(st, msg)
			state_add_notice(st, fmt.tprintf("aether: /copy selected → %s", msg))
			return true
		}
		// no selection: fall through to agent /copy (latest assistant)
	}
	if line == "/resume" || line == "/sessions-ui" {
		input_clear(st)
		err := picker_open(&st.picker, sess.sessions_dir)
		if err != "" {
			state_set_status(st, err)
		} else {
			state_set_status(st, "session picker")
		}
		return true
	}
	if line == "/model" || strings.has_prefix(line, "/model ") {
		input_clear(st)
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			arg = strings.trim_space(line[sp + 1:])
		}
		if arg != "" {
			// direct set: /model grok-4.5
			delete(model^)
			model^ = strings.clone(arg)
			delete(st.model)
			st.model = strings.clone(arg)
			delete(sess.model)
			sess.model = strings.clone(arg)
			if sess.auto_save {
				_ = agent.session_save(sess)
			}
			_ = core.persist_default_model(arg)
			state_set_status(st, fmt.tprintf("model: %s", arg))
			state_add_notice(st, fmt.tprintf("model set to %s", arg))
			return true
		}
		model_picker_open(&st.model_picker, model^)
		state_set_status(st, "model picker")
		return true
	}
	// /history N → fill composer with that prompt (Grok recall UX)
	if line == "/history" || strings.has_prefix(line, "/history ") {
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			arg = strings.trim_space(line[sp + 1:])
		}
		if idx, ok := agent.parse_history_index(arg); ok {
			prompts := agent.collect_user_prompts(sess.msgs[:], context.temp_allocator)
			if idx <= len(prompts) {
				input_set_text(st, prompts[idx - 1])
				st.history_idx = -1
				state_set_status(st, fmt.tprintf("recalled history #%d", idx))
				state_add_notice(st, fmt.tprintf("aether: loaded history #%d into prompt", idx))
				return true
			}
			// fall through to slash for error message
		}
		// list / filter via shared slash handler
	}

	// Capture notices via package-level sink target
	g_slash_state = st
	defer g_slash_state = nil
	slash_out :: proc(msg: string) {
		if g_slash_state != nil {
			state_add_notice(g_slash_state, msg)
		}
	}

	action := agent.run_slash(sess, line, opts, model, cwd, perm, slash_out)
	input_clear(st)
	st.history_idx = -1
	// keep header chip in sync when /auto /always-approve change perm
	delete(st.perm)
	st.perm = strings.clone(core.permission_mode_string(perm^))

	switch action {
	case .Exit:
		st.quit = true
		return false
	case .Session_Changed:
		// refresh header + blocks + history
		delete(st.model)
		st.model = strings.clone(model^)
		state_set_session_meta(st, sess.id, sess.title)
		rebuild_blocks(st, sess.msgs[:])
		seed_prompt_history(st, sess.msgs[:])
		stream_pin_bottom(st)
		// B56: /clear and /new drop ephemeral notice spam
		if line == "/clear" || line == "/new" || strings.has_prefix(line, "/new ") {
			state_clear_notices(st)
		}
		state_set_status(st, "ready")
		return true
	case .Continue:
		// show last notice in status if any
		if len(st.notices) > 0 {
			state_set_status(st, st.notices[len(st.notices) - 1])
		}
		return true
	}
	return true
}




open_session :: proc(
	opts: agent.Headless_Options,
	model: string,
	cwd: string,
	auto_save: bool,
	perm: core.Permission_Mode,
) -> (agent.Session, string) {
	if opts.session_ref != "" {
		path, err := agent.resolve_session_ref(opts.session_ref, opts.sessions_dir, context.temp_allocator)
		if err != "" {
			return {}, err
		}
		return agent.session_load_file(path, auto_save)
	}
	if opts.continue_last {
		path := agent.most_recent_session_path(opts.sessions_dir, context.temp_allocator)
		if path == "" {
			return {}, "no previous sessions to continue"
		}
		return agent.session_load_file(path, auto_save)
	}
	catalog := agent.skills_catalog_text(context.temp_allocator)
	return agent.new_session(model, cwd, opts.sessions_dir, auto_save, perm, context.allocator, catalog), ""
}

rebuild_blocks :: proc(s: ^App_State, msgs: []agent.Chat_Message) {
	// Preserve expand state by tool name order (best-effort)
	prev_expand := make(map[string]bool, context.temp_allocator)
	// B37: preserve wall-clock stamps across rebuild (match kind+text key)
	prev_stamp := make(map[string]i64, context.temp_allocator)
	for b in s.blocks {
		if b.kind == .Tool && b.tool_name != "" {
			prev_expand[b.tool_name] = b.expanded
		}
		if b.time_unix != 0 {
			k := block_stamp_key(b.kind, b.text, b.tool_name, context.temp_allocator)
			prev_stamp[k] = b.time_unix
		}
	}
	state_clear_blocks(s)

	Pending_Tool :: struct {
		name: string,
		args: string,
	}
	pending := make(map[string]Pending_Tool, context.temp_allocator)
	defer delete(pending)

	// restore stamp on last-added block when key matches
	restore_stamp :: proc(s: ^App_State, prev: map[string]i64) {
		if len(s.blocks) == 0 {
			return
		}
		i := len(s.blocks) - 1
		b := &s.blocks[i]
		k := block_stamp_key(b.kind, b.text, b.tool_name, context.temp_allocator)
		if t, ok := prev[k]; ok {
			b.time_unix = t
		}
	}

	for m in msgs {
		switch m.role {
		case .System:
			continue
		case .User:
			if m.content != "" {
				state_add_block(s, .User, m.content)
				restore_stamp(s, prev_stamp)
			}
		case .Assistant:
			if m.content != "" {
				state_add_block(s, .Assistant, m.content)
				restore_stamp(s, prev_stamp)
			}
			for tc in m.tool_calls {
				pending[tc.id] = Pending_Tool {
					name = tc.name,
					args = tc.arguments,
				}
			}
		case .Tool:
			name := "tool"
			args := ""
			if p, ok := pending[m.tool_call_id]; ok {
				name = p.name if p.name != "" else "tool"
				args = p.args
				delete_key(&pending, m.tool_call_id)
			}
			body: string
			if args != "" && m.content != "" {
				body = fmt.tprintf("args: %s\n---\n%s", args, m.content)
			} else if m.content != "" {
				body = m.content
			} else if args != "" {
				body = fmt.tprintf("args: %s", args)
			} else {
				body = "(empty)"
			}
			// Preserve user expand choice; default-expand tool failures.
			exp: bool
			if name in prev_expand {
				exp = prev_expand[name]
			} else {
				exp = agent.tool_result_is_error(m.content)
			}
			state_add_block(s, .Tool, body, name, exp)
			restore_stamp(s, prev_stamp)
		}
	}
	for id, p in pending {
		_ = id
		body := p.args if p.args != "" else "(pending)"
		nm := p.name if p.name != "" else "tool"
		exp := prev_expand[nm] if nm in prev_expand else false
		state_add_block(s, .Tool, body, nm, exp)
		restore_stamp(s, prev_stamp)
	}
}
