#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"

// Session_Picker is a Grok-shaped Ctrl+S resume list.
Session_Picker :: struct {
	active:   bool,
	entries:  [dynamic]agent.Session_List_Entry, // owned
	// filtered indices into entries (or all when filter empty)
	visible:  [dynamic]int,
	selected: int, // index into visible
	scroll:   int, // first visible row in list viewport
	filter:   [dynamic]u8,
}

picker_init :: proc(p: ^Session_Picker) {
	p.entries = make([dynamic]agent.Session_List_Entry, 0, 16)
	p.visible = make([dynamic]int, 0, 16)
	p.filter = make([dynamic]u8, 0, 32)
	p.selected = 0
	p.scroll = 0
	p.active = false
}

picker_destroy :: proc(p: ^Session_Picker) {
	picker_clear_entries(p)
	delete(p.entries)
	delete(p.visible)
	delete(p.filter)
	p.active = false
}

picker_clear_entries :: proc(p: ^Session_Picker) {
	for e in p.entries {
		delete(e.id)
		delete(e.title)
		delete(e.path)
		delete(e.updated_at)
		delete(e.model)
	}
	clear(&p.entries)
	clear(&p.visible)
}

// picker_open loads sessions from dir and activates the modal.
picker_open :: proc(p: ^Session_Picker, sessions_dir: string) -> string /* err */ {
	picker_clear_entries(p)
	clear(&p.filter)
	p.selected = 0
	p.scroll = 0

	list, err := agent.list_sessions(sessions_dir, context.allocator)
	if err != "" {
		p.active = true // still show empty/error state
		picker_refilter(p)
		return err
	}
	// Cap to 50 newest
	n := min(50, len(list))
	for i in 0 ..< n {
		e := list[i]
		append(
			&p.entries,
			agent.Session_List_Entry {
				id         = strings.clone(e.id),
				title      = strings.clone(e.title),
				path       = strings.clone(e.path),
				updated_at = strings.clone(e.updated_at),
				model      = strings.clone(e.model),
			},
		)
	}
	// free list's own allocations
	agent.destroy_session_list(list)
	picker_refilter(p)
	p.active = true
	return ""
}

picker_close :: proc(p: ^Session_Picker) {
	p.active = false
	clear(&p.filter)
}

picker_filter_text :: proc(p: ^Session_Picker) -> string {
	return string(p.filter[:])
}

picker_refilter :: proc(p: ^Session_Picker) {
	clear(&p.visible)
	q := strings.to_lower(string(p.filter[:]), context.temp_allocator)
	for i in 0 ..< len(p.entries) {
		e := p.entries[i]
		if q == "" {
			append(&p.visible, i)
			continue
		}
		id_l := strings.to_lower(e.id, context.temp_allocator)
		title_l := strings.to_lower(e.title, context.temp_allocator)
		if strings.contains(id_l, q) || strings.contains(title_l, q) {
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

picker_move :: proc(p: ^Session_Picker, delta: int) {
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

// picker_selected_path returns path of current selection or "".
picker_selected_path :: proc(p: ^Session_Picker) -> string {
	if !p.active || len(p.visible) == 0 {
		return ""
	}
	if p.selected < 0 || p.selected >= len(p.visible) {
		return ""
	}
	ei := p.visible[p.selected]
	if ei < 0 || ei >= len(p.entries) {
		return ""
	}
	return p.entries[ei].path
}

picker_selected_id :: proc(p: ^Session_Picker) -> string {
	if !p.active || len(p.visible) == 0 {
		return ""
	}
	if p.selected < 0 || p.selected >= len(p.visible) {
		return ""
	}
	ei := p.visible[p.selected]
	return p.entries[ei].id
}

// picker_row_label formats one list line for display.
picker_row_label :: proc(e: agent.Session_List_Entry, cols: int) -> string {
	title := e.title if e.title != "" else "(untitled)"
	// short updated (date part if RFC3339)
	upd := e.updated_at
	if len(upd) >= 10 {
		upd = upd[:10]
	}
	line := fmt.tprintf("%s  %s  %s", e.id, upd, title)
	// hard truncate by runes roughly via bytes for paint
	if len(line) > cols - 2 {
		if cols > 4 {
			line = fmt.tprintf("%s…", line[:cols - 3])
		}
	}
	return line
}

// --- Model picker (Ctrl+M when scrollback focused) ---

KNOWN_MODELS :: []string {
	"grok-4.5",
	"grok-4-1-fast-reasoning",
	"grok-4-fast",
	"grok-build",
}

Model_Picker :: struct {
	active:   bool,
	entries:  [dynamic]string, // owned model ids
	visible:  [dynamic]int,
	selected: int,
	scroll:   int,
	filter:   [dynamic]u8,
	current:  string, // not owned; snapshot of current model at open
}

model_picker_init :: proc(p: ^Model_Picker) {
	p.entries = make([dynamic]string, 0, 8)
	p.visible = make([dynamic]int, 0, 8)
	p.filter = make([dynamic]u8, 0, 32)
	p.selected = 0
	p.scroll = 0
	p.active = false
	p.current = ""
}

model_picker_destroy :: proc(p: ^Model_Picker) {
	model_picker_clear(p)
	delete(p.entries)
	delete(p.visible)
	delete(p.filter)
	p.active = false
}

model_picker_clear :: proc(p: ^Model_Picker) {
	for e in p.entries {
		delete(e)
	}
	clear(&p.entries)
	clear(&p.visible)
}

model_picker_open :: proc(p: ^Model_Picker, current_model: string) {
	model_picker_clear(p)
	clear(&p.filter)
	p.scroll = 0
	p.current = current_model

	// unique catalog + current
	add :: proc(p: ^Model_Picker, id: string) {
		if id == "" {
			return
		}
		for e in p.entries {
			if e == id {
				return
			}
		}
		append(&p.entries, strings.clone(id))
	}
	for m in KNOWN_MODELS {
		add(p, m)
	}
	add(p, current_model)

	model_picker_refilter(p)
	// preselect current
	p.selected = 0
	for vi in 0 ..< len(p.visible) {
		ei := p.visible[vi]
		if p.entries[ei] == current_model {
			p.selected = vi
			break
		}
	}
	p.active = true
}

model_picker_close :: proc(p: ^Model_Picker) {
	p.active = false
	clear(&p.filter)
}

model_picker_filter_text :: proc(p: ^Model_Picker) -> string {
	return string(p.filter[:])
}

model_picker_refilter :: proc(p: ^Model_Picker) {
	clear(&p.visible)
	q := strings.to_lower(string(p.filter[:]), context.temp_allocator)
	for i in 0 ..< len(p.entries) {
		if q == "" {
			append(&p.visible, i)
			continue
		}
		id_l := strings.to_lower(p.entries[i], context.temp_allocator)
		if strings.contains(id_l, q) {
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

model_picker_move :: proc(p: ^Model_Picker, delta: int) {
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

model_picker_selected :: proc(p: ^Model_Picker) -> string {
	if !p.active || len(p.visible) == 0 {
		return ""
	}
	if p.selected < 0 || p.selected >= len(p.visible) {
		return ""
	}
	return p.entries[p.visible[p.selected]]
}
