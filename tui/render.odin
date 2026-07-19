#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"
import "aether:tools"

// format_context_chip: estimated context window usage for header (B26).
// msgs = session history; live = in-flight assistant draft (streaming).
// Returns " ctx:N%" or " N%" (compact); empty if nothing to show.
format_context_chip :: proc(
	msgs: []agent.Chat_Message,
	live: string,
	compact: bool,
) -> string {
	chars := agent.estimate_message_chars(msgs)
	chars += len(live)
	if chars <= 0 && len(msgs) == 0 {
		return ""
	}
	toks := agent.estimate_tokens(chars)
	win := agent.default_context_window()
	pct := agent.context_usage_pct(toks, win)
	if compact {
		return fmt.tprintf(" %d%%", pct)
	}
	return fmt.tprintf(" ctx:%d%%", pct)
}

// flatten_blocks → display rows for current width (temp allocator strings).
// block_idxs[i] = transcript block index for line i, or -1 for notices/live.
// term_rows: terminal height for welcome art tier (0 = assume 24).
flatten_blocks :: proc(
	s: ^App_State,
	cols: int,
	out: ^[dynamic]string,
	styles: ^[dynamic]Line_Style,
	block_idxs: ^[dynamic]int,
	allocator := context.allocator,
	term_rows: int = 0,
) {
	clear(out)
	clear(styles)
	clear(block_idxs)
	// B8 compact: use full width (pad 1 col only via max(8,cols-1) → almost full)
	compact := core.compact_mode_enabled()
	w := max(8, cols - 1) if compact else max(8, cols - 2)
	for n in s.notices {
		pref := "·" if compact else "· "
		wrap_push(out, styles, block_idxs, -1, fmt.tprintf("%s%s", pref, n), .Dim, w, allocator)
	}
	// V1: empty-session welcome art (no transcript blocks, not streaming)
	if len(s.blocks) == 0 && !s.streaming && core.brand_art_enabled() {
		rows_hint := term_rows if term_rows > 0 else 24
		art_lines := core.brand_pick_art(rows_hint, cols)
		for line in art_lines {
			mark_line(out, styles, block_idxs, -1, line, .Dim, allocator)
		}
		if len(art_lines) > 0 {
			tips := core.brand_welcome_tips(context.temp_allocator)
			mark_line(out, styles, block_idxs, -1, tips, .Dim, allocator)
			// blank separator before compose area content
			mark_line(out, styles, block_idxs, -1, "", .Dim, allocator)
		}
	}
	for bi in 0 ..< len(s.blocks) {
		bl := s.blocks[bi]
		ts := format_block_hhmm(bl.time_unix) // B37: optional HH:MM prefix
		switch bl.kind {
		case .User:
			up := ">" if compact else "> "
			wrap_push(out, styles, block_idxs, bi, fmt.tprintf("%s%s%s", ts, up, bl.text), .User, w, allocator)
		case .Assistant:
			// stamp only first line of assistant body
			if ts != "" {
				push_assistant(out, styles, block_idxs, bi, fmt.tprintf("%s%s", ts, bl.text), w, allocator)
			} else {
				push_assistant(out, styles, block_idxs, bi, bl.text, w, allocator)
			}
		case .Tool:
			name := bl.tool_name if bl.tool_name != "" else "tool"
			failed := tool_body_looks_error(bl.text)
			if bl.expanded {
				head: string
				if compact {
					head = fmt.tprintf("%s▾ %s%s", ts, name, " · fail" if failed else "")
				} else if failed {
					head = fmt.tprintf("%s▾ [tool] %s · fail  (e collapse)", ts, name)
				} else {
					head = fmt.tprintf("%s▾ [tool] %s  (e collapse)", ts, name)
				}
				mark_line(out, styles, block_idxs, bi, head, .Tool, allocator)
				lines := strings.split_lines(bl.text, context.temp_allocator)
				n := min(TOOL_EXPAND_MAX_LINES, len(lines))
				ind := " " if compact else "  "
				for i in 0 ..< n {
					wrap_push(out, styles, block_idxs, bi, fmt.tprintf("%s%s", ind, lines[i]), .Dim, w, allocator)
				}
				if len(lines) > n {
					extra := fmt.tprintf(" … +%d", len(lines) - n) if compact else fmt.tprintf("  … +%d lines", len(lines) - n)
					mark_line(out, styles, block_idxs, bi, extra, .Dim, allocator)
				}
			} else {
				preview := tool_preview(tool_result_section(bl.text), 36 if compact else 48)
				line_count := 1 + strings.count(bl.text, "\n")
				line: string
				if compact {
					if failed {
						line = fmt.tprintf("%s▸ %s · fail · %s", ts, name, preview)
					} else if preview == "" || preview == "…" {
						line = fmt.tprintf("%s▸ %s", ts, name)
					} else {
						line = fmt.tprintf("%s▸ %s · %s", ts, name, preview)
					}
				} else if failed {
					line = fmt.tprintf("%s▸ [tool] %s · fail · %s (%d lines)", ts, name, preview, line_count)
				} else if preview == "" || preview == "…" {
					line = fmt.tprintf("%s▸ [tool] %s · (empty) (%d lines)", ts, name, line_count)
				} else {
					line = fmt.tprintf("%s▸ [tool] %s · %s (%d lines)", ts, name, preview, line_count)
				}
				mark_line(out, styles, block_idxs, bi, line, .Tool, allocator)
			}
		}
	}
	if s.streaming {
		live := strings.to_string(s.live_assist)
		if live != "" {
			push_assistant(out, styles, block_idxs, -1, live, w, allocator)
		}
	}
}

