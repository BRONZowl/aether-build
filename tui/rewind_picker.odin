// Package tui — /rewind interactive user-turn picker (Wave 1).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"

// Rewind_Picker: list of user turns (newest first); Enter rewinds that many turns.
Rewind_Picker :: struct {
	active:   bool,
	// labels + how many user turns to drop if selected (1 = last user turn only)
	labels:   [dynamic]string, // owned
	depths:   [dynamic]int,    // parallel to labels
	selected: int,
	scroll:   int,
}

rewind_picker_init :: proc(p: ^Rewind_Picker) {
	p.labels = make([dynamic]string, 0, 16)
	p.depths = make([dynamic]int, 0, 16)
	p.selected = 0
	p.scroll = 0
	p.active = false
}

rewind_picker_destroy :: proc(p: ^Rewind_Picker) {
	rewind_picker_clear(p)
	delete(p.labels)
	delete(p.depths)
	p.active = false
}

rewind_picker_clear :: proc(p: ^Rewind_Picker) {
	for l in p.labels {
		delete(l)
	}
	clear(&p.labels)
	clear(&p.depths)
	p.selected = 0
	p.scroll = 0
}

// rewind_picker_open builds newest-first user turn list from session.
rewind_picker_open :: proc(p: ^Rewind_Picker, sess: ^agent.Session) {
	rewind_picker_clear(p)
	if sess == nil {
		p.active = true
		return
	}
	// depth from newest: first user from end = depth 1
	depth := 0
	for i := len(sess.msgs) - 1; i >= 0; i -= 1 {
		m := sess.msgs[i]
		if m.role != .User {
			continue
		}
		depth += 1
		t := strings.trim_space(m.content)
		if t == "" {
			t = "(empty user turn)"
		}
		if len(t) > 80 {
			t = fmt.tprintf("%s…", t[:77])
		}
		t, _ = strings.replace_all(t, "\n", " ", context.temp_allocator)
		append(&p.labels, strings.clone(fmt.tprintf("#%d  %s", depth, t)))
		append(&p.depths, depth)
	}
	p.selected = 0
	p.scroll = 0
	p.active = true
}

rewind_picker_close :: proc(p: ^Rewind_Picker) {
	p.active = false
}

rewind_picker_move :: proc(p: ^Rewind_Picker, delta: int) {
	if len(p.labels) == 0 {
		return
	}
	p.selected += delta
	if p.selected < 0 {
		p.selected = 0
	}
	if p.selected >= len(p.labels) {
		p.selected = len(p.labels) - 1
	}
}

// rewind_picker_selected_depth: user turns to drop, or 0 if none.
rewind_picker_selected_depth :: proc(p: ^Rewind_Picker) -> int {
	if !p.active || len(p.depths) == 0 {
		return 0
	}
	if p.selected < 0 || p.selected >= len(p.depths) {
		return 0
	}
	return p.depths[p.selected]
}

handle_rewind_picker_key :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	key: Key,
) -> bool {
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		rewind_picker_close(&st.rewind_picker)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		rewind_picker_move(&st.rewind_picker, -1)
		return true
	case .Down, .Ctrl_J:
		rewind_picker_move(&st.rewind_picker, 1)
		return true
	case .PgUp:
		rewind_picker_move(&st.rewind_picker, -max(1, term.rows / 2))
		return true
	case .PgDn:
		rewind_picker_move(&st.rewind_picker, max(1, term.rows / 2))
		return true
	case .Enter:
		n := rewind_picker_selected_depth(&st.rewind_picker)
		rewind_picker_close(&st.rewind_picker)
		if n <= 0 {
			state_set_status(st, "no turn to rewind")
			return true
		}
		before := len(sess.msgs)
		removed, rerr := agent.conversation_rewind_turns(sess, n)
		if rerr != "" {
			state_set_status(st, rerr)
			state_add_notice(st, fmt.tprintf("aether: %s", rerr))
			return true
		}
		if sess.auto_save {
			if e := agent.session_save(sess); e != "" {
				state_add_notice(st, fmt.tprintf("autosave failed: %s", e))
			}
		}
		rebuild_blocks(st, sess.msgs[:])
		seed_prompt_history(st, sess.msgs[:])
		stream_pin_bottom(st)
		state_set_status(st, fmt.tprintf("rewound %d turn(s)", removed))
		state_add_notice(
			st,
			fmt.tprintf("aether: rewound %d user turn(s) (%d→%d messages)", removed, before, len(sess.msgs)),
		)
		return true
	}
	return false
}
