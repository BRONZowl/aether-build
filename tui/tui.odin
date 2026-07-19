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

// Cooperative cancel + live permission, visible to stream/status/HTTP poll callbacks.
@(private)
g_cancel: bool
@(private)
g_perm: ^core.Permission_Mode
@(private)
g_perm_before: ^core.Permission_Mode

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

		// When auto-wake may fire, use a short timed wait so we re-check without a key
		key: Key
		if tui_can_auto_wake(&st) && agent.auto_wake_enabled() {
			b, ok := read_byte_timeout(5) // 500ms
			if !ok {
				continue
			}
			one := [1]u8{b}
			push_bytes(one[:])
			key = read_key()
		} else {
			key = read_key()
		}
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

// apply_middle_paste: PRIMARY/clipboard text + image path/clipboard image → prompt (C2.5 / M1).
apply_middle_paste :: proc(st: ^App_State) -> bool {
	return apply_paste(st, false)
}

// apply_bracketed_paste: terminal ESC[200~…201~ payload (C2.6).
// Focuses prompt; rewrites image paths to [Image #N]; bulk-inserts (no per-char Esc).
apply_bracketed_paste :: proc(st: ^App_State, raw: string) -> bool {
	if st.focus != .Prompt {
		focus_prompt(st)
	}
	if raw == "" {
		return false
	}
	rewritten, n_att := agent.process_paste_for_images(raw, context.temp_allocator)
	insert := rewritten if rewritten != "" else raw
	if input_insert_text(st, insert) {
		st.history_idx = -1
		if n_att > 0 {
			state_set_status(st, fmt.tprintf("pasted %d image(s)", n_att))
		} else {
			// short status: rune count approx
			n := 0
			for _ in insert {
				n += 1
				if n > 9999 {
					break
				}
			}
			state_set_status(st, fmt.tprintf("pasted %d chars", n))
		}
		return true
	}
	return false
}

// try_paste_clipboard_image attaches binary clipboard image as [Image #N].
try_paste_clipboard_image :: proc(st: ^App_State) -> bool {
	data, ok := paste_clipboard_image_bytes(context.temp_allocator)
	if !ok {
		return false
	}
	label, aok := agent.save_clipboard_image_bytes(data, context.temp_allocator)
	if !aok {
		return false
	}
	if input_insert_text(st, fmt.tprintf("%s ", label)) {
		st.history_idx = -1
		state_set_status(st, "pasted image")
		return true
	}
	return false
}

// apply_paste: multimodal-aware paste (M1).
// prefer_image=true (Ctrl+V): try clipboard image bytes first, then text.
// prefer_image=false (middle): text first (PRIMARY), then clipboard image if empty.
apply_paste :: proc(st: ^App_State, prefer_image: bool) -> bool {
	if st.focus != .Prompt {
		focus_prompt(st)
	}
	if prefer_image {
		if try_paste_clipboard_image(st) {
			return true
		}
	}
	text, ok := paste_from_primary(context.temp_allocator)
	if ok && text != "" {
		rewritten, n_att := agent.process_paste_for_images(text, context.temp_allocator)
		insert := rewritten if rewritten != "" else text
		if input_insert_text(st, insert) {
			st.history_idx = -1
			if n_att > 0 {
				state_set_status(st, fmt.tprintf("pasted %d image(s)", n_att))
			} else {
				state_set_status(st, "pasted")
			}
			return true
		}
	}
	if !prefer_image {
		if try_paste_clipboard_image(st) {
			return true
		}
	}
	state_set_status(st, "paste: empty / no selection")
	return true
}