mark_line :: proc(
	out: ^[dynamic]string,
	styles: ^[dynamic]Line_Style,
	block_idxs: ^[dynamic]int,
	bi: int,
	text: string,
	style: Line_Style,
	allocator := context.allocator,
) {
	append(out, strings.clone(text, allocator))
	append(styles, style)
	append(block_idxs, bi)
}

// tool_result_section skips leading "args: … ---" header for previews when present.
tool_result_section :: proc(text: string) -> string {
	// body format from rebuild: "args: …\n---\nRESULT"
	if idx := strings.index(text, "\n---\n"); idx >= 0 {
		return strings.trim_left_space(text[idx + 5:])
	}
	// skip pure args-only pending
	if strings.has_prefix(text, "args:") {
		if nl := strings.index_byte(text, '\n'); nl >= 0 {
			rest := strings.trim_left_space(text[nl + 1:])
			if rest != "" {
				return rest
			}
		}
	}
	return strings.trim_left_space(text)
}

tool_preview :: proc(text: string, max_runes: int) -> string {
	// first non-empty line
	rest := text
	first := ""
	for len(rest) > 0 {
		line: string
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			line = rest
			rest = ""
		}
		line = strings.trim_space(line)
		if line != "" {
			first = line
			break
		}
	}
	if first == "" {
		return "…"
	}
	// collapse runs of spaces for one-line preview
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	prev_space := false
	count := 0
	for r in first {
		if r == ' ' || r == '\t' {
			if prev_space {
				continue
			}
			prev_space = true
			strings.write_rune(&b, ' ')
			count += 1
		} else {
			prev_space = false
			strings.write_rune(&b, r)
			count += 1
		}
		if count >= max_runes {
			strings.write_string(&b, "…")
			break
		}
	}
	return strings.to_string(b)
}

// tool_body_looks_error true when the tool result (not args) uses error: convention.
tool_body_looks_error :: proc(body: string) -> bool {
	r := strings.trim_space(tool_result_section(body))
	return strings.has_prefix(r, "error:") || strings.has_prefix(r, "Error:")
}

