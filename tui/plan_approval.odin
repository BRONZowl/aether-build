// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "aether:agent"

// Grok plan approval surface (exit_plan_mode).
// Reference: crates/codegen/xai-grok-pager/src/views/plan_approval_view.rs
// Keys: a approve · s request changes · q quit · c comment · Tab preview↔prompt

// EMPTY_PLAN_PLACEHOLDER — Grok empty-body text when plan.md is missing/blank.
EMPTY_PLAN_PLACEHOLDER :: `# No plan written yet

The agent exited plan mode without writing a plan.

- **Approve** — leave plan mode and start implementing
- **Request changes** — send the agent back to planning
- **Quit** — abandon and turn plan mode off
`

Plan_Approval_Focus :: enum {
	Preview,
	Prompt,
	Commenting,
}

Plan_Comment :: struct {
	id:         u64,
	line_start: int, // 1-based inclusive
	line_end:   int, // 1-based exclusive (Grok Range end)
	text:       string, // owned
}

// Plan_Approval_View: fullscreen review while exit_plan_mode is parked,
// or read-only /view-plan preview (readonly=true).
Plan_Approval_View :: struct {
	active:         bool,
	readonly:       bool, // /view-plan: scroll only; q/Esc close
	focus:          Plan_Approval_Focus,
	plan_path:      string, // owned
	plan_body:      string, // owned display body (file or placeholder)
	has_plan:       bool,
	scroll:         int, // first visible line index into display lines
	sel_line:       int, // 0-based index into display lines
	comments:       [dynamic]Plan_Comment,
	next_comment_id: u64,
	feedback:       [dynamic]u8, // prompt buffer
	feedback_cursor: int,
	comment_buf:    [dynamic]u8,
	comment_cursor: int,
}

plan_approval_init :: proc(p: ^Plan_Approval_View) {
	p^ = {}
	p.comments = make([dynamic]Plan_Comment, 0, 4)
	p.feedback = make([dynamic]u8, 0, 64)
	p.comment_buf = make([dynamic]u8, 0, 64)
}

plan_approval_destroy :: proc(p: ^Plan_Approval_View) {
	plan_approval_clear(p)
	delete(p.comments)
	delete(p.feedback)
	delete(p.comment_buf)
}

plan_approval_clear :: proc(p: ^Plan_Approval_View) {
	delete(p.plan_path)
	delete(p.plan_body)
	p.plan_path = ""
	p.plan_body = ""
	for c in p.comments {
		delete(c.text)
	}
	clear(&p.comments)
	clear(&p.feedback)
	clear(&p.comment_buf)
	p.active = false
	p.readonly = false
	p.focus = .Preview
	p.has_plan = false
	p.scroll = 0
	p.sel_line = 0
	p.feedback_cursor = 0
	p.comment_cursor = 0
	p.next_comment_id = 0
}

// plan_approval_status_label matches Grok plan_approval_status_label.
// When readonly, labels are for /view-plan (not exit approval).
plan_approval_status_label :: proc(has_plan: bool, readonly := false) -> string {
	if readonly {
		if has_plan {
			return "Plan preview"
		}
		return "No plan written yet"
	}
	if has_plan {
		return "Waiting on plan approval"
	}
	return "No plan written — approve or request changes"
}

// plan_approval_load_body: read plan file; empty → placeholder.
plan_approval_load_body :: proc(
	plan_path: string,
	allocator := context.allocator,
) -> (
	body: string,
	has_plan: bool,
) {
	if plan_path != "" {
		if data, err := os.read_entire_file(plan_path, context.temp_allocator); err == nil {
			text := strings.trim_space(string(data))
			if text != "" {
				return strings.clone(string(data), allocator), true
			}
		}
	}
	return strings.clone(EMPTY_PLAN_PLACEHOLDER, allocator), false
}

// plan_approval_open fills view for a parked exit_plan_mode (or /view-plan).
plan_approval_open :: proc(p: ^Plan_Approval_View, plan_path: string, readonly := false) {
	plan_approval_clear(p)
	p.plan_path = strings.clone(plan_path)
	body, has := plan_approval_load_body(plan_path)
	p.plan_body = body
	p.has_plan = has
	p.active = true
	p.readonly = readonly
	p.focus = .Preview
	p.scroll = 0
	p.sel_line = 0
}

