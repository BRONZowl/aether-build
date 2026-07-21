// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"
import "aether:core"

// Session + model picker key handlers.

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
