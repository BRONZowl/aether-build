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
	// Empty-session welcome is painted by write_welcome_body (Grok stacked/hero
	// layout) — not as scrollable transcript lines.

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
	frame_top, frame_bot := composer_frame_rows(s, cols)
	block_h := frame_top + input_h + frame_bot // full composer block (box + text)
	// Live slash suggestion menu (between body and status); capped to fit terminal
	menu_h := slash_menu_height(s, rows, block_h)
	// header + status + composer block [+ slash menu]
	fixed := chrome_fixed_rows(s) // header + hints status
	body_h := rows - fixed - block_h - menu_h
	if body_h < 1 {
		body_h = 1
	}
	// Re-cap if body clamp pushed total over rows (tiny terminals)
	for body_h + menu_h + fixed + block_h > rows && menu_h > 0 {
		menu_h -= 1
	}
	if body_h + menu_h + fixed + block_h > rows {
		body_h = max(1, rows - fixed - block_h - menu_h)
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

	// row 1 — Grok-shaped top bar: branch · cwd | chips (mode · context · model)
	header := format_top_bar(s, cols)
	write_row(&b, header, cols, .Bar_Dim, true)

	// body rows (or modal overlays / Grok-parity welcome)
	if s.ask_active {
		write_ask_body(&b, s, cols, body_h)
	} else if s.picker.active {
		write_picker_body(&b, &s.picker, cols, body_h)
	} else if s.model_picker.active {
		write_model_picker_body(&b, &s.model_picker, cols, body_h)
	} else if welcome_is_active(s) {
		// Opening layout matches Grok Build: stacked logo+menu or hero box
		write_welcome_body(&b, s, cols, body_h)
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

	// Slash command suggestion popup (live while typing /…)
	if menu_h > 0 {
		write_slash_menu(&b, s, cols, menu_h)
	}

	// status — hints match Grok Build prompt bindings
	st := s.status if s.status != "" else "ready"
	compact := core.compact_mode_enabled()
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
	} else if menu_h > 0 {
		ms := make([dynamic]string, 0, 16, context.temp_allocator)
		_ = slash_menu_matches(s, &ms)
		if compact {
			status = fmt.tprintf(" %s | %d cmds · ↑↓ · Tab", st, len(ms))
		} else {
			status = fmt.tprintf(
				" %s  | %d slash matches · ↑↓ select · Tab accept · Esc clear",
				st,
				len(ms),
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

	// composer block (optional box + text + bottom caption) + cursor
	write_input(&b, s, cols, input_h, frame_top, frame_bot, rows)

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

// write_slash_menu: live autocomplete list for `/` tokens (above status/input).
write_slash_menu :: proc(b: ^strings.Builder, s: ^App_State, cols: int, menu_h: int) {
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	if !slash_menu_matches(s, &ms) || menu_h <= 0 {
		for i := 0; i < menu_h; i += 1 {
			write_row(b, "", cols, .Bar_Dim, true)
		}
		return
	}
	// header
	write_row(b, " slash commands · Tab accept · ↑↓", cols, .Bar_Dim, true)
	shown := menu_h - 1
	if shown > len(ms) {
		shown = len(ms)
	}
	// scroll window so selection is visible
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
	for row := 0; row < shown; row += 1 {
		i := start + row
		if i >= len(ms) {
			write_row(b, "", cols, .Normal, true)
			continue
		}
		line: string
		if i == s.slash_menu_sel {
			line = fmt.tprintf(" › %s", ms[i])
			write_row(b, line, cols, .Bar_Reverse, true)
		} else {
			line = fmt.tprintf("   %s", ms[i])
			write_row(b, line, cols, .Normal, true)
		}
	}
}

// write_input paints the Grok-shaped composer:
//   ╭────────────╮          (optional box top)
//   │  ❯ text…   │
//   ╰─ model · mode ─╯      (optional box bottom with caption)
// Compact / narrow: plain ❯ lines + optional dim info under.
write_input :: proc(
	b: ^strings.Builder,
	s: ^App_State,
	cols: int,
	input_h: int,
	frame_top: int,
	frame_bot: int,
	screen_rows: int,
) {
	use_box := frame_top > 0 && frame_bot > 0
	// Inner content width for text wrapping
	// box: "│ " + content + " │" → content cols-4; first line uses "❯ " (2) inside content
	// plain: full width for "❯ " + text
	inner_w: int
	prefix_cols := 2 // "❯ "
	cont_indent := 2 // spaces under continuation
	if use_box {
		inner_w = max(8, cols - 4) // inside side borders + one pad space each side
	} else {
		inner_w = max(8, cols)
	}
	text_w := max(4, inner_w - prefix_cols) // wrap width for body after prefix

	text := input_text(s)
	show_placeholder := text == "" && s.focus == .Prompt && !s.streaming
	body := text
	if show_placeholder {
		body = "Type a message…"
	}

	// Build display lines: first has ❯ , continuations indented
	disp_lines := make([dynamic]string, 0, 8, context.temp_allocator)
	// Wrap body into text_w columns, then attach prefix/indent
	wrap_body := make([dynamic]string, 0, 8, context.temp_allocator)
	{
		start := 0
		for start <= len(body) {
			if start == len(body) {
				if len(body) > 0 && body[len(body) - 1] == '\n' {
					append(&wrap_body, "")
				} else if len(wrap_body) == 0 {
					append(&wrap_body, "")
				}
				break
			}
			end := start
			col := 0
			for end < len(body) && col < text_w {
				if body[end] == '\n' {
					break
				}
				_, sz := utf8.decode_rune(body[end:])
				if sz <= 0 {
					sz = 1
				}
				end += sz
				col += 1
			}
			append(&wrap_body, body[start:end])
			if end < len(body) && body[end] == '\n' {
				start = end + 1
			} else if end >= len(body) {
				break
			} else {
				start = end
			}
			if len(wrap_body) > 64 {
				break
			}
		}
		if len(wrap_body) == 0 {
			append(&wrap_body, "")
		}
	}
	for i in 0 ..< len(wrap_body) {
		if i == 0 {
			append(&disp_lines, fmt.tprintf("%s%s", INPUT_PREFIX, wrap_body[i]))
		} else {
			// indent continuation under text (same width as prefix)
			ind := "  "
			append(&disp_lines, fmt.tprintf("%s%s", ind, wrap_body[i]))
		}
	}

	// Cursor: byte index in first-line coordinates of "❯ "+text (or indent+text)
	// Map s.cursor within body to display line/col
	cur_row, cur_col := map_cursor_to_display(body, s.cursor, text_w, prefix_cols, cont_indent)
	if show_placeholder {
		cur_row = 0
		cur_col = prefix_cols
	}

	// Theme accents
	th := active_theme()
	focus_on := s.focus == .Prompt
	prefix_ansi := th.user if th.user != "" else th.bold
	if prefix_ansi == "" {
		prefix_ansi = "\x1b[1m"
	}
	border_ansi := th.dim if th.dim != "" else "\x1b[2m"
	if focus_on && th.user != "" {
		border_ansi = th.user
	}

	// --- top border ---
	if frame_top > 0 {
		top := format_composer_top_border(cols)
		strings.write_string(b, border_ansi)
		n := write_fit(b, top, cols)
		strings.write_string(b, "\x1b[0m")
		for i := n; i < cols; i += 1 {
			strings.write_byte(b, ' ')
		}
		strings.write_string(b, "\r\n")
	}

	// --- text rows ---
	from := max(0, len(disp_lines) - input_h)
	for hi in 0 ..< input_h {
		ri := from + hi
		line := ""
		if ri < len(disp_lines) {
			line = disp_lines[ri]
		}
		is_last := hi == input_h - 1 && frame_bot == 0
		row_s: string
		if use_box {
			row_s = format_composer_side_row(line, cols)
		} else {
			row_s = line
		}
		// paint: bold/dim content; keep border dim/accent already in string for box via re-style
		if use_box {
			// rewrite with styled borders: paint row_s with border on │ and content styled
			write_composer_content_row(b, line, cols, show_placeholder, focus_on, th, border_ansi)
		} else {
			if show_placeholder {
				strings.write_string(b, "\x1b[2m")
			} else {
				// accent the chevron on first visible row when it's the logical first line
				if ri == 0 && strings.has_prefix(line, INPUT_PREFIX) {
					strings.write_string(b, prefix_ansi)
					strings.write_string(b, INPUT_PREFIX)
					strings.write_string(b, "\x1b[0m\x1b[1m")
					rest := line[len(INPUT_PREFIX):]
					n := write_fit(b, rest, max(0, cols - prefix_cols))
					strings.write_string(b, "\x1b[0m")
					for i := n + prefix_cols; i < cols; i += 1 {
						strings.write_byte(b, ' ')
					}
					if !is_last {
						strings.write_string(b, "\r\n")
					}
					continue
				}
				strings.write_string(b, "\x1b[1m")
			}
			n := write_fit(b, row_s, cols)
			strings.write_string(b, "\x1b[0m")
			for i := n; i < cols; i += 1 {
				strings.write_byte(b, ' ')
			}
		}
		if !is_last {
			strings.write_string(b, "\r\n")
		}
	}

	// --- bottom border / dim info ---
	if frame_bot > 0 {
		cap := format_composer_info(s)
		if use_box {
			bot := format_composer_bottom_border(cols, cap)
			strings.write_string(b, border_ansi)
			n := write_fit(b, bot, cols)
			strings.write_string(b, "\x1b[0m")
			for i := n; i < cols; i += 1 {
				strings.write_byte(b, ' ')
			}
			// last screen row — no NL
		} else {
			// plain dim info line
			info := fmt.tprintf(" %s", cap)
			write_row(b, info, cols, .Bar_Dim, false)
		}
	}

	// cursor CUP
	vis_row := cur_row - from
	if vis_row < 0 {
		vis_row = 0
	}
	if vis_row >= input_h {
		vis_row = input_h - 1
	}
	// box: content is offset +2 cols ("│ ")
	col_off := 2 if use_box else 0
	abs_row := screen_rows - frame_bot - input_h + vis_row + 1
	abs_col := min(cols - 1, col_off + cur_col + 1)
	if abs_col < 1 {
		abs_col = 1
	}
	strings.write_string(b, fmt.tprintf("\x1b[%d;%dH\x1b[?25h", abs_row, abs_col))
}

// write_composer_content_row paints one boxed line: │  content… │
write_composer_content_row :: proc(
	b: ^strings.Builder,
	content: string,
	cols: int,
	placeholder: bool,
	focused: bool,
	th: Theme,
	border_ansi: string,
) {
	w := max(4, cols)
	inner := w - 2
	strings.write_string(b, border_ansi)
	strings.write_string(b, "│")
	strings.write_string(b, "\x1b[0m")
	// one space pad
	strings.write_byte(b, ' ')
	n := 1
	// style content
	if placeholder {
		strings.write_string(b, "\x1b[2m")
	} else if strings.has_prefix(content, INPUT_PREFIX) {
		// accent chevron (2 display columns)
		acc := th.user if th.user != "" else "\x1b[1m"
		strings.write_string(b, acc)
		strings.write_string(b, INPUT_PREFIX)
		strings.write_string(b, "\x1b[0m\x1b[1m")
		n += 2
		rest := content[len(INPUT_PREFIX):]
		for r in rest {
			if n >= inner {
				break
			}
			strings.write_string(b, fmt.tprintf("%c", r))
			n += 1
		}
		strings.write_string(b, "\x1b[0m")
		for n < inner {
			strings.write_byte(b, ' ')
			n += 1
		}
		strings.write_string(b, border_ansi)
		strings.write_string(b, "│")
		strings.write_string(b, "\x1b[0m")
		return
	} else {
		strings.write_string(b, "\x1b[1m")
	}
	for r in content {
		if n >= inner {
			break
		}
		strings.write_string(b, fmt.tprintf("%c", r))
		n += 1
	}
	strings.write_string(b, "\x1b[0m")
	for n < inner {
		strings.write_byte(b, ' ')
		n += 1
	}
	strings.write_string(b, border_ansi)
	strings.write_string(b, "│")
	strings.write_string(b, "\x1b[0m")
	_ = focused
}

// map_cursor_to_display maps body byte cursor to (row, col) in display lines
// where row 0 has prefix_cols of chevron and later rows have cont_indent.
map_cursor_to_display :: proc(
	body: string,
	cursor: int,
	text_w: int,
	prefix_cols: int,
	cont_indent: int,
) -> (
	row, col: int,
) {
	cur := cursor
	if cur < 0 {
		cur = 0
	}
	if cur > len(body) {
		cur = len(body)
	}
	// Walk same wrap algorithm as write_input
	start := 0
	r := 0
	for start <= len(body) {
		end := start
		c := 0
		for end < len(body) && c < text_w {
			if body[end] == '\n' {
				break
			}
			_, sz := utf8.decode_rune(body[end:])
			if sz <= 0 {
				sz = 1
			}
			if end < cur && end + sz > cur {
				// cursor mid-rune — sit at end
			}
			end += sz
			c += 1
			if end >= cur && start <= cur {
				// cursor in this segment
				// count runes from start to cur
				rn := 0
				p := start
				for p < cur && p < end {
					_, sz2 := utf8.decode_rune(body[p:])
					if sz2 <= 0 {
						sz2 = 1
					}
					p += sz2
					rn += 1
				}
				indent := prefix_cols if r == 0 else cont_indent
				return r, indent + rn
			}
		}
		// segment [start,end)
		if cur >= start && cur <= end {
			rn := 0
			p := start
			for p < cur && p < end {
				_, sz2 := utf8.decode_rune(body[p:])
				if sz2 <= 0 {
					sz2 = 1
				}
				p += sz2
				rn += 1
			}
			indent := prefix_cols if r == 0 else cont_indent
			return r, indent + rn
		}
		if end < len(body) && body[end] == '\n' {
			if cur == end {
				indent := prefix_cols if r == 0 else cont_indent
				return r, indent + c
			}
			start = end + 1
			r += 1
			continue
		}
		if end >= len(body) {
			indent := prefix_cols if r == 0 else cont_indent
			if cur >= end {
				return r, indent + c
			}
			break
		}
		start = end
		r += 1
		if r > 64 {
			break
		}
	}
	return 0, prefix_cols
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
