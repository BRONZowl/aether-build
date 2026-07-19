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

// composer_info_rows: model · mode line under the prompt (0 in compact mode).
composer_info_rows :: proc(s: ^App_State) -> int {
	if core.compact_mode_enabled() {
		return 0
	}
	return 1
}

// chrome_fixed_rows: header + status + composer info (excludes input + slash menu).
chrome_fixed_rows :: proc(s: ^App_State) -> int {
	return 2 + composer_info_rows(s) // header + hints status [+ info]
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

// format_composer_info: dim line under input — "model · mode [· multi]"
format_composer_info :: proc(s: ^App_State) -> string {
	mode := s.perm if s.perm != "" else "ask"
	model := s.model if s.model != "" else "—"
	if s.multiline_mode {
		return fmt.tprintf(" %s · %s · multi", model, mode)
	}
	return fmt.tprintf(" %s · %s", model, mode)
}