wrap_push :: proc(
	out: ^[dynamic]string,
	styles: ^[dynamic]Line_Style,
	block_idxs: ^[dynamic]int,
	bi: int,
	text: string,
	style: Line_Style,
	width: int,
	allocator := context.allocator,
) {
	if len(text) == 0 {
		append(out, strings.clone("", allocator))
		append(styles, style)
		append(block_idxs, bi)
		return
	}
	start := 0
	for start < len(text) {
		// hard break on newline
		nl := -1
		limit := min(start + width * 4, len(text)) // byte scan upper bound
		for i in start ..< limit {
			if text[i] == '\n' {
				nl = i
				break
			}
		}
		end: int
		if nl >= 0 {
			end = nl
		} else {
			// take up to `width` display runes
			end = start
			cols := 0
			for end < len(text) && cols < width {
				if text[end] == '\n' {
					break
				}
				_, sz := utf8.decode_rune(text[end:])
				if sz <= 0 {
					sz = 1
				}
				end += sz
				cols += 1
			}
			if end < len(text) && text[end] != '\n' {
				// prefer word boundary
				sp := end
				for sp > start && text[sp - 1] != ' ' {
					sp -= 1
				}
				if sp > start + width / 4 {
					end = sp
				}
			}
		}
		append(out, strings.clone(text[start:end], allocator))
		append(styles, style)
		append(block_idxs, bi)
		if nl >= 0 {
			start = nl + 1
		} else {
			start = end
			for start < len(text) && text[start] == ' ' {
				start += 1
			}
			if start == end && start < len(text) {
				// no progress (very long token) — force advance one rune
				_, size := utf8.decode_rune(text[start:])
				start += max(1, size)
			}
		}
	}
}

push_assistant :: proc(
	out: ^[dynamic]string,
	styles: ^[dynamic]Line_Style,
	block_idxs: ^[dynamic]int,
	bi: int,
	text: string,
	width: int,
	allocator := context.allocator,
) {
	// fence split
	parts := strings.split(text, "```", context.temp_allocator)
	for pi in 0 ..< len(parts) {
		part := parts[pi]
		if pi % 2 == 1 {
			// C1.3: language-tagged fences (mermaid, rust, …)
			body_start, lang := fence_body_start_and_lang(part)
			// M8: mermaid → Unicode box-drawing layout when enabled
			if is_mermaid_lang(lang) {
				// body is after language tag; when tag is flowchart/sequence the
				// tag itself is the diagram header — rejoin as source.
				body: string
				if lang == "mermaid" || lang == "mmd" {
					body = part[body_start:] if body_start <= len(part) else part
				} else {
					// e.g. ```flowchart\nA-->B  → "flowchart\nA-->B"
					body = part
				}
				art, aok := try_render_mermaid(body, width, context.temp_allocator)
				if aok && len(art) > 0 {
					for line in art {
						mark_line(out, styles, block_idxs, bi, line, .Code, allocator)
					}
					continue
				}
			}
			head := fence_header_line(lang, context.temp_allocator)
			foot := fence_footer_line(lang, context.temp_allocator)
			mark_line(out, styles, block_idxs, bi, head, .Code, allocator)
			// body from body_start
			if body_start < len(part) {
				wrap_push(out, styles, block_idxs, bi, part[body_start:], .Code, width, allocator)
			}
			mark_line(out, styles, block_idxs, bi, foot, .Code, allocator)
		} else if part != "" {
			// C1.2: GFM pipe tables + prose wrap
			push_markdown_prose(out, styles, block_idxs, bi, part, width, allocator)
		}
	}
}