// apply_mouse_click handles left-click: select scrollback block or focus prompt (C2.3).
// Returns true if UI state changed.
apply_mouse_click :: proc(st: ^App_State, term: ^Term_State, mx, my: int) -> bool {
	_ = mx // column unused for now (full-line hit)
	rows := max(6, term.rows)
	cols := max(20, term.cols)
	input_h := input_line_count(st, cols)
	body_h := rows - 2 - input_h
	if body_h < 1 {
		body_h = 1
	}
	zone := hit_test_click_zone(my, rows, body_h, input_h)
	switch zone {
	case .Input:
		if st.focus != .Prompt {
			focus_prompt(st)
			return true
		}
		return false
	case .Header, .Status, .Outside:
		return false
	case .Body:
		// Recompute flatten map (same as render)
		lines := make([dynamic]string, 0, 128, context.temp_allocator)
		styles := make([dynamic]Line_Style, 0, 128, context.temp_allocator)
		block_idxs := make([dynamic]int, 0, 128, context.temp_allocator)
		flatten_blocks(st, cols, &lines, &styles, &block_idxs, context.temp_allocator, rows)
		total := len(lines)
		max_scroll := max(0, total - body_h)
		scroll := st.scroll
		if scroll > max_scroll {
			scroll = max_scroll
		}
		start := max(0, total - body_h - scroll)
		line_i := body_line_index(my, body_h, start, total)
		changed := false
		if st.focus != .Scrollback {
			focus_scrollback(st)
			changed = true
		}
		if line_i >= 0 && line_i < len(block_idxs) {
			bi := block_idxs[line_i]
			if bi >= 0 && bi < len(st.blocks) {
				if st.selected_block != bi {
					st.selected_block = bi
					changed = true
				}
			}
		}
		return changed
	}
	return false
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

// toggle_yolo flips Always_Approve vs previous mode (Grok Ctrl+O).
toggle_yolo :: proc(
	st: ^App_State,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
) {
	if perm^ == .Always_Approve {
		// Leaving yolo: drop plan if still active, restore prior perm
		if agent.plan_mode_is_active() || agent.plan_mode_is_pending() || agent.plan_mode_is_exit_pending() {
			_ = agent.user_exit_plan_mode(".", st.streaming, context.temp_allocator)
		}
		perm^ = perm_before^
		delete(st.perm)
		st.perm = strings.clone(core.permission_mode_string(perm^))
		_ = core.persist_permission_mode(perm^)
		state_set_status(st, fmt.tprintf("yolo off (%s)", st.perm))
	} else {
		// Entering yolo: leave plan mode (Always-Approve is full agent)
		if agent.plan_mode_is_active() || agent.plan_mode_is_pending() || agent.plan_mode_is_exit_pending() {
			_ = agent.user_exit_plan_mode(".", st.streaming, context.temp_allocator)
		}
		if perm^ != .Always_Approve {
			perm_before^ = perm^
		}
		perm^ = .Always_Approve
		delete(st.perm)
		st.perm = strings.clone(core.permission_mode_string(perm^))
		_ = core.persist_permission_mode(perm^)
		state_set_status(st, "yolo on")
	}
}

// cycle_mode: Grok-shaped Shift+Tab ring.
// With plan mode: ask → plan → auto → always-approve → read-only → ask.
// With AETHER_NO_PLAN_MODE: ask → auto → always-approve → read-only → ask.
cycle_mode :: proc(
	st: ^App_State,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	cwd: string,
) {
	sync_sess_plan :: proc() {
		if g_sess != nil {
			g_sess.plan_mode =
				agent.plan_mode_is_active() ||
				agent.plan_mode_is_pending() ||
				agent.plan_mode_is_exit_pending()
		}
	}
	apply_perm :: proc(
		st: ^App_State,
		perm: ^core.Permission_Mode,
		perm_before: ^core.Permission_Mode,
		m: core.Permission_Mode,
	) {
		perm^ = m
		if m != .Always_Approve {
			perm_before^ = m
		}
		delete(st.perm)
		st.perm = strings.clone(core.permission_mode_string(perm^))
		_ = core.persist_permission_mode(perm^)
		state_set_status(st, fmt.tprintf("mode: %s", st.perm))
	}
	if agent.plan_mode_enabled() {
		// plan Active/Pending/Exit_Pending → auto (leave plan into accept-edits)
		if agent.plan_mode_is_active() ||
		   agent.plan_mode_is_pending() ||
		   agent.plan_mode_is_exit_pending() {
			_ = agent.user_exit_plan_mode(cwd, st.streaming, context.temp_allocator)
			sync_sess_plan()
			apply_perm(st, perm, perm_before, .Auto)
			return
		}
		// Not in plan: ask → plan; auto → always; always → ro; ro → ask
		switch perm^ {
		case .Ask:
			_ = agent.user_enter_plan_mode(cwd, "", context.temp_allocator)
			sync_sess_plan()
			// Keep underlying permission as ask; header shows plan chip via agent state
			perm_before^ = .Ask
			delete(st.perm)
			st.perm = strings.clone(core.permission_mode_string(perm^))
			state_set_status(st, "mode: plan")
			return
		case .Auto:
			apply_perm(st, perm, perm_before, .Always_Approve)
			return
		case .Always_Approve:
			apply_perm(st, perm, perm_before, .Read_Only)
			return
		case .Read_Only:
			apply_perm(st, perm, perm_before, .Ask)
			return
		}
	}
	// Plan mode disabled: permission-only cycle (includes auto)
	perm^ = core.next_permission_mode(perm^)
	if perm^ != .Always_Approve {
		perm_before^ = perm^
	}
	delete(st.perm)
	st.perm = strings.clone(core.permission_mode_string(perm^))
	_ = core.persist_permission_mode(perm^)
	state_set_status(st, fmt.tprintf("mode: %s", st.perm))
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

g_slash_state:  ^App_State
g_stream_state: ^App_State
g_stream_term:  ^Term_State
g_status_state: ^App_State
g_status_term:  ^Term_State
g_sess:         ^agent.Session

// tui_modal_yn shows ask modal with name/summary; returns true on y/Enter.
// (Still used by plan-exit and callers that only need binary choice.)
tui_modal_yn :: proc(title, name, summary: string) -> bool {
	dec := tui_modal_ask(title, name, summary, allow_always = false)
	return dec == .Once || dec == .Always
}

// tui_modal_ask: Deny / Once / Always / Never session. Keys a/d when grants enabled.
tui_modal_ask :: proc(
	title, name, summary: string,
	allow_always := true,
) -> core.Ask_Decision {
	st := g_stream_state
	term := g_stream_term
	if st == nil || term == nil {
		return .Deny
	}
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = strings.clone(name)
	st.ask_summary = strings.clone(summary)
	st.ask_active = true
	state_set_status(st, title)
	render(term, st)

	dec: core.Ask_Decision = .Deny
	grants := allow_always && core.session_allow_enabled()
	for {
		key := read_key()
		#partial switch key.kind {
		case .Char:
			if key.ch == 'y' || key.ch == 'Y' {
				dec = .Once
				break
			}
			if key.ch == 'n' || key.ch == 'N' {
				dec = .Deny
				break
			}
			if grants && (key.ch == 'a' || key.ch == 'A') {
				dec = .Always
				break
			}
			if grants && (key.ch == 'd' || key.ch == 'D') {
				dec = .Never
				break
			}
			continue
		case .Enter:
			dec = .Once
			break
		case .Esc, .Ctrl_C:
			dec = .Deny
			break
		case:
			continue
		}
		break
	}

	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""
	return dec
}

// tui_ask_user_clear_modal tears down the mid-turn ask overlay.
tui_ask_user_clear_modal :: proc(st: ^App_State) {
	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""
}

// tui_ask_user_set_choice_summary paints option list for digit selection.
// Shows description and optional preview (Grok option.preview).
tui_ask_user_set_choice_summary :: proc(st: ^App_State, q: agent.Ask_Question) {
	b := strings.builder_make(context.temp_allocator)
	for o, i in q.options {
		fmt.sbprintf(&b, "%d) %s\n", i + 1, o.label)
		if o.description != "" {
			fmt.sbprintf(&b, "   %s\n", o.description)
		}
		if o.preview != "" {
			// indent multi-line previews
			prev := o.preview
			for len(prev) > 0 {
				nl := strings.index_byte(prev, '\n')
				line: string
				if nl >= 0 {
					line = prev[:nl]
					prev = prev[nl + 1:]
				} else {
					line = prev
					prev = ""
				}
				if line != "" {
					fmt.sbprintf(&b, "   │ %s\n", line)
				}
			}
		}
	}
	strings.write_string(&b, "1-9 select · Esc cancel")
	delete(st.ask_summary)
	st.ask_summary = strings.clone(strings.to_string(b))
}

// tui_ask_user_set_multi_summary paints multi-select with [x]/[ ] markers.
tui_ask_user_set_multi_summary :: proc(st: ^App_State, q: agent.Ask_Question, selected: []bool) {
	b := strings.builder_make(context.temp_allocator)
	for o, i in q.options {
		mark := "[ ]"
		if i < len(selected) && selected[i] {
			mark = "[x]"
		}
		fmt.sbprintf(&b, "%s %d) %s\n", mark, i + 1, o.label)
		if o.description != "" {
			fmt.sbprintf(&b, "   %s\n", o.description)
		}
		if o.preview != "" {
			prev := o.preview
			for len(prev) > 0 {
				nl := strings.index_byte(prev, '\n')
				line: string
				if nl >= 0 {
					line = prev[:nl]
					prev = prev[nl + 1:]
				} else {
					line = prev
					prev = ""
				}
				if line != "" {
					fmt.sbprintf(&b, "   │ %s\n", line)
				}
			}
		}
	}
	strings.write_string(&b, "digit toggle · Enter submit · Esc cancel")
	delete(st.ask_summary)
	st.ask_summary = strings.clone(strings.to_string(b))
}

// tui_ask_user_set_freeform_summary paints live Other freeform draft.
tui_ask_user_set_freeform_summary :: proc(st: ^App_State, draft: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Other> %s_\n", draft)
	strings.write_string(&b, "Enter submit · Esc = Other · Ctrl+C cancel")
	delete(st.ask_summary)
	st.ask_summary = strings.clone(strings.to_string(b))
}

// tui_ask_user_freeform: after Other pick — type free text (Grok Path A).
// Returns (answer, cancelled). Esc/empty → "Other"; Ctrl+C → cancel all.
tui_ask_user_freeform :: proc(st: ^App_State, term: ^Term_State) -> (answer: string, cancelled: bool) {
	draft := make([dynamic]u8, 0, 64, context.temp_allocator)
	tui_ask_user_set_freeform_summary(st, "")
	state_set_status(st, "type freeform · Enter submit · Esc = Other")
	render(term, st)
	for {
		key := read_key()
		#partial switch key.kind {
		case .Enter:
			return agent.other_answer_from_draft(string(draft[:])), false
		case .Esc:
			return "Other", false
		case .Ctrl_C:
			return "", true
		case .Backspace:
			if len(draft) > 0 {
				_, size := utf8.decode_last_rune(draft[:])
				if size <= 0 {
					size = 1
				}
				resize(&draft, len(draft) - size)
			}
		case .Char:
			if key.ch >= 32 {
				buf, n := utf8.encode_rune(key.ch)
				for i in 0 ..< n {
					append(&draft, buf[i])
				}
			}
		case:
			continue
		}
		tui_ask_user_set_freeform_summary(st, string(draft[:]))
		state_set_status(st, "type freeform · Enter submit · Esc = Other")
		render(term, st)
	}
}

