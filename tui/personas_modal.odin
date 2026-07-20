// Package tui — /personas and /config-agents manage list.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:agent"
import "aether:core"

Personas_Modal :: struct {
	active:   bool,
	labels:   [dynamic]string, // owned
	paths:    [dynamic]string, // owned
	selected: int,
	scroll:   int,
	cwd:      string,
}

personas_modal_init :: proc(m: ^Personas_Modal) {
	m.labels = make([dynamic]string, 0, 16)
	m.paths = make([dynamic]string, 0, 16)
	m.selected = 0
	m.scroll = 0
	m.active = false
	m.cwd = ""
}

personas_modal_destroy :: proc(m: ^Personas_Modal) {
	personas_modal_clear(m)
	delete(m.labels)
	delete(m.paths)
	delete(m.cwd)
	m.active = false
}

personas_modal_clear :: proc(m: ^Personas_Modal) {
	for l in m.labels {
		delete(l)
	}
	for p in m.paths {
		delete(p)
	}
	clear(&m.labels)
	clear(&m.paths)
	m.selected = 0
	m.scroll = 0
}

personas_modal_open :: proc(m: ^Personas_Modal, cwd: string) {
	personas_modal_clear(m)
	delete(m.cwd)
	m.cwd = strings.clone(cwd if cwd != "" else ".")
	// Built-in types
	append(&m.labels, strings.clone("type: general-purpose"))
	append(&m.paths, strings.clone(""))
	append(&m.labels, strings.clone("type: explore"))
	append(&m.paths, strings.clone(""))
	append(&m.labels, strings.clone("type: plan"))
	append(&m.paths, strings.clone(""))
	append(&m.labels, strings.clone("— personas (Enter: open in $PAGER · n: new stub) —"))
	append(&m.paths, strings.clone(""))

	list := agent.discover_personas(m.cwd, context.temp_allocator)
	if len(list) == 0 {
		append(&m.labels, strings.clone("  (no personas — press n to scaffold)"))
		append(&m.paths, strings.clone(""))
	} else {
		for p in list {
			desc := p.description if p.description != "" else p.path
			if len(desc) > 40 {
				desc = fmt.tprintf("%s…", desc[:37])
			}
			append(&m.labels, strings.clone(fmt.tprintf("  %s  %s", p.name, desc)))
			append(&m.paths, strings.clone(p.path))
		}
	}
	agent.destroy_personas(list)
	m.selected = 0
	m.scroll = 0
	m.active = true
}

personas_modal_close :: proc(m: ^Personas_Modal) {
	m.active = false
}

personas_modal_move :: proc(m: ^Personas_Modal, delta: int) {
	if len(m.labels) == 0 {
		return
	}
	m.selected += delta
	if m.selected < 0 {
		m.selected = 0
	}
	if m.selected >= len(m.labels) {
		m.selected = len(m.labels) - 1
	}
}

// personas_scaffold_stub creates ~/.grok/personas/example.md if missing.
personas_scaffold_stub :: proc(cwd: string) -> string {
	home := core.grok_home(context.temp_allocator)
	dir, _ := filepath.join({home, "personas"}, context.temp_allocator)
	_ = core.ensure_dir(dir)
	path, _ := filepath.join({dir, "example.md"}, context.temp_allocator)
	if os.exists(path) {
		return fmt.tprintf("already exists: %s", path)
	}
	body := "---\nname: example\ndescription: Sample persona for spawn_subagent persona=example\n---\n\nYou are a careful coding assistant. Prefer small, tested changes.\n"
	if err := os.write_entire_file(path, transmute([]byte)body); err != nil {
		return fmt.tprintf("write failed: %v", err)
	}
	return fmt.tprintf("created %s", path)
}

handle_personas_modal_key :: proc(st: ^App_State, term: ^Term_State, key: Key) -> bool {
	m := &st.personas_modal
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		personas_modal_close(m)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		personas_modal_move(m, -1)
		return true
	case .Down, .Ctrl_J:
		personas_modal_move(m, 1)
		return true
	case .Char:
		if key.ch == 'n' || key.ch == 'N' {
			msg := personas_scaffold_stub(m.cwd)
			state_add_notice(st, msg)
			personas_modal_open(m, m.cwd)
			state_set_status(st, "persona stub")
			return true
		}
	case .Enter:
		if m.selected < 0 || m.selected >= len(m.paths) {
			return true
		}
		path := m.paths[m.selected]
		if path == "" {
			state_set_status(st, "built-in type — use spawn persona=")
			return true
		}
		if term != nil && os.exists(path) {
			personas_modal_close(m)
			term_suspend_for_pager(term)
			_ = agent.run_transcript_pager(path)
			term_resume_after_pager(term)
			state_set_status(st, "persona closed")
		}
		return true
	}
	return false
}

write_personas_modal_body :: proc(b: ^strings.Builder, m: ^Personas_Modal, cols: int, body_h: int) {
	write_row(b, " agents / personas", cols, .Bar_Reverse, true)
	list_h := body_h - 2
	if list_h < 1 {
		list_h = 1
	}
	if m.selected < m.scroll {
		m.scroll = m.selected
	}
	if m.selected >= m.scroll + list_h {
		m.scroll = m.selected - list_h + 1
	}
	painted := 0
	for i := m.scroll; i < len(m.labels) && painted < list_h; i += 1 {
		sel := i == m.selected
		line := m.labels[i]
		if len(line) > cols - 2 {
			line = fmt.tprintf("%s…", line[:max(1, cols - 5)])
		}
		disp := fmt.tprintf("%s%s", "›" if sel else " ", line)
		write_row(b, disp, cols, .Bar_Reverse if sel else .Normal, true)
		painted += 1
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(b, " Enter open · n new stub · Esc", cols, .Bar_Dim, true)
}
