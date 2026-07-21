#+build linux, darwin, freebsd, openbsd, netbsd
// TUI chrome: Grok-shaped top bar (branch · cwd · mode · context chips).
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"
import "aether:tools"

// BRANCH_ICON matches Grok non-nerd fallback (⎇); ASCII fallback for safety in tests.
BRANCH_ICON :: "⎇"

// composer_use_box: Grok-shaped rounded frame around the prompt (non-compact, wide enough).
composer_use_box :: proc(cols: int) -> bool {
	return !core.compact_mode_enabled() && cols >= 28
}

// composer_frame_rows: chrome rows around the prompt text.
// Boxed: blank pad + top border + bottom border (Grok vpad + rails).
// Compact: none. Narrow non-compact: dim info line only under field.
composer_frame_rows :: proc(s: ^App_State, cols: int) -> (top, bottom: int) {
	_ = s
	if composer_use_box(cols) {
		// 1 blank gap above box + 1 top rail; 1 bottom rail with caption
		return 2, 1
	}
	if core.compact_mode_enabled() {
		return 0, 0
	}
	return 0, 1
}

// composer_info_rows: rows below the text field for model · mode (legacy name).
composer_info_rows :: proc(s: ^App_State) -> int {
	// Prefer cols from last paint; if unknown assume box-capable width.
	cols := s.last_cols if s.last_cols > 0 else 80
	_, bottom := composer_frame_rows(s, cols)
	return bottom
}

// chrome_fixed_rows: header + status only (composer frame is part of input block).
chrome_fixed_rows :: proc(s: ^App_State) -> int {
	_ = s
	return 2 // header + hints status
}

// composer_block_height: text lines + optional box/info chrome.
composer_block_height :: proc(s: ^App_State, cols: int) -> int {
	top, bottom := composer_frame_rows(s, cols)
	return top + input_line_count(s, cols) + bottom
}

// format_top_bar builds the Grok-shaped top chrome line for width cols.
// left: branch + cwd; right: plan/goal/todos/ctx/mode/model. Truncates left first.
format_top_bar :: proc(s: ^App_State, cols: int) -> string {
	cwd := s.cwd if s.cwd != "" else "."
	compact := core.compact_mode_enabled()

	// --- left: location ---
	left_b := strings.builder_make(context.temp_allocator)
	branch := core.git_branch_cached(cwd)
	if branch != "" {
		strings.write_string(&left_b, BRANCH_ICON)
		strings.write_string(&left_b, " ")
		strings.write_string(&left_b, branch)
		strings.write_string(&left_b, " ")
	}
	cwd_disp := core.format_cwd_display(cwd, context.temp_allocator)
	strings.write_string(&left_b, cwd_disp)
	left := strings.to_string(left_b)

	// --- right: chips ---
	right_b := strings.builder_make(context.temp_allocator)
	first := true
	write_chip :: proc(b: ^strings.Builder, first: ^bool, chip: string) {
		if chip == "" {
			return
		}
		if !first^ {
			strings.write_string(b, " · ")
		}
		first^ = false
		strings.write_string(b, chip)
	}

	plan := strings.trim_space(agent.plan_mode_chip())
	// plan_mode_chip often returns " plan" with leading space
	if plan != "" {
		write_chip(&right_b, &first, plan)
	}
	goal := strings.trim_space(agent.goal_chip())
	if goal != "" {
		write_chip(&right_b, &first, goal)
	}
	if n := tools.todo_open_count(); n > 0 {
		write_chip(&right_b, &first, fmt.tprintf("todos:%d", n))
	}
	ctx := ""
	if stream_sess() != nil {
		live := ""
		if s.streaming {
			live = strings.to_string(s.live_assist)
		}
		ctx = strings.trim_space(format_context_chip(stream_sess().msgs[:], live, compact))
	}
	if ctx != "" {
		write_chip(&right_b, &first, ctx)
	}
	// permission mode
	mode := s.perm if s.perm != "" else "ask"
	if compact {
		// short labels
		switch mode {
		case "always-approve":
			mode = "yolo"
		case "read-only":
			mode = "ro"
		}
	}
	write_chip(&right_b, &first, mode)
	// model (short)
	model := s.model if s.model != "" else ""
	if model != "" {
		if compact && len(model) > 16 {
			model = fmt.tprintf("%s…", model[:15])
		} else if !compact && len(model) > 28 {
			model = fmt.tprintf("%s…", model[:27])
		}
		write_chip(&right_b, &first, model)
	}
	right := strings.to_string(right_b)

	return layout_left_right(left, right, cols)
}

// layout_left_right pads left and right into cols; truncates left (with …) if needed.
layout_left_right :: proc(left, right: string, cols: int) -> string {
	w := max(8, cols)
	lw := utf8.rune_count(left)
	rw := utf8.rune_count(right)
	// Prefer keeping right chips fully visible
	if rw + 1 >= w {
		// only room for right (or right truncated)
		return truncate_runes(right, w)
	}
	max_left := w - rw - 1 // at least one space
	if max_left < 0 {
		max_left = 0
	}
	l := left
	if lw > max_left {
		l = truncate_runes(left, max_left)
		lw = utf8.rune_count(l)
	}
	pad := w - lw - rw
	if pad < 1 {
		pad = 1
		// re-truncate left
		max_left = w - rw - pad
		if max_left < 0 {
			max_left = 0
		}
		l = truncate_runes(left, max_left)
		lw = utf8.rune_count(l)
		pad = max(0, w - lw - rw)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, l)
	for i in 0 ..< pad {
		_ = i
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, right)
	return strings.to_string(b)
}