// tui_ask_user_multi: multi_select loop — digit toggles, Enter submits.
// Returns (answer, cancelled). Empty selection + Enter → cancel.
tui_ask_user_multi :: proc(
	st: ^App_State,
	term: ^Term_State,
	q: agent.Ask_Question,
) -> (
	answer: string,
	cancelled: bool,
) {
	selected := make([]bool, len(q.options), context.temp_allocator)
	tui_ask_user_set_multi_summary(st, q, selected)
	state_set_status(st, "multi-select · digit toggle · Enter submit")
	render(term, st)
	for {
		key := read_key()
		#partial switch key.kind {
		case .Enter:
			ans := agent.join_selected_labels(q.options[:], selected, context.temp_allocator)
			if ans == "" {
				return "", true
			}
			return ans, false
		case .Esc, .Ctrl_C:
			return "", true
		case .Char:
			if key.ch >= '1' && key.ch <= '9' {
				idx := int(key.ch - '1')
				if idx < len(selected) {
					selected[idx] = !selected[idx]
					tui_ask_user_set_multi_summary(st, q, selected)
					state_set_status(st, "multi-select · digit toggle · Enter submit")
					render(term, st)
				}
			}
		case:
			continue
		}
	}
}

// tui_ask_user_question: number-key multi-choice for ask_user_question tool.
// Esc cancels (Grok Path D). Digits 1-9 select (or toggle if multi_select); Other opens freeform.
tui_ask_user_question :: proc(arguments_json: string) -> string {
	qs, err := agent.parse_ask_questions(arguments_json, context.allocator)
	defer agent.free_ask_questions(&qs)
	if err != "" {
		return fmt.tprintf("error: %s", err)
	}
	st := g_stream_state
	term := g_stream_term
	if st == nil || term == nil {
		return agent.ASK_USER_CANCEL_TEXT
	}
	pairs := make([dynamic]string, 0, len(qs) * 2, context.temp_allocator)
	for q in qs {
		delete(st.ask_name)
		st.ask_name = strings.clone(q.question)
		st.ask_active = true

		chosen := ""
		if q.multi_select {
			ans, cancelled := tui_ask_user_multi(st, term, q)
			if cancelled {
				tui_ask_user_clear_modal(st)
				return agent.ASK_USER_CANCEL_TEXT
			}
			chosen = ans
		} else {
			tui_ask_user_set_choice_summary(st, q)
			state_set_status(st, "answer question · digit select · Esc cancel")
			render(term, st)
			for {
				key := read_key()
				#partial switch key.kind {
				case .Char:
					if key.ch >= '1' && key.ch <= '9' {
						idx := int(key.ch - '1')
						if idx < len(q.options) {
							chosen = q.options[idx].label
							break
						}
					}
					continue
				case .Esc, .Ctrl_C:
					tui_ask_user_clear_modal(st)
					return agent.ASK_USER_CANCEL_TEXT
				case:
					continue
				}
			}
			if chosen == "" {
				tui_ask_user_clear_modal(st)
				return agent.ASK_USER_CANCEL_TEXT
			}
		}
		// Other alone → freeform sub-mode (stdin parity; multi "A, Other" stays literal)
		if agent.is_other_option(chosen) {
			ans, cancelled := tui_ask_user_freeform(st, term)
			if cancelled {
				tui_ask_user_clear_modal(st)
				return agent.ASK_USER_CANCEL_TEXT
			}
			chosen = ans
		}
		tui_ask_user_clear_modal(st)
		append(&pairs, q.question)
		append(&pairs, chosen)
	}
	state_set_status(st, "questions answered")
	return agent.format_accepted_answers(pairs[:], context.allocator)
}

