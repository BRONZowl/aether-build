// Package tui — /help command palette (searchable slash list).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:core"

// Command_Palette: filterable list of catalog primaries.
Command_Palette :: struct {
	active:   bool,
	// all entries as "name\tdesc"
	names:    [dynamic]string, // owned primaries
	descs:    [dynamic]string, // owned
	visible:  [dynamic]int,
	selected: int,
	scroll:   int,
	filter:   [dynamic]u8,
}

command_palette_init :: proc(p: ^Command_Palette) {
	p.names = make([dynamic]string, 0, 64)
	p.descs = make([dynamic]string, 0, 64)
	p.visible = make([dynamic]int, 0, 64)
	p.filter = make([dynamic]u8, 0, 32)
	p.selected = 0
	p.scroll = 0
	p.active = false
}

command_palette_destroy :: proc(p: ^Command_Palette) {
	command_palette_clear(p)
	delete(p.names)
	delete(p.descs)
	delete(p.visible)
	delete(p.filter)
	p.active = false
}

command_palette_clear :: proc(p: ^Command_Palette) {
	for n in p.names {
		delete(n)
	}
	for d in p.descs {
		delete(d)
	}
	clear(&p.names)
	clear(&p.descs)
	clear(&p.visible)
	clear(&p.filter)
	p.selected = 0
	p.scroll = 0
}

command_palette_open :: proc(p: ^Command_Palette) {
	command_palette_clear(p)
	for e in core.SLASH_CATALOG {
		if e.primary == "" {
			continue
		}
		append(&p.names, strings.clone(e.primary))
		append(&p.descs, strings.clone(core.slash_entry_desc(e)))
	}
	command_palette_refilter(p)
	p.active = true
}

command_palette_close :: proc(p: ^Command_Palette) {
	p.active = false
}

command_palette_refilter :: proc(p: ^Command_Palette) {
	clear(&p.visible)
	q := strings.to_lower(string(p.filter[:]), context.temp_allocator)
	for i in 0 ..< len(p.names) {
		if q == "" {
			append(&p.visible, i)
			continue
		}
		nl := strings.to_lower(p.names[i], context.temp_allocator)
		dl := strings.to_lower(p.descs[i], context.temp_allocator)
		if strings.contains(nl, q) || strings.contains(dl, q) {
			append(&p.visible, i)
		}
	}
	if p.selected >= len(p.visible) {
		p.selected = max(0, len(p.visible) - 1)
	}
	if p.selected < 0 {
		p.selected = 0
	}
	p.scroll = 0
}

command_palette_move :: proc(p: ^Command_Palette, delta: int) {
	if len(p.visible) == 0 {
		return
	}
	p.selected += delta
	if p.selected < 0 {
		p.selected = 0
	}
	if p.selected >= len(p.visible) {
		p.selected = len(p.visible) - 1
	}
}

command_palette_selected_name :: proc(p: ^Command_Palette) -> string {
	if len(p.visible) == 0 {
		return ""
	}
	if p.selected < 0 || p.selected >= len(p.visible) {
		return ""
	}
	return p.names[p.visible[p.selected]]
}

handle_command_palette_key :: proc(st: ^App_State, key: Key) -> bool {
	p := &st.command_palette
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		command_palette_close(p)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		command_palette_move(p, -1)
		return true
	case .Down, .Ctrl_J:
		command_palette_move(p, 1)
		return true
	case .PgUp:
		command_palette_move(p, -10)
		return true
	case .PgDn:
		command_palette_move(p, 10)
		return true
	case .Enter:
		name := command_palette_selected_name(p)
		command_palette_close(p)
		if name != "" {
			// Insert into composer for user to complete/run
			input_set_text(st, fmt.tprintf("%s ", name))
			focus_prompt(st)
			state_set_status(st, fmt.tprintf("insert %s", name))
		}
		return true
	case .Backspace:
		if len(p.filter) > 0 {
			resize(&p.filter, len(p.filter) - 1)
			command_palette_refilter(p)
		}
		return true
	case .Char:
		if key.ch >= 32 && key.ch < 127 {
			append(&p.filter, u8(key.ch))
			command_palette_refilter(p)
			return true
		}
	}
	return false
}

write_command_palette_body :: proc(b: ^strings.Builder, p: ^Command_Palette, cols: int, body_h: int) {
	filt := string(p.filter[:])
	title := " commands"
	if filt != "" {
		title = fmt.tprintf(" commands  filter:%s", filt)
	}
	write_row(b, title, cols, .Bar_Reverse, true)
	list_h := body_h - 2
	if list_h < 1 {
		list_h = 1
	}
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if p.selected >= p.scroll + list_h {
		p.scroll = p.selected - list_h + 1
	}
	if p.scroll < 0 {
		p.scroll = 0
	}
	painted := 0
	if len(p.visible) == 0 {
		write_row(b, "  (no matches)", cols, .Bar_Dim, true)
		painted = 1
	} else {
		for vi := p.scroll; vi < len(p.visible) && painted < list_h; vi += 1 {
			ei := p.visible[vi]
			sel := vi == p.selected
			line := fmt.tprintf("%s %-18s %s", "›" if sel else " ", p.names[ei], p.descs[ei])
			if len(line) > cols - 1 {
				line = fmt.tprintf("%s…", line[:max(1, cols - 4)])
			}
			write_row(b, line, cols, .Bar_Reverse if sel else .Normal, true)
			painted += 1
		}
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(b, " Enter insert · type filter · Esc close", cols, .Bar_Dim, true)
}
