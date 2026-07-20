// Package tui — /settings modal shell (Wave 1; no billing).
// Browse-only list of effective settings; Enter toggles bools where supported.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:core"

// Settings_Modal: simple scrollable key/value list.
Settings_Modal :: struct {
	active:   bool,
	rows:     [dynamic]string, // owned "key · value" lines
	selected: int,
	scroll:   int,
}

settings_modal_init :: proc(m: ^Settings_Modal) {
	m.rows = make([dynamic]string, 0, 16)
	m.selected = 0
	m.scroll = 0
	m.active = false
}

settings_modal_destroy :: proc(m: ^Settings_Modal) {
	settings_modal_clear(m)
	delete(m.rows)
	m.active = false
}

settings_modal_clear :: proc(m: ^Settings_Modal) {
	for r in m.rows {
		delete(r)
	}
	clear(&m.rows)
	m.selected = 0
	m.scroll = 0
}

settings_modal_open :: proc(
	m: ^Settings_Modal,
	st: ^App_State,
	perm: core.Permission_Mode,
) {
	settings_modal_clear(m)
	add :: proc(m: ^Settings_Modal, line: string) {
		append(&m.rows, strings.clone(line))
	}
	add(m, fmt.tprintf("model · %s  (Enter → model picker)", st.model if st.model != "" else "(default)"))
	add(m, fmt.tprintf("permission · %s  (Enter cycles)", core.permission_mode_string(perm)))
	add(m, fmt.tprintf("theme · %s  (Enter cycles)", core.get_ui_theme_name()))
	add(m, fmt.tprintf("vim_mode · %s", "on" if core.vim_mode_enabled() else "off"))
	add(m, fmt.tprintf("compact_mode · %s", "on" if core.compact_mode_enabled() else "off"))
	add(m, fmt.tprintf("timestamps · %s", "on" if core.timestamps_enabled() else "off"))
	add(m, fmt.tprintf("multiline · %s", "on" if st.multiline_mode else "off"))
	add(
		m,
		fmt.tprintf(
			"privacy · %s  (Enter toggles)",
			"opt-in" if core.privacy_coding_data_share() else "opt-out",
		),
	)
	add(m, fmt.tprintf("cwd · %s", st.cwd if st.cwd != "" else "."))
	add(m, "— Enter edits selection · Esc close —")
	add(m, "(no billing — /usage is context-only by design)")
	m.selected = 0
	m.scroll = 0
	m.active = true
}

settings_modal_close :: proc(m: ^Settings_Modal) {
	m.active = false
}

settings_modal_move :: proc(m: ^Settings_Modal, delta: int) {
	if len(m.rows) == 0 {
		return
	}
	m.selected += delta
	if m.selected < 0 {
		m.selected = 0
	}
	if m.selected >= len(m.rows) {
		m.selected = len(m.rows) - 1
	}
}

// handle_settings_modal_key: navigate + toggle/cycle editable rows.
handle_settings_modal_key :: proc(
	st: ^App_State,
	perm: ^core.Permission_Mode,
	key: Key,
) -> bool {
	m := &st.settings_modal
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		settings_modal_close(m)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		settings_modal_move(m, -1)
		return true
	case .Down, .Ctrl_J:
		settings_modal_move(m, 1)
		return true
	case .Enter:
		if m.selected < 0 || m.selected >= len(m.rows) {
			return true
		}
		row := m.rows[m.selected]
		if strings.has_prefix(row, "model") {
			settings_modal_close(m)
			model_picker_open(&st.model_picker, st.model)
			state_set_status(st, "model picker")
			return true
		}
		if strings.has_prefix(row, "permission") && perm != nil {
			// cycle ask → auto → always-approve → read-only → ask
			switch perm^ {
			case .Ask:
				perm^ = .Auto
			case .Auto:
				perm^ = .Always_Approve
			case .Always_Approve:
				perm^ = .Read_Only
			case .Read_Only:
				perm^ = .Ask
			}
			_ = core.persist_permission_mode(perm^)
			delete(st.perm)
			st.perm = strings.clone(core.permission_mode_string(perm^))
			settings_modal_open(m, st, perm^)
			state_set_status(st, fmt.tprintf("permission %s", st.perm))
			return true
		}
		if strings.has_prefix(row, "theme") {
			next := core.cycle_ui_theme_name()
			_ = core.persist_ui_string("theme", next)
			settings_modal_open(m, st, perm^ if perm != nil else .Ask)
			state_set_status(st, fmt.tprintf("theme %s", next))
			return true
		}
		if strings.has_prefix(row, "vim_mode") {
			on := core.toggle_vim_mode()
			_ = core.persist_ui_bool("vim_mode", on)
			settings_modal_open(m, st, perm^ if perm != nil else .Ask)
			state_set_status(st, fmt.tprintf("vim_mode %s", "on" if on else "off"))
			return true
		}
		if strings.has_prefix(row, "compact_mode") {
			on := core.toggle_compact_mode()
			_ = core.persist_ui_bool("compact_mode", on)
			settings_modal_open(m, st, perm^ if perm != nil else .Ask)
			state_set_status(st, fmt.tprintf("compact_mode %s", "on" if on else "off"))
			return true
		}
		if strings.has_prefix(row, "timestamps") {
			on := core.toggle_timestamps()
			_ = core.persist_ui_bool("timestamps", on)
			settings_modal_open(m, st, perm^ if perm != nil else .Ask)
			state_set_status(st, fmt.tprintf("timestamps %s", "on" if on else "off"))
			return true
		}
		if strings.has_prefix(row, "multiline") {
			st.multiline_mode = !st.multiline_mode
			settings_modal_open(m, st, perm^ if perm != nil else .Ask)
			state_set_status(st, fmt.tprintf("multiline %s", "on" if st.multiline_mode else "off"))
			return true
		}
		if strings.has_prefix(row, "privacy") {
			on := !core.privacy_coding_data_share()
			_ = core.set_privacy_coding_data_share(on)
			settings_modal_open(m, st, perm^ if perm != nil else .Ask)
			state_set_status(st, "privacy opt-in" if on else "privacy opt-out")
			return true
		}
		state_set_status(st, "read-only row")
		return true
	}
	return false
}