// tui_ask_tool is the Turn_Options.on_ask handler (nested key loop on alt-screen).
// y/Enter = once, n/Esc = deny, a = always, d = never (Grok AllowAlways / RejectAlways).
tui_ask_tool :: proc(name, summary: string) -> core.Ask_Decision {
	title := fmt.tprintf("approve %s? y/n/a/d", name)
	if !core.session_allow_enabled() {
		title = fmt.tprintf("approve %s? y/n", name)
	}
	dec := tui_modal_ask(title, name, summary, allow_always = true)
	st := g_stream_state
	term := g_stream_term
	if st != nil {
		switch dec {
		case .Once:
			state_set_status(st, fmt.tprintf("allowed %s", name))
		case .Always:
			state_set_status(st, fmt.tprintf("always allow (session) %s", name))
		case .Never:
			state_set_status(st, fmt.tprintf("never allow (session) %s", name))
		case .Deny:
			state_set_status(st, fmt.tprintf("denied %s", name))
		}
		if term != nil {
			render(term, st)
		}
	}
	return dec
}

// tui_plan_enter_ask: approve model enter_plan_mode tool.
tui_plan_enter_ask :: proc() -> bool {
	ok := tui_modal_yn("enter plan mode? y/n", "enter_plan_mode", "explore first; only .grok/plan.md writable")
	st := g_stream_state
	term := g_stream_term
	if st != nil {
		if ok {
			state_set_status(st, "plan mode enter approved")
		} else {
			state_set_status(st, "plan mode enter declined")
		}
		if term != nil {
			render(term, st)
		}
	}
	return ok
}