render :: proc(term: ^Term_State, s: ^App_State) {
	term_update_size(term)
	rows := max(6, term.rows)
	cols := max(20, term.cols)
	s.last_cols = cols

	input_h := input_line_count(s, cols)
	// header + status + input
	body_h := rows - 2 - input_h
	if body_h < 1 {
		body_h = 1
	}

	lines := make([dynamic]string, 0, 128, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 128, context.temp_allocator)
	block_idxs := make([dynamic]int, 0, 128, context.temp_allocator)
	flatten_blocks(s, cols, &lines, &styles, &block_idxs, context.temp_allocator, rows)

	total := len(lines)
	max_scroll := max(0, total - body_h)
	if s.scroll > max_scroll {
		s.scroll = max_scroll
	}
	// Keep selected block visible when scrollback-focused
	modal_open := s.picker.active || s.model_picker.active || s.ask_active
	if s.focus == .Scrollback && s.selected_block >= 0 && !modal_open {
		ensure_block_visible(s, block_idxs[:], body_h, total)
	}
	start := max(0, total - body_h - s.scroll)
	end := min(total, start + body_h)

	b := strings.builder_make(context.temp_allocator)
	// full clear + home once per frame (reliable; alt screen)
	strings.write_string(&b, "\x1b[H\x1b[J")

	// row 1 header
	focus_tag := "prompt" if s.focus == .Prompt else "scroll"
	sess_part := s.session_id
	if s.session_title != "" {
		// short title for chrome
		t := s.session_title
		if len(t) > 28 {
			t = fmt.tprintf("%s…", t[:27])
		}
		sess_part = fmt.tprintf("%s · %s", s.session_id, t)
	}
	plan_chip := agent.plan_mode_chip()
	todo_chip := ""
	if n := tools.todo_open_count(); n > 0 {
		todo_chip = fmt.tprintf(" todos:%d", n)
	}
	goal_chip := agent.goal_chip()
	compact := core.compact_mode_enabled()
	// B26: live context usage chip (session msgs + streaming draft)
	ctx_chip := ""
	if g_sess != nil {
		live := ""
		if s.streaming {
			live = strings.to_string(s.live_assist)
		}
		ctx_chip = format_context_chip(g_sess.msgs[:], live, compact)
	}
	header: string
	if compact {
		// denser chrome (B8)
		header = fmt.tprintf(
			"aether %s %s%s%s%s [%s]%s",
			s.model,
			s.perm,
			plan_chip,
			todo_chip,
			ctx_chip,
			focus_tag,
			" ·c" if compact else "",
		)
	} else {
		header = fmt.tprintf(
			" aether  %s  sess=%s  %s%s%s%s%s  [%s]",
			s.model,
			sess_part,
			s.perm,
			plan_chip,
			todo_chip,
			goal_chip,
			ctx_chip,
			focus_tag,
		)
	}
	write_row(&b, header, cols, .Bar_Reverse, true)

	// body rows (or modal overlays)
	if s.ask_active {
		write_ask_body(&b, s, cols, body_h)
	} else if s.picker.active {
		write_picker_body(&b, &s.picker, cols, body_h)
	} else if s.model_picker.active {
		write_model_picker_body(&b, &s.model_picker, cols, body_h)
	} else {
		painted := 0
		for i in start ..< end {
			sel := s.focus == .Scrollback &&
				s.selected_block >= 0 &&
				i < len(block_idxs) &&
				block_idxs[i] == s.selected_block
			if sel {
				// reverse highlight selected block lines
				write_row(&b, fmt.tprintf("›%s", lines[i]), cols, .Bar_Reverse, true)
			} else {
				write_row_content(&b, lines[i], styles[i], cols, true)
			}
			painted += 1
		}
		for painted < body_h {
			write_row(&b, "", cols, .Normal, true)
			painted += 1
		}
	}

	// status — hints match Grok Build prompt bindings
	st := s.status if s.status != "" else "ready"
	scroll_info := ""
	if max_scroll > 0 && !modal_open {
		scroll_info = fmt.tprintf("  [%d/%d]", total - s.scroll, total)
	}
	status: string
	if s.ask_active {
		// Question freeform / multi / single select vs tool approve (y/n/a/d)
		if strings.contains(s.ask_summary, "Other>") {
			status = fmt.tprintf(" %s  | type · Enter submit · Esc = Other", st)
		} else if strings.contains(s.ask_summary, "digit toggle") {
			status = fmt.tprintf(" %s  | digit toggle · Enter submit · Esc cancel", st)
		} else if strings.contains(s.ask_summary, "1-9 select") {
			status = fmt.tprintf(" %s  | digit select · Esc cancel", st)
		} else {
			status = fmt.tprintf(" %s  | y allow · n deny · a always · d never", st)
		}
	} else if s.picker.active {
		status = fmt.tprintf(
			" %s  | Enter load · Esc close · type filter · ↑↓",
			st,
		)
	} else if s.model_picker.active {
		status = fmt.tprintf(
			" %s  | Enter apply · Esc close · type filter · ↑↓",
			st,
		)
	} else if s.search.active {
		// status already set by search_set_status
		status = fmt.tprintf(" %s  | n/N next · Esc close", st)
	} else if s.focus == .Scrollback {
		status = fmt.tprintf(
			" %s%s  | ↑↓ select · y copy · Ctrl+F find · Tab",
			st,
			scroll_info,
		)
	} else if s.multiline_mode {
		if compact {
			status = fmt.tprintf(" %s%s | S-Enter · Tab · Q", st, scroll_info)
		} else {
			status = fmt.tprintf(
				" %s%s  | S-Enter send · Ctrl+F find · Tab · Ctrl+Q",
				st,
				scroll_info,
			)
		}
	} else {
		if compact {
			status = fmt.tprintf(" %s%s | Enter · Tab · Q", st, scroll_info)
		} else {
			status = fmt.tprintf(
				" %s%s  | Enter send · Ctrl+F find · Tab · Ctrl+Q",
				st,
				scroll_info,
			)
		}
	}
	write_row(&b, status, cols, .Bar_Dim, true)

	// input region + cursor (may omit trailing NL on last line to avoid scroll)
	write_input(&b, s, cols, input_h, rows)

	fmt.print(strings.to_string(b))
}