// plan_body_lines splits plan body into display lines (temp).
plan_body_lines :: proc(body: string, allocator := context.temp_allocator) -> []string {
	if body == "" {
		return {}
	}
	// Keep empty lines so line numbers match file.
	parts := strings.split_lines(body, allocator)
	return parts
}

// format_plan_line_comment — Grok inline / file-backed style (file-backed path).
format_plan_line_comment :: proc(c: Plan_Comment, allocator := context.allocator) -> string {
	if c.line_end <= c.line_start + 1 {
		return fmt.aprintf("@plan.md:%d\n%s", c.line_start, c.text, allocator = allocator)
	}
	return fmt.aprintf(
		"@plan.md:%d-%d\n%s",
		c.line_start,
		c.line_end - 1,
		c.text,
		allocator = allocator,
	)
}

// plan_approval_format_feedback joins comments + freeform (Grok format_feedback).
plan_approval_format_feedback :: proc(
	p: ^Plan_Approval_View,
	freeform: string,
	allocator := context.allocator,
) -> string {
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	for c in p.comments {
		append(&parts, format_plan_line_comment(c, context.temp_allocator))
	}
	fb := strings.trim_space(freeform)
	if fb != "" {
		if len(p.comments) > 0 {
			append(&parts, fmt.tprintf("Additional feedback:\n%s", fb))
		} else {
			append(&parts, fb)
		}
	}
	if len(parts) == 0 {
		return strings.clone("", allocator)
	}
	return strings.join(parts[:], "\n\n", allocator)
}

// plan_approval_action_bar_label — bottom controls strip.
plan_approval_action_bar_label :: proc(p: ^Plan_Approval_View) -> string {
	if p.readonly {
		return " q/Esc close · j/k · ↑/↓ · PgUp/Dn scroll"
	}
	if len(p.comments) > 0 {
		return " a approve w/ comments · s request changes · c comment · q quit · Tab prompt"
	}
	return " a approve · s request changes · c comment · q quit · Tab prompt"
}

// write_plan_approval_body paints Grok-shaped review layout into the body region.
write_plan_approval_body :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	p := &s.plan_approval
	// Header status line inside body
	label := plan_approval_status_label(p.has_plan, p.readonly)
	path_note := p.plan_path if p.plan_path != "" else ".grok/plan.md"
	write_row(b, fmt.tprintf(" %s", label), cols, .Bar_Reverse, true)
	write_row(b, fmt.tprintf(" %s", path_note), cols, .Bar_Dim, true)

	// Reserve: 2 header + 1 action bar + optional feedback (2) + optional comment (1)
	// Read-only view never shows feedback/comment footers.
	footer_h := 1
	if !p.readonly {
		if p.focus == .Prompt {
			footer_h = 3
		} else if p.focus == .Commenting {
			footer_h = 2
		}
	}
	list_h := body_h - 2 - footer_h
	if list_h < 1 {
		list_h = 1
	}

	lines := plan_body_lines(p.plan_body)
	n := len(lines)
	if p.sel_line < 0 {
		p.sel_line = 0
	}
	if n > 0 && p.sel_line >= n {
		p.sel_line = n - 1
	}
	// Keep selection visible
	if p.sel_line < p.scroll {
		p.scroll = p.sel_line
	}
	if p.sel_line >= p.scroll + list_h {
		p.scroll = p.sel_line - list_h + 1
	}
	if p.scroll < 0 {
		p.scroll = 0
	}
	max_scroll := max(0, n - list_h)
	if p.scroll > max_scroll {
		p.scroll = max_scroll
	}

	painted := 0
	for i in p.scroll ..< min(n, p.scroll + list_h) {
		line := lines[i]
		// Comment markers for this line (1-based file line = i+1)
		mark := " "
		for c in p.comments {
			if c.line_start <= i + 1 && i + 1 < c.line_end {
				mark = "·"
				break
			}
		}
		prefix := " "
		style: Row_Style = .Normal
		if i == p.sel_line && p.focus == .Preview {
			prefix = "›"
			style = .Bar_Reverse
		}
		// Cap display width
		row := fmt.tprintf("%s%s%s", prefix, mark, line)
		write_row(b, row, cols, style, true)
		painted += 1
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}

	// Action bar
	write_row(b, plan_approval_action_bar_label(p), cols, .Bar_Dim, true)

	if !p.readonly {
		if p.focus == .Prompt {
			fb := string(p.feedback[:])
			write_row(b, " request changes — Enter send · Esc back", cols, .Bar_Dim, true)
			write_row(b, fmt.tprintf(" ›%s█", fb), cols, .Bar_Reverse, true)
		} else if p.focus == .Commenting {
			cb := string(p.comment_buf[:])
			write_row(
				b,
				fmt.tprintf(" comment line %d — Enter save · Esc cancel ›%s█", p.sel_line + 1, cb),
				cols,
				.Bar_Reverse,
				true,
			)
		}
	}
}