// tui_plan_exit_ask: y approve / n revise / a abandon (Grok plan approval outcomes).
tui_plan_exit_ask :: proc(plan_path, plan_preview: string) -> agent.Plan_Exit_Result {
	sum := plan_preview
	if sum == "" {
		sum = "(empty plan file)"
	}
	st := g_stream_state
	term := g_stream_term
	res := agent.Plan_Exit_Result {
		outcome = .Cancelled,
	}
	if st == nil || term == nil {
		// headless fallback inside TUI package — should not happen mid-stream
		return agent.default_plan_exit_ask(plan_path, plan_preview)
	}
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = strings.clone("exit_plan_mode")
	st.ask_summary = strings.clone(sum)
	st.ask_active = true
	state_set_status(st, "exit plan? y=approve n=revise a=abandon")
	render(term, st)

	for {
		key := read_key()
		#partial switch key.kind {
		case .Char:
			if key.ch == 'y' || key.ch == 'Y' {
				res.outcome = .Approved
				break
			}
			if key.ch == 'a' || key.ch == 'A' {
				res.outcome = .Abandoned
				break
			}
			if key.ch == 'n' || key.ch == 'N' {
				// optional freeform feedback
				res.outcome = .Cancelled
				fb, cancelled := tui_ask_user_freeform(st, term)
				if !cancelled && strings.trim_space(fb) != "" {
					// Plan_Exit_Result.feedback is not owned long-term; clone into temp
					// for exit_plan_mode_impl which only reads during the call.
					res.feedback = fb
				} else {
					delete(fb)
				}
				break
			}
			continue
		case .Enter:
			res.outcome = .Approved
			break
		case .Esc, .Ctrl_C:
			res.outcome = .Cancelled
			break
		case:
			continue
		}
		break
	}

	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""

	switch res.outcome {
	case .Approved:
		state_set_status(st, "plan exit approved")
		if g_sess != nil {
			g_sess.plan_mode = false
		}
	case .Abandoned:
		state_set_status(st, "plan abandoned")
		if g_sess != nil {
			g_sess.plan_mode = false
		}
	case .Cancelled:
		state_set_status(st, "plan revise — still planning")
	}
	if term != nil {
		render(term, st)
	}
	return res
}

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

// peek_is_shift_tab recognizes common Shift+Tab CSI sequences in a raw buffer.
peek_is_shift_tab :: proc(buf: []u8) -> bool {
	// ESC [ Z
	if len(buf) >= 3 && buf[0] == 0x1b && buf[1] == '[' && buf[len(buf) - 1] == 'Z' {
		return true
	}
	// Kitty / CSI-u Tab with shift: ESC [ 9 ; 2 u  (optional future)
	// Also bare Z after partial — only accept full CSI starting with ESC
	if len(buf) >= 3 && buf[0] == 0x1b {
		// any ESC [ ... Z
		if buf[1] == '[' {
			for i in 2 ..< len(buf) {
				if buf[i] == 'Z' {
					return true
				}
			}
		}
	}
	return false
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
