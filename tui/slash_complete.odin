// Package tui — slash command Tab autocomplete (B20 / Grok-shaped).
// Match list from core.SLASH_CATALOG: bare `/` = primaries; longer prefix
// also matches aliases (type /ex → /exit still completes).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tui

import "core:fmt"
import "core:strings"
import "aether:core"

// slash_token_prefix: text from last newline (or start) to cursor if it is a
// partial slash command (starts with `/`, no space). Returns ("", false) otherwise.
slash_token_prefix :: proc(text: string, cursor: int) -> (prefix: string, ok: bool) {
	cur := cursor
	if cur < 0 {
		cur = 0
	}
	if cur > len(text) {
		cur = len(text)
	}
	start := 0
	for i in 0 ..< cur {
		if text[i] == '\n' {
			start = i + 1
		}
	}
	frag := text[start:cur]
	if frag == "" || frag[0] != '/' {
		return "", false
	}
	// already past command word → do not hijack Tab
	for i in 1 ..< len(frag) {
		if frag[i] == ' ' || frag[i] == '\t' {
			return "", false
		}
	}
	return frag, true
}

// collect_slash_matches appends command names that have_prefix(prefix).
// Bare "/" → menu primaries only; longer prefix → primary + matching aliases.
collect_slash_matches :: proc(prefix: string, out: ^[dynamic]string) {
	core.slash_collect_matches(prefix, out)
}

// collect_slash_match_rows: name + description for Grok-shaped dropdown.
collect_slash_match_rows :: proc(prefix: string, out: ^[dynamic]core.Slash_Match) {
	core.slash_collect_match_rows(prefix, out)
}

// common_slash_prefix of a non-empty match list (longest shared prefix).
common_slash_prefix :: proc(matches: []string) -> string {
	if len(matches) == 0 {
		return ""
	}
	if len(matches) == 1 {
		return matches[0]
	}
	base := matches[0]
	n := len(base)
	for m in matches[1:] {
		i := 0
		for i < n && i < len(m) && base[i] == m[i] {
			i += 1
		}
		n = i
		if n == 0 {
			return ""
		}
	}
	return base[:n]
}

// apply_slash_completion replaces the slash token before cursor with `completed`
// (optionally appends a trailing space when unique full match).
// Returns true if input changed.
apply_slash_completion :: proc(s: ^App_State, completed: string, add_space: bool) -> bool {
	text := input_text(s)
	cur := s.cursor
	prefix, ok := slash_token_prefix(text, cur)
	if !ok || completed == "" {
		return false
	}
	start := cur - len(prefix)
	if start < 0 {
		return false
	}
	// rebuild: before + completed + space? + after cursor
	after := text[cur:]
	ins := completed
	if add_space && !strings.has_suffix(ins, " ") {
		ins = fmt.tprintf("%s ", completed)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, text[:start])
	strings.write_string(&b, ins)
	strings.write_string(&b, after)
	new_text := strings.to_string(b)
	input_set_text(s, new_text)
	s.cursor = start + len(ins)
	return true
}

// try_slash_tab_complete: Tab handler when prompt has a slash token.
// With live menu: accepts highlighted row (Tab) or advances selection (Shift+Tab via navigate).
// Without multi match: LCP expand then cycle.
// Returns true if Tab was consumed (caller should not toggle focus).
try_slash_tab_complete :: proc(s: ^App_State) -> bool {
	if s == nil || s.focus != .Prompt {
		return false
	}
	text := input_text(s)
	prefix, ok := slash_token_prefix(text, s.cursor)
	if !ok {
		// reset cycle state
		s.slash_comp_idx = 0
		if s.slash_comp_prefix != "" {
			delete(s.slash_comp_prefix)
			s.slash_comp_prefix = ""
		}
		return false
	}

	matches := make([dynamic]string, 0, 16, context.temp_allocator)
	collect_slash_matches(prefix, &matches)
	if len(matches) == 0 {
		state_set_status(s, fmt.tprintf("no slash match for %s", prefix))
		return true
	}

	// Unique → complete with space
	if len(matches) == 1 {
		_ = apply_slash_completion(s, matches[0], true)
		state_set_status(s, matches[0])
		slash_complete_reset(s)
		s.slash_menu_sel = 0
		return true
	}

	// Live menu: Tab always accepts the highlighted row (visible list UX).
	idx := s.slash_menu_sel
	if idx < 0 || idx >= len(matches) {
		idx = 0
	}
	chosen := matches[idx]
	_ = apply_slash_completion(s, chosen, true)
	state_set_status(s, fmt.tprintf("%s  (%d/%d)", chosen, idx + 1, len(matches)))
	slash_complete_reset(s)
	s.slash_menu_sel = 0
	return true
}

// slash_complete_reset clears Tab-cycle state (call on input edit if desired).
slash_complete_reset :: proc(s: ^App_State) {
	if s == nil {
		return
	}
	s.slash_comp_idx = 0
	if s.slash_comp_prefix != "" {
		delete(s.slash_comp_prefix)
		s.slash_comp_prefix = ""
	}
	// keep slash_menu_sel; refreshed when matches recompute
}

SLASH_MENU_MAX :: 8

// slash_menu_matches: current slash-token matches for live popup (temp ok).
// Returns false if menu should not show (not on slash token / empty).
slash_menu_matches :: proc(
	s: ^App_State,
	out: ^[dynamic]string,
) -> bool {
	rows := make([dynamic]core.Slash_Match, 0, 16, context.temp_allocator)
	if !slash_menu_match_rows(s, &rows) {
		return false
	}
	clear(out)
	for r in rows {
		append(out, r.name)
	}
	return true
}