// --- input helpers for feedback / comment buffers ---

plan_approval_buf_insert :: proc(buf: ^[dynamic]u8, cursor: ^int, r: rune) {
	if r < 32 && r != '\t' {
		return
	}
	tmp, n := utf8.encode_rune(r)
	inject_at(buf, cursor^, ..tmp[:n])
	cursor^ += n
}

plan_approval_buf_backspace :: proc(buf: ^[dynamic]u8, cursor: ^int) {
	if cursor^ <= 0 || len(buf) == 0 {
		return
	}
	// delete one UTF-8 rune before cursor
	i := cursor^ - 1
	for i > 0 && (buf[i] & 0xc0) == 0x80 {
		i -= 1
	}
	ordered_remove_range(buf, i, cursor^)
	cursor^ = i
}

// tui_run_plan_approval: nested key loop; returns Grok outcomes.
tui_run_plan_approval :: proc(plan_path: string) -> agent.Plan_Exit_Result {
	st := stream_st()
	term := stream_term()
	res := agent.Plan_Exit_Result {
		outcome = .Cancelled,
	}
	if st == nil || term == nil {
		return agent.default_plan_exit_ask(plan_path, "")
	}

	p := &st.plan_approval
	plan_approval_open(p, plan_path, false)
	// Also set ask_active so mid-turn chrome treats us as modal (spinner hide).
	st.ask_active = true
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = strings.clone("exit_plan_mode")
	st.ask_summary = strings.clone(plan_approval_status_label(p.has_plan, false))
	state_set_status(st, plan_approval_status_label(p.has_plan, false))
	render(term, st)

	done := false
	for !done {
		key := read_key()
		#partial switch p.focus {
		case .Preview:
			#partial switch key.kind {
			case .Char:
				switch key.ch {
				case 'a', 'A':
					res.outcome = .Approved
					// Attach comments as feedback alongside approval (Grok approve w/ comments)
					if len(p.comments) > 0 {
						res.feedback = plan_approval_format_feedback(p, "", context.temp_allocator)
					}
					done = true
				case 'q', 'Q':
					res.outcome = .Abandoned
					done = true
				case 's', 'S':
					p.focus = .Prompt
					state_set_status(st, "request changes — type feedback")
				case 'c', 'C':
					p.focus = .Commenting
					clear(&p.comment_buf)
					p.comment_cursor = 0
					state_set_status(st, "comment on selected line")
				case 'j', 'J':
					plan_approval_move_sel(p, 1)
				case 'k', 'K':
					plan_approval_move_sel(p, -1)
				case:
				}
			case .Down:
				plan_approval_move_sel(p, 1)
			case .Up:
				plan_approval_move_sel(p, -1)
			case .PgDn:
				plan_approval_move_sel(p, 10)
			case .PgUp:
				plan_approval_move_sel(p, -10)
			case .Home:
				p.sel_line = 0
			case .End:
				lines := plan_body_lines(p.plan_body)
				if len(lines) > 0 {
					p.sel_line = len(lines) - 1
				}
			case .Tab:
				p.focus = .Prompt
				state_set_status(st, "request changes — type feedback")
			case .Enter:
				// Enter on line → comment (Grok)
				p.focus = .Commenting
				clear(&p.comment_buf)
				p.comment_cursor = 0
			case .Esc:
				// Grok: Esc does not abandon from Preview
			case .Ctrl_C:
				// Soft cancel → revise without feedback (stay in plan mode)
				res.outcome = .Cancelled
				done = true
			case:
			}
		case .Prompt:
			#partial switch key.kind {
			case .Char:
				if key.ch == 'q' || key.ch == 'Q' {
					// Quit plan still works from prompt focus (Grok)
					res.outcome = .Abandoned
					done = true
				} else {
					// Type feedback; 'a'/'s' are literal characters while composing
					plan_approval_buf_insert(&p.feedback, &p.feedback_cursor, key.ch)
				}
			case .Backspace:
				plan_approval_buf_backspace(&p.feedback, &p.feedback_cursor)
			case .Enter:
				fb := string(p.feedback[:])
				res.outcome = .Cancelled
				res.feedback = plan_approval_format_feedback(p, fb, context.temp_allocator)
				done = true
			case .Esc, .Tab:
				p.focus = .Preview
				state_set_status(st, plan_approval_status_label(p.has_plan))
			case .Ctrl_C:
				res.outcome = .Cancelled
				done = true
			case:
			}
		case .Commenting:
			#partial switch key.kind {
			case .Char:
				plan_approval_buf_insert(&p.comment_buf, &p.comment_cursor, key.ch)
			case .Backspace:
				plan_approval_buf_backspace(&p.comment_buf, &p.comment_cursor)
			case .Enter:
				txt := strings.trim_space(string(p.comment_buf[:]))
				if txt != "" {
					ln := p.sel_line + 1
					append(
						&p.comments,
						Plan_Comment {
							id         = p.next_comment_id,
							line_start = ln,
							line_end   = ln + 1,
							text       = strings.clone(txt),
						},
					)
					p.next_comment_id += 1
				}
				clear(&p.comment_buf)
				p.comment_cursor = 0
				p.focus = .Preview
				state_set_status(st, plan_approval_status_label(p.has_plan))
			case .Esc:
				clear(&p.comment_buf)
				p.comment_cursor = 0
				p.focus = .Preview
				state_set_status(st, plan_approval_status_label(p.has_plan))
			case .Ctrl_C:
				res.outcome = .Cancelled
				done = true
			case:
			}
		}
		if !done {
			render(term, st)
		}
	}

	// Tear down
	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""
	plan_approval_clear(p)

	switch res.outcome {
	case .Approved:
		state_set_status(st, "plan exit approved")
		if stream_sess() != nil {
			stream_sess().plan_mode = false
		}
	case .Abandoned:
		state_set_status(st, "plan abandoned")
		if stream_sess() != nil {
			stream_sess().plan_mode = false
		}
	case .Cancelled:
		state_set_status(st, "plan revise — still planning")
	}
	render(term, st)
	return res
}

