// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

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

// New/load session UI helpers.

// tui_new_session creates a fresh session (same as /new) and refreshes UI.
tui_new_session :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	model: ^string,
	cwd: ^string,
	perm: core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	stream_bind_slash(st)
	defer stream_clear_slash()
	slash_out :: proc(msg: string) {
		stream_notice_slash(msg)
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
