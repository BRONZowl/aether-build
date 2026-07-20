// Package tui — shared overlay focus + list navigation kit (Wave 0).
// New modals (settings, extensions, dashboard, queue pane) reuse Overlay_Kind
// and list_move / list_clamp so key routing stays consistent.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

// Overlay_Kind identifies which modal owns keys/paint (at most one).
Overlay_Kind :: enum {
	None,
	Ask,
	Session_Picker,
	Model_Picker,
	Search,
	Queue,
	Rewind,
	Settings,
	Extensions,
	Dashboard,
}

// overlay_kind: highest-priority active overlay (ask steals first).
overlay_kind :: proc(s: ^App_State) -> Overlay_Kind {
	if s == nil {
		return .None
	}
	if s.ask_active {
		return .Ask
	}
	if s.picker.active {
		return .Session_Picker
	}
	if s.model_picker.active {
		return .Model_Picker
	}
	if s.search.active {
		return .Search
	}
	if s.queue_pane_active {
		return .Queue
	}
	if s.rewind_picker.active {
		return .Rewind
	}
	if s.settings_modal.active {
		return .Settings
	}
	if s.extensions_hub.active {
		return .Extensions
	}
	if s.dashboard.active {
		return .Dashboard
	}
	return .None
}

// overlay_is_open: any modal that replaces body paint or steals keys.
overlay_is_open :: proc(s: ^App_State) -> bool {
	return overlay_kind(s) != .None
}

// overlay_blocks_composer: true when Enter should not submit the main prompt.
overlay_blocks_composer :: proc(s: ^App_State) -> bool {
	k := overlay_kind(s)
	return k != .None && k != .Search // search coexists with scroll keys
}

// List_Nav: shared selected/scroll/filter indices for list modals.
List_Nav :: struct {
	selected: int,
	scroll:   int,
	filter:   [dynamic]u8,
	visible:  [dynamic]int, // indices into entry array
}

list_nav_init :: proc(n: ^List_Nav) {
	n.selected = 0
	n.scroll = 0
	n.filter = make([dynamic]u8, 0, 32)
	n.visible = make([dynamic]int, 0, 16)
}

list_nav_destroy :: proc(n: ^List_Nav) {
	delete(n.filter)
	delete(n.visible)
	n.selected = 0
	n.scroll = 0
}

list_nav_clear_filter :: proc(n: ^List_Nav) {
	clear(&n.filter)
}

list_nav_filter_text :: proc(n: ^List_Nav) -> string {
	return string(n.filter[:])
}

list_nav_move :: proc(n: ^List_Nav, delta: int) {
	if len(n.visible) == 0 {
		return
	}
	n.selected += delta
	if n.selected < 0 {
		n.selected = 0
	}
	if n.selected >= len(n.visible) {
		n.selected = len(n.visible) - 1
	}
}

list_nav_clamp :: proc(n: ^List_Nav) {
	if len(n.visible) == 0 {
		n.selected = 0
		n.scroll = 0
		return
	}
	if n.selected < 0 {
		n.selected = 0
	}
	if n.selected >= len(n.visible) {
		n.selected = len(n.visible) - 1
	}
}

// list_nav_ensure_visible keeps selected row inside [scroll, scroll+view_h).
list_nav_ensure_visible :: proc(n: ^List_Nav, view_h: int) {
	if view_h < 1 || len(n.visible) == 0 {
		return
	}
	if n.selected < n.scroll {
		n.scroll = n.selected
	}
	if n.selected >= n.scroll + view_h {
		n.scroll = n.selected - view_h + 1
	}
	if n.scroll < 0 {
		n.scroll = 0
	}
}

// list_nav_selected_entry: entry index or -1.
list_nav_selected_entry :: proc(n: ^List_Nav) -> int {
	if len(n.visible) == 0 {
		return -1
	}
	if n.selected < 0 || n.selected >= len(n.visible) {
		return -1
	}
	return n.visible[n.selected]
}

// list_nav_type_filter: append printable ASCII; returns true if filter changed.
list_nav_type_filter :: proc(n: ^List_Nav, ch: int) -> bool {
	if ch < 32 || ch >= 127 {
		return false
	}
	append(&n.filter, u8(ch))
	return true
}

list_nav_backspace_filter :: proc(n: ^List_Nav) -> bool {
	if len(n.filter) == 0 {
		return false
	}
	resize(&n.filter, len(n.filter) - 1)
	return true
}