Row_Style :: enum {
	Normal,
	Bar_Reverse,
	Bar_Dim,
}

write_row :: proc(b: ^strings.Builder, text: string, cols: int, style: Row_Style, with_nl: bool) {
	th := active_theme()
	switch style {
	case .Bar_Reverse:
		if th.bar_reverse != "" {
			strings.write_string(b, th.bar_reverse)
		}
	case .Bar_Dim:
		if th.bar_dim != "" {
			strings.write_string(b, th.bar_dim)
		}
	case .Normal:
	}
	n := write_fit(b, text, cols)
	for i := n; i < cols; i += 1 {
		strings.write_byte(b, ' ')
	}
	strings.write_string(b, "\x1b[0m")
	if with_nl {
		strings.write_string(b, "\r\n")
	}
}

write_row_content :: proc(b: ^strings.Builder, text: string, style: Line_Style, cols: int, with_nl: bool) {
	on, off := style_ansi(style)
	if on != "" {
		strings.write_string(b, on)
	}
	vis: int
	if style == .Assistant {
		vis = write_md_inline(b, text, cols)
	} else {
		vis = write_fit(b, text, cols)
	}
	if off != "" {
		strings.write_string(b, off)
	} else {
		strings.write_string(b, "\x1b[0m")
	}
	for i := vis; i < cols; i += 1 {
		strings.write_byte(b, ' ')
	}
	if with_nl {
		strings.write_string(b, "\r\n")
	}
}

write_fit :: proc(b: ^strings.Builder, text: string, cols: int) -> int {
	n := 0
	end := 0
	for r in text {
		if n + 1 > cols {
			break
		}
		n += 1
		end += utf8.rune_size(r)
	}
	strings.write_string(b, text[:end])
	return n
}

// write_md_inline lives in markdown.odin (C1.1).

