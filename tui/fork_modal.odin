// Package tui — /fork worktree question (Grok-shaped).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"
import "aether:core"

// Fork_Modal: ask worktree yes/no before forking.
Fork_Modal :: struct {
	active: bool,
	// remaining free text after /fork (title/directive); owned
	rest:   string,
	// highlight: 0 = worktree, 1 = same workspace
	sel:    int,
}

fork_modal_init :: proc(m: ^Fork_Modal) {
	m.active = false
	m.rest = ""
	m.sel = 0
}

fork_modal_destroy :: proc(m: ^Fork_Modal) {
	delete(m.rest)
	m.rest = ""
	m.active = false
}

// fork_modal_open: rest is title/directive after /fork (no flags).
fork_modal_open :: proc(m: ^Fork_Modal, rest: string) {
	delete(m.rest)
	m.rest = strings.clone(strings.trim_space(rest))
	m.sel = 0
	m.active = true
}

fork_modal_close :: proc(m: ^Fork_Modal) {
	m.active = false
}

// fork_modal_build_line: reconstruct slash for agent after choice.
fork_modal_build_line :: proc(m: ^Fork_Modal, worktree: bool, allocator := context.allocator) -> string {
	flag := "--worktree" if worktree else "--no-worktree"
	if m.rest == "" {
		return strings.clone(fmt.tprintf("/fork %s", flag), allocator)
	}
	return strings.clone(fmt.tprintf("/fork %s %s", flag, m.rest), allocator)
}

handle_fork_modal_key :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	key: Key,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	m := &st.fork_modal
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		fork_modal_close(m)
		state_set_status(st, "fork cancelled")
		return true
	case .Up, .Ctrl_K:
		m.sel = 0
		return true
	case .Down, .Ctrl_J:
		m.sel = 1
		return true
	case .Char:
		if key.ch == '1' || key.ch == 'w' || key.ch == 'W' {
			return fork_modal_confirm(st, sess, term, model, cwd, perm, perm_before, opts, true)
		}
		if key.ch == '2' || key.ch == 's' || key.ch == 'S' {
			return fork_modal_confirm(st, sess, term, model, cwd, perm, perm_before, opts, false)
		}
	case .Enter:
		return fork_modal_confirm(
			st,
			sess,
			term,
			model,
			cwd,
			perm,
			perm_before,
			opts,
			m.sel == 0,
		)
	}
	return false
}

fork_modal_confirm :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
	worktree: bool,
) -> bool {
	m := &st.fork_modal
	line := fork_modal_build_line(m, worktree, context.allocator)
	fork_modal_close(m)
	stream_bind_slash(st)
	defer stream_clear_slash()
	slash_out :: proc(msg: string) {
		stream_notice_slash(msg)
	}
	action := agent.run_slash(sess, line, opts, model, cwd, perm, slash_out)
	delete(line)
	delete(st.perm)
	st.perm = strings.clone(core.permission_mode_string(perm^))
	if action == .Session_Changed {
		delete(st.model)
		st.model = strings.clone(model^)
		state_set_cwd(st, cwd^)
		state_set_session_meta(st, sess.id, sess.title)
		rebuild_blocks(st, sess.msgs[:])
		seed_prompt_history(st, sess.msgs[:])
		stream_pin_bottom(st)
		if dir := agent.take_fork_pending_composer(); dir != "" {
			input_set_text(st, dir)
			delete(dir)
			focus_prompt(st)
		}
		state_set_status(st, "forked")
	} else if action == .Exit {
		st.quit = true
	}
	_ = term
	_ = perm_before
	return true
}

write_fork_modal_body :: proc(b: ^strings.Builder, m: ^Fork_Modal, cols: int, body_h: int) {
	write_row(b, " fork session", cols, .Bar_Reverse, true)
	painted := 1
	if m.rest != "" {
		snip := m.rest
		if len(snip) > cols - 14 {
			snip = fmt.tprintf("%s…", snip[:max(1, cols - 17)])
		}
		write_row(b, fmt.tprintf("  directive: %s", snip), cols, .Bar_Dim, true)
		painted += 1
	} else {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(b, "  Branch this conversation into a peer session.", cols, .Normal, true)
	painted += 1
	write_row(b, "", cols, .Normal, true)
	painted += 1

	opt0 := "New git worktree (isolated cwd)"
	opt1 := "Same workspace"
	for i in 0 ..< 2 {
		label := opt0 if i == 0 else opt1
		sel := m.sel == i
		line: string
		if sel {
			line = fmt.tprintf("› [%d] %s", i + 1, label)
		} else {
			line = fmt.tprintf("  [%d] %s", i + 1, label)
		}
		write_row(b, line, cols, .Bar_Reverse if sel else .Normal, true)
		painted += 1
	}
	write_row(b, "", cols, .Normal, true)
	painted += 1
	write_row(b, "  Enter confirm · Esc cancel · 1/2 or w/s", cols, .Bar_Dim, true)
	painted += 1
	for painted < body_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
}