// slash_menu_match_rows: name + description for Grok-shaped dropdown.
slash_menu_match_rows :: proc(
	s: ^App_State,
	out: ^[dynamic]core.Slash_Match,
) -> bool {
	if s == nil || s.focus != .Prompt {
		return false
	}
	if overlay_is_open(s) {
		return false
	}
	text := input_text(s)
	prefix, ok := slash_token_prefix(text, s.cursor)
	if !ok {
		return false
	}
	collect_slash_match_rows(prefix, out)
	if len(out) == 0 {
		return false
	}
	if s.slash_menu_sel < 0 {
		s.slash_menu_sel = 0
	}
	if s.slash_menu_sel >= len(out) {
		s.slash_menu_sel = len(out) - 1
	}
	return true
}

// slash_menu_height: rows reserved above status for the suggestion list.
// Grok chrome: top rule (+count) + item rows (+ optional bottom rule).
// term_rows / input_h cap the menu so header+body(1)+menu+status+input fit.
slash_menu_height :: proc(s: ^App_State, term_rows: int = 0, input_h: int = 1) -> int {
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	if !slash_menu_matches(s, &ms) {
		return 0
	}
	n := len(ms)
	if n > SLASH_MENU_MAX {
		n = SLASH_MENU_MAX
	}
	// +1 top border; +1 bottom border when enough space (Grok panel chrome)
	want := n + 2
	if term_rows > 0 {
		// chrome: header(1) + min body(1) + optional status + input_h
		ih := input_h if input_h > 0 else 1
		// Slash menu open → status row usually visible (match counts); budget conservatively.
		status_rows := 1 if status_row_visible(s) else 0
		// When deciding menu height before status_row_visible sees matches, reserve 1 for status
		// once we know we have matches (this proc only runs with matches).
		if status_rows == 0 {
			status_rows = 1
		}
		budget := term_rows - 1 - 1 - status_rows - ih // remaining for menu
		if budget < 2 {
			// still show at least top rule + 1 match if possible
			budget = max(0, term_rows - 1 - 1 - ih)
		}
		if budget < 2 {
			return 0 // terminal too short for a useful menu
		}
		if want > budget {
			want = budget
		}
	}
	return want
}

// slash_menu_navigate: ↑/↓ while menu open. Returns true if consumed.
slash_menu_navigate :: proc(s: ^App_State, delta: int) -> bool {
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	if !slash_menu_matches(s, &ms) {
		return false
	}
	n := len(ms)
	if n <= 0 {
		return false
	}
	s.slash_menu_sel = (s.slash_menu_sel + delta) % n
	if s.slash_menu_sel < 0 {
		s.slash_menu_sel += n
	}
	return true
}

// slash_menu_accept: apply highlighted (or only) match. Returns true if applied.
slash_menu_accept :: proc(s: ^App_State) -> bool {
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	if !slash_menu_matches(s, &ms) {
		return false
	}
	idx := s.slash_menu_sel
	if idx < 0 || idx >= len(ms) {
		idx = 0
	}
	ok := apply_slash_completion(s, ms[idx], true)
	if ok {
		state_set_status(s, ms[idx])
		slash_complete_reset(s)
		s.slash_menu_sel = 0
	}
	return ok
}

// slash_menu_click: mouse hit on suggestion row (1-based screen y).
// body_h / menu_h match render layout. Header row of the menu is non-select.
// Returns true if a match was accepted.
slash_menu_click :: proc(s: ^App_State, y, body_h, menu_h: int) -> bool {
	if s == nil || menu_h <= 0 {
		return false
	}
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	if !slash_menu_matches(s, &ms) {
		return false
	}
	menu_start := top_chrome_rows() + 1 + body_h // first row of menu (after top chrome + body)
	// row 0 of menu = header; rows 1.. are matches (windowed like write_slash_menu)
	rel := y - menu_start
	if rel <= 0 {
		// clicked header — focus prompt only
		if s.focus != .Prompt {
			// keep API local — caller may focus
		}
		return false
	}
	shown := menu_h - 1
	if shown > len(ms) {
		shown = len(ms)
	}
	if shown <= 0 {
		return false
	}
	// same scroll window as write_slash_menu
	start := 0
	if s.slash_menu_sel >= shown {
		start = s.slash_menu_sel - shown + 1
	}
	if start < 0 {
		start = 0
	}
	if start + shown > len(ms) {
		start = max(0, len(ms) - shown)
	}
	row := rel - 1 // 0-based among match rows
	if row < 0 || row >= shown {
		return false
	}
	idx := start + row
	if idx < 0 || idx >= len(ms) {
		return false
	}
	s.slash_menu_sel = idx
	return slash_menu_accept(s)
}

// slash_menu_dismiss: Esc while menu open — clear the slash token (keep prior text).
// Returns true if dismissed.
slash_menu_dismiss :: proc(s: ^App_State) -> bool {
	if s == nil || s.focus != .Prompt {
		return false
	}
	ms := make([dynamic]string, 0, 4, context.temp_allocator)
	if !slash_menu_matches(s, &ms) {
		return false
	}
	text := input_text(s)
	prefix, ok := slash_token_prefix(text, s.cursor)
	if !ok {
		return false
	}
	start := s.cursor - len(prefix)
	if start < 0 {
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, text[:start])
	strings.write_string(&b, text[s.cursor:])
	input_set_text(s, strings.to_string(b))
	s.cursor = start
	slash_complete_reset(s)
	s.slash_menu_sel = 0
	state_set_status(s, "ready")
	return true
}