write_input :: proc(b: ^strings.Builder, s: ^App_State, cols: int, input_h: int, screen_rows: int) {
	prefix := "> "
	full_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&full_b, prefix)
	strings.write_string(&full_b, input_text(s))
	full := strings.to_string(full_b)
	// cursor is in input bytes; absolute in full = prefix + cursor
	cur_abs := len(prefix) + s.cursor

	Row :: struct {
		start, end: int, // byte range in full
	}
	rows_v := make([dynamic]Row, 0, 16, context.temp_allocator)
	start := 0
	for start <= len(full) {
		if start == len(full) {
			if len(full) > 0 && full[len(full) - 1] == '\n' {
				append(&rows_v, Row{start = start, end = start})
			} else if len(rows_v) == 0 {
				append(&rows_v, Row{start = 0, end = 0})
			}
			break
		}
		end := start
		col := 0
		for end < len(full) && col < cols {
			if full[end] == '\n' {
				break
			}
			_, sz := utf8.decode_rune(full[end:])
			if sz <= 0 {
				sz = 1
			}
			end += sz
			col += 1
		}
		append(&rows_v, Row{start = start, end = end})
		if end < len(full) && full[end] == '\n' {
			start = end + 1
		} else if end >= len(full) {
			break
		} else {
			start = end
		}
		if len(rows_v) > 64 {
			break
		}
	}
	if len(rows_v) == 0 {
		append(&rows_v, Row{start = 0, end = 0})
	}

	// which visual row holds the cursor
	cur_row := 0
	cur_col := 0
	for i in 0 ..< len(rows_v) {
		r := rows_v[i]
		if cur_abs >= r.start && cur_abs <= r.end {
			cur_row = i
			cur_col = utf8.rune_count(full[r.start:min(cur_abs, r.end)])
			break
		}
		if cur_abs > r.end {
			cur_row = i
			cur_col = utf8.rune_count(full[r.start:r.end])
		}
	}

	from := max(0, len(rows_v) - input_h)
	for hi in 0 ..< input_h {
		ri := from + hi
		line := ""
		if ri < len(rows_v) {
			r := rows_v[ri]
			line = full[r.start:r.end]
		}
		is_last := hi == input_h - 1
		strings.write_string(b, "\x1b[1m")
		n := write_fit(b, line, cols)
		strings.write_string(b, "\x1b[0m")
		for i := n; i < cols; i += 1 {
			strings.write_byte(b, ' ')
		}
		// omit trailing NL on last screen row to avoid scroll off alt-screen bottom
		if !is_last {
			strings.write_string(b, "\r\n")
		}
	}

	vis_row := cur_row - from
	if vis_row < 0 {
		vis_row = 0
	}
	if vis_row >= input_h {
		vis_row = input_h - 1
	}
	// 1-based absolute screen row for CUP
	abs_row := screen_rows - input_h + vis_row + 1
	abs_col := min(cols, cur_col + 1)
	strings.write_string(b, fmt.tprintf("\x1b[%d;%dH\x1b[?25h", abs_row, abs_col))
}

