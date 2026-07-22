// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui


// apply_mouse_click handles left-click: select scrollback block or focus prompt (C2.3).
// Returns true if UI state changed.
apply_mouse_click :: proc(st: ^App_State, term: ^Term_State, mx, my: int) -> bool {
	_ = mx // column unused for now (full-line hit)
	rows := max(6, term.rows)
	cols := max(20, term.cols)
	_ = input_line_count(st, cols)
	block_h := composer_block_height(st, cols)
	menu_h := slash_menu_height(st, rows, block_h)
	fixed := chrome_fixed_rows(st)
	status_h := 1 if status_row_visible(st) else 0
	body_h := rows - fixed - block_h - menu_h
	if body_h < 1 {
		body_h = 1
	}
	for body_h + menu_h + fixed + block_h > rows && menu_h > 0 {
		menu_h -= 1
	}
	// hit_test treats "input" as the full composer block (box + text)
	zone := hit_test_click_zone(my, rows, body_h, block_h, menu_h, status_h)
	switch zone {
	case .Input:
		if st.focus != .Prompt {
			focus_prompt(st)
			return true
		}
		return false
	case .Slash_Menu:
		if st.focus != .Prompt {
			focus_prompt(st)
		}
		if slash_menu_click(st, my, body_h, menu_h) {
			return true
		}
		return st.focus == .Prompt // focus change only
	case .Header, .Status, .Outside:
		return false
	case .Body:
		// Recompute flatten map (same as render)
		lines := make([dynamic]string, 0, 128, context.temp_allocator)
		styles := make([dynamic]Line_Style, 0, 128, context.temp_allocator)
		block_idxs := make([dynamic]int, 0, 128, context.temp_allocator)
		flatten_blocks(st, cols, &lines, &styles, &block_idxs, context.temp_allocator, rows)
		total := len(lines)
		max_scroll := max(0, total - body_h)
		scroll := st.scroll
		if scroll > max_scroll {
			scroll = max_scroll
		}
		start := max(0, total - body_h - scroll)
		line_i := body_line_index(my, body_h, start, total)
		changed := false
		if st.focus != .Scrollback {
			focus_scrollback(st)
			changed = true
		}
		if line_i >= 0 && line_i < len(block_idxs) {
			bi := block_idxs[line_i]
			if bi >= 0 && bi < len(st.blocks) {
				if st.selected_block != bi {
					st.selected_block = bi
					changed = true
				}
			}
		}
		return changed
	}
	return false
}