plan_approval_move_sel :: proc(p: ^Plan_Approval_View, delta: int) {
	lines := plan_body_lines(p.plan_body)
	n := len(lines)
	if n == 0 {
		p.sel_line = 0
		return
	}
	p.sel_line = clamp(p.sel_line + delta, 0, n - 1)
}

// tui_run_plan_view: read-only scrollable plan.md preview (/view-plan).
// q / Esc close; no approve/revise/comment. Reuses Plan_Approval_View paint.
tui_run_plan_view :: proc(plan_path: string) {
	st := stream_st()
	term := stream_term()
	if st == nil || term == nil {
		return
	}

	p := &st.plan_approval
	plan_approval_open(p, plan_path, true)
	st.ask_active = true
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = strings.clone("view_plan")
	st.ask_summary = strings.clone(plan_approval_status_label(p.has_plan, true))
	state_set_status(st, plan_approval_status_label(p.has_plan, true))
	render(term, st)

	done := false
	for !done {
		key := read_key()
		#partial switch key.kind {
		case .Char:
			switch key.ch {
			case 'q', 'Q':
				done = true
			case 'j', 'J':
				plan_approval_move_sel(p, 1)
			case 'k', 'K':
				plan_approval_move_sel(p, -1)
			case:
			}
		case .Down:
			plan_approval_move_sel(p, 1)
		case .Up:
			plan_approval_move_sel(p, -1)
		case .PgDn:
			plan_approval_move_sel(p, 10)
		case .PgUp:
			plan_approval_move_sel(p, -10)
		case .Home:
			p.sel_line = 0
		case .End:
			lines := plan_body_lines(p.plan_body)
			if len(lines) > 0 {
				p.sel_line = len(lines) - 1
			}
		case .Esc, .Ctrl_C:
			done = true
		case:
		}
		if !done {
			render(term, st)
		}
	}

	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""
	plan_approval_clear(p)
	state_set_status(st, "ready")
	render(term, st)
}
