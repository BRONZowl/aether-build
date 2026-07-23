// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
// TUI chrome: Grok-shaped top bar (branch · cwd · context used/window) + composer rails.
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"
import "aether:tools"

// BRANCH_ICON matches Grok non-nerd fallback (⎇); ASCII fallback for safety in tests.
BRANCH_ICON :: "⎇"

// TOP_BAR_GAP: blank rows between the top bar and the transcript/output body.
TOP_BAR_GAP :: 1

// top_chrome_rows: header (1) + gap before body.
top_chrome_rows :: proc() -> int {
	return 1 + TOP_BAR_GAP
}

// composer_use_box: Grok-shaped rounded frame around the prompt (non-compact, wide enough).
composer_use_box :: proc(cols: int) -> bool {
	return !core.compact_mode_enabled() && cols >= 28
}

// composer_frame_rows: chrome rows around the prompt text.
// Boxed: blank pad + top border + bottom border (Grok vpad + rails).
// Compact: none. Narrow non-compact: dim info line only under field.
// Plan approval: no composer chrome (feedback lives in the approval body).
composer_frame_rows :: proc(s: ^App_State, cols: int) -> (top, bottom: int) {
	if s != nil && s.plan_approval.active {
		return 0, 0
	}
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

// status_row_visible: paint the line above the composer?
// Hidden when idle at prompt with status "ready" (no Enter/Tab/Q hint bar).
// Shown for streaming spinner, ask/modals, scrollback, multiline, slash menu, errors.
status_row_visible :: proc(s: ^App_State) -> bool {
	if s == nil {
		return false
	}
	if s.plan_approval.active || s.ask_active || s.streaming || s.multiline_mode {
		return true
	}
	// Detached from follow: show scroll position like Grok scrollbar chrome
	if !s.stream_follow {
		return true
	}
	if s.focus == .Scrollback || s.search.active || s.queue_pane_active {
		return true
	}
	if overlay_is_open(s) {
		return true
	}
	st := s.status if s.status != "" else "ready"
	if st != "ready" {
		return true
	}
	// Live slash suggestions (menu open) keep the status row for match counts.
	ms := make([dynamic]string, 0, 4, context.temp_allocator)
	if slash_menu_matches(s, &ms) {
		return true
	}
	return false
}

// chrome_fixed_rows: top bar + gap [+ optional status]; composer frame is separate.
chrome_fixed_rows :: proc(s: ^App_State) -> int {
	n := top_chrome_rows() // top bar + blank gap before body
	if status_row_visible(s) {
		n += 1
	}
	return n
}

// composer_block_height: text lines + optional box/info chrome.
composer_block_height :: proc(s: ^App_State, cols: int) -> int {
	top, bottom := composer_frame_rows(s, cols)
	return top + input_line_count(s, cols) + bottom
}

// format_top_bar builds the Grok-shaped top chrome line for width cols.
// left: branch + cwd; right: plan/goal/todos + context used/window (not mode/model).
// Truncates left first. Mode/model live on the composer bottom rail.
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

	// --- right: chips (no permission/model — those are on the composer caption) ---
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
	// Context used/window (Grok context_bar style). Prefer live_sess (always set by
	// TUI loop); fall back to mid-turn stream_sess when bound.
	live := ""
	if s.streaming {
		live = strings.to_string(s.live_assist)
	}
	msgs: []agent.Chat_Message
	if sess := live_session(s); sess != nil {
		msgs = sess.msgs[:]
	} else if stream_sess() != nil {
		msgs = stream_sess().msgs[:]
	}
	model := s.model if s != nil else ""
	ctx := strings.trim_space(format_context_chip(msgs, live, compact, model))
	if ctx != "" {
		write_chip(&right_b, &first, ctx)
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

// composer_in_plan: any plan lifecycle state (Pending/Active/Exit_Pending).
// Shift+Tab enters Pending until the first turn activates — must not show "ask".
composer_in_plan :: proc() -> bool {
	return agent.plan_mode_is_active() ||
		agent.plan_mode_is_pending() ||
		agent.plan_mode_is_exit_pending()
}

// format_composer_info: bottom rail caption — "model · [effort ·] mode [· multi]".
// Effort is live; mode uses plan chip label whenever plan is on (not only Active).
format_composer_info :: proc(s: ^App_State) -> string {
	mode := s.perm if s != nil && s.perm != "" else "ask"
	if composer_in_plan() {
		// "plan" / "plan…" / "plan↓" — same vocabulary as top-bar chip
		chip := strings.trim_space(agent.plan_mode_chip())
		if chip != "" {
			mode = chip
		} else {
			mode = "plan"
		}
	}
	model := s.model if s != nil && s.model != "" else "—"
	eff := agent.reasoning_effort_current()
	if s != nil && s.multiline_mode {
		if eff != "" {
			return fmt.tprintf("%s · %s · %s · multi", model, eff, mode)
		}
		return fmt.tprintf("%s · %s · multi", model, mode)
	}
	if eff != "" {
		return fmt.tprintf("%s · %s · %s", model, eff, mode)
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

// Mode chrome (Grok-aligned borders + distinct bottom-rail flags only):
//   - Border / chevron: plan → gold; else neutral prompt_border* / user chevron
//   - Bottom mode token: distinct color per mode (caption only — not the box)

// composer_mode_accent: chevron tint — plan gold, else accent_user.
composer_mode_accent :: proc(s: ^App_State, th: Theme) -> string {
	_ = s
	if composer_in_plan() {
		if th.accent_plan != "" {
			return th.accent_plan
		}
		return "\x1b[33m"
	}
	if th.user != "" {
		return th.user
	}
	return "\x1b[37m"
}

// composer_border_ansi: plan gold, else neutral prompt_border*.
composer_border_ansi :: proc(focused: bool, th: Theme, accent: string = "") -> string {
	_ = accent
	if composer_in_plan() {
		if th.accent_plan != "" {
			return th.accent_plan
		}
		return "\x1b[33m"
	}
	if focused {
		if th.prompt_border_active != "" {
			return th.prompt_border_active
		}
		if th.user != "" {
			return th.user
		}
		return "\x1b[90m"
	}
	if th.prompt_border != "" {
		return th.prompt_border
	}
	if th.dim != "" {
		return th.dim
	}
	return "\x1b[2m"
}

// composer_flag_ansi: color for the mode token on the bottom info rail only.
// Each mode is visually distinct (user request); palette leans on Grok accents.
//   plan            → accent_plan (gold)
//   always-approve  → tool / warm yellow (warning)
//   auto            → accent_system (blue)
//   ask             → user accent
//   read-only       → dim / muted
composer_flag_ansi :: proc(s: ^App_State, th: Theme) -> string {
	// Any plan lifecycle state (Pending/Active/Exit_Pending)
	if composer_in_plan() {
		if th.accent_plan != "" {
			return th.accent_plan
		}
		return "\x1b[33m"
	}
	mode := ""
	if s != nil && s.perm != "" {
		mode = s.perm
	}
	switch mode {
	case "always-approve", "yolo":
		// Warning-ish yellow so yolo stands out on the rail
		if th.tool != "" {
			return th.tool
		}
		return "\x1b[33m"
	case "auto":
		if th.accent_system != "" {
			return th.accent_system
		}
		if th.user != "" {
			return th.user
		}
		return "\x1b[94m"
	case "read-only":
		if th.dim != "" {
			return th.dim
		}
		return "\x1b[2m"
	case "ask", "":
		if th.user != "" {
			return th.user
		}
		return "\x1b[36m"
	case "plan", "plan…", "plan↓":
		if th.accent_plan != "" {
			return th.accent_plan
		}
		return "\x1b[33m"
	}
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