// ensure_block_visible adjusts s.scroll so selected_block's first line is in view.
ensure_block_visible :: proc(s: ^App_State, block_idxs: []int, body_h, total: int) {
	// find first line of selected block
	first := -1
	last := -1
	for i in 0 ..< len(block_idxs) {
		if block_idxs[i] == s.selected_block {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		return
	}
	// visible window is [start, start+body_h) where start = total - body_h - scroll
	start := max(0, total - body_h - s.scroll)
	end := min(total, start + body_h)
	if first < start {
		// need more scroll (show older content higher)
		// start' = first → scroll' = total - body_h - first
		s.scroll = max(0, total - body_h - first)
	} else if last >= end {
		// scroll down toward bottom (decrease scroll)
		// end' = last+1 → start' = last+1-body_h → scroll = total - body_h - start'
		new_start := max(0, last + 1 - body_h)
		s.scroll = max(0, total - body_h - new_start)
	}
}

// write_ask_body paints mid-turn tool approval / plan-exit / ask_user modals.
write_ask_body :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	is_freeform := strings.contains(s.ask_summary, "Other>")
	is_multi := strings.contains(s.ask_summary, "digit toggle")
	is_question :=
		is_freeform || is_multi || strings.contains(s.ask_summary, "1-9 select")
	title := " allow tool?"
	footer := " y/Enter allow · n/Esc deny · a always · d never"
	if s.ask_name == "exit_plan_mode" {
		title = " exit plan mode?"
		footer = " y approve · n revise · a abandon · Esc cancel"
	} else if s.ask_name == "enter_plan_mode" {
		title = " enter plan mode?"
		footer = " y/Enter allow · n/Esc decline"
	} else if is_freeform {
		title = " freeform answer"
		footer = " Enter submit · Esc = Other · Ctrl+C cancel"
	} else if is_multi {
		q := s.ask_name if s.ask_name != "" else "question"
		title = fmt.tprintf(" %s", q)
		footer = " digit toggle · Enter submit · Esc cancel"
	} else if is_question {
		// ask_name holds the question text
		q := s.ask_name if s.ask_name != "" else "question"
		title = fmt.tprintf(" %s", q)
		footer = " 1-9 select · Esc cancel"
	}
	write_row(b, title, cols, .Bar_Reverse, true)
	list_h := body_h - 2
	if list_h < 1 {
		list_h = 1
	}
	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	if !is_question {
		append(&lines, fmt.tprintf("  tool: %s", s.ask_name))
	}
	// wrap summary roughly (newline-aware for multi-line option lists)
	sum := s.ask_summary
	w := max(8, cols - 4)
	for len(sum) > 0 && len(lines) < list_h {
		// prefer splitting on newline so option rows stay intact
		nl := strings.index_byte(sum, '\n')
		chunk: string
		rest: string
		if nl >= 0 && nl <= w {
			chunk = sum[:nl]
			rest = sum[nl + 1:]
		} else if len(sum) <= w {
			chunk = sum
			rest = ""
		} else {
			chunk = sum[:w]
			rest = sum[w:]
		}
		append(&lines, fmt.tprintf("  %s", chunk))
		sum = rest
	}
	painted := 0
	for i in 0 ..< len(lines) {
		if painted >= list_h {
			break
		}
		write_row(b, lines[i], cols, .Normal, true)
		painted += 1
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(b, footer, cols, .Bar_Dim, true)
}

// write_model_picker_body paints the Ctrl+M model list.
write_model_picker_body :: proc(b: ^strings.Builder, p: ^Model_Picker, cols: int, body_h: int) {
	filt := model_picker_filter_text(p)
	title := " models"
	if filt != "" {
		title = fmt.tprintf(" models  filter:%s", filt)
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
			id := p.entries[ei]
			mark := " " if id != p.current else "*"
			sel := vi == p.selected
			line := fmt.tprintf("%s%s %s", "›" if sel else " ", mark, id)
			if sel {
				write_row(b, line, cols, .Bar_Reverse, true)
			} else {
				write_row(b, line, cols, .Normal, true)
			}
			painted += 1
		}
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	foot := fmt.tprintf(" %d models · * = current · Enter apply · Esc close", len(p.visible))
	write_row(b, foot, cols, .Bar_Dim, true)
}

// write_picker_body paints the Ctrl+S session list into the body region.
write_picker_body :: proc(b: ^strings.Builder, p: ^Session_Picker, cols: int, body_h: int) {
	// title
	filt := picker_filter_text(p)
	title := " sessions"
	if filt != "" {
		title = fmt.tprintf(" sessions  filter:%s", filt)
	}
	write_row(b, title, cols, .Bar_Reverse, true)
	list_h := body_h - 2 // title + footer
	if list_h < 1 {
		list_h = 1
	}

	// clamp scroll so selected is in view
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
		msg := "(no saved sessions)" if len(p.entries) == 0 else "(no matches)"
		write_row(b, fmt.tprintf("  %s", msg), cols, .Bar_Dim, true)
		painted = 1
	} else {
		for vi := p.scroll; vi < len(p.visible) && painted < list_h; vi += 1 {
			ei := p.visible[vi]
			e := p.entries[ei]
			label := picker_row_label(e, cols - 2)
			selected := vi == p.selected
			line := fmt.tprintf("%s %s", "›" if selected else " ", label)
			if selected {
				write_row(b, line, cols, .Bar_Reverse, true)
			} else {
				write_row(b, line, cols, .Normal, true)
			}
			painted += 1
		}
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	// footer
	n := len(p.visible)
	foot := fmt.tprintf(" %d shown · Enter load · Esc close", n)
	write_row(b, foot, cols, .Bar_Dim, true)
}

style_ansi :: proc(style: Line_Style) -> (on, off: string) {
	th := active_theme()
	// monochrome / NO_COLOR: empty on, still reset off when needed
	switch style {
	case .User:
		return th.user, "\x1b[0m" if th.user != "" else ""
	case .Assistant:
		return th.assistant, "\x1b[0m" if th.assistant != "" else ""
	case .Tool:
		return th.tool, "\x1b[0m" if th.tool != "" else ""
	case .Dim, .Status:
		return th.dim, "\x1b[0m" if th.dim != "" else ""
	case .Code:
		return th.code, "\x1b[0m" if th.code != "" else ""
	case .Bold:
		return th.bold, "\x1b[0m" if th.bold != "" else ""
	case .Normal:
		return "", ""
	}
	return "", ""
}