truncate_runes :: proc(s: string, max_runes: int) -> string {
	if max_runes <= 0 {
		return ""
	}
	if utf8.rune_count(s) <= max_runes {
		return s
	}
	if max_runes == 1 {
		return "…"
	}
	// take max_runes-1 runes + ellipsis
	n := 0
	end := 0
	for end < len(s) && n < max_runes - 1 {
		_, sz := utf8.decode_rune(s[end:])
		if sz <= 0 {
			sz = 1
		}
		end += sz
		n += 1
	}
	return fmt.tprintf("%s…", s[:end])
}

// format_composer_info: caption text for bottom rail / dim line — "model · mode [· multi]"
format_composer_info :: proc(s: ^App_State) -> string {
	mode := s.perm if s.perm != "" else "ask"
	model := s.model if s.model != "" else "—"
	if s.multiline_mode {
		return fmt.tprintf("%s · %s · multi", model, mode)
	}
	return fmt.tprintf("%s · %s", model, mode)
}

// format_composer_top_border: ╭──── title ─╮ with title right-aligned (2 cells before ╮).
// Matches Grok chrome caption placement on the top rail.
format_composer_top_border :: proc(cols: int, title: string = "") -> string {
	w := max(4, cols)
	return format_box_rail(w, "╭", "╮", title, .Right)
}

// format_composer_bottom_border: ╰──── caption ─╯ with caption right-aligned.
// Matches Grok bottom divider (model · mode near the right end).
format_composer_bottom_border :: proc(cols: int, caption: string) -> string {
	w := max(4, cols)
	return format_box_rail(w, "╰", "╯", caption, .Right)
}

Rail_Align :: enum {
	Left,
	Right,
}

// format_box_rail: open + dashes + optional " label " + dashes + close, total width cols.
// Label is right-aligned with 2 cells of border before the close corner (Grok).
format_box_rail :: proc(
	cols: int,
	open, close: string,
	caption: string,
	align: Rail_Align,
) -> string {
	w := max(4, cols)
	avail := w - 2 // between corners
	cap := strings.trim_space(caption)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, open)
	if cap == "" {
		for i in 0 ..< avail {
			_ = i
			strings.write_string(&b, "─")
		}
		strings.write_string(&b, close)
		return strings.to_string(b)
	}
	label := fmt.tprintf(" %s ", cap)
	// Keep ≥2 dash cells at the trailing end before ╮/╯ (Grok inset).
	max_label := avail - 2
	if max_label < 3 {
		max_label = max(1, avail - 1)
	}
	if utf8.rune_count(label) > max_label {
		// truncate caption body inside spaces
		inner_max := max(1, max_label - 2)
		label = fmt.tprintf(" %s ", truncate_runes(cap, inner_max))
	}
	lw := utf8.rune_count(label)
	dashes_total := max(0, avail - lw)
	dashes_left, dashes_right: int
	switch align {
	case .Right:
		// right-align: most dashes left, 2 (or remaining) right of label
		dashes_right = min(2, dashes_total)
		dashes_left = dashes_total - dashes_right
	case .Left:
		dashes_left = min(1, dashes_total)
		dashes_right = dashes_total - dashes_left
	}
	for i in 0 ..< dashes_left {
		_ = i
		strings.write_string(&b, "─")
	}
	strings.write_string(&b, label)
	for i in 0 ..< dashes_right {
		_ = i
		strings.write_string(&b, "─")
	}
	strings.write_string(&b, close)
	return strings.to_string(b)
}

// composer_border_ansi: stronger when prompt focused, dim when scrollback-focused.
composer_border_ansi :: proc(focused: bool, th: Theme) -> string {
	if focused {
		// bold + user accent when available
		if th.user != "" {
			return strings.concatenate({th.bold if th.bold != "" else "\x1b[1m", th.user}, context.temp_allocator)
		}
		return th.bold if th.bold != "" else "\x1b[1m"
	}
	// unfocused: muted
	if th.dim != "" {
		return th.dim
	}
	return "\x1b[2m"
}

// format_composer_side_row: "│ " + content padded + "│" to cols (tests / helpers).
format_composer_side_row :: proc(content: string, cols: int) -> string {
	w := max(4, cols)
	inner := w - 2 // between │ │
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "│")
	pad_content := fmt.tprintf(" %s", content)
	n := 0
	for r in pad_content {
		if n >= inner {
			break
		}
		strings.write_string(&b, fmt.tprintf("%c", r))
		n += 1
	}
	for n < inner {
		strings.write_byte(&b, ' ')
		n += 1
	}
	strings.write_string(&b, "│")
	return strings.to_string(b)
}
