// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
// Package tui — lightweight markdown → ANSI for assistant scrollback (C1.1/C1.2).
// TUI: render Grok-style; headless/NO_COLOR: keep markdown source visible.
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "aether:core"

// md_sgr_bold / md_sgr_dim: theme-aware SGR (fallback to intensity attributes).
// Soft paint only — never reverse video or bright-white.
md_sgr_bold :: proc() -> string {
	th := active_theme()
	if th.bold != "" {
		return th.bold
	}
	return "\x1b[1m"
}

md_sgr_dim :: proc() -> string {
	th := active_theme()
	if th.dim != "" {
		return th.dim
	}
	return "\x1b[2m"
}

// md_restore_prose resets SGR then re-applies assistant base + open spans.
// Needed because theme dim/code may be truecolor fg, not intensity bit 2.
md_restore_prose :: proc(b: ^strings.Builder, th: Theme, in_bold, in_italic, heading: bool) {
	strings.write_string(b, "\x1b[0m")
	if th.assistant != "" {
		strings.write_string(b, th.assistant)
	}
	if in_bold || heading {
		strings.write_string(b, md_sgr_bold())
	}
	if in_italic {
		strings.write_string(b, "\x1b[3m")
	}
}

// write_md_inline paints one logical line with markdown markers into b.
// Returns visible rune count (markers do not count). Caps at cols.
// Supports: `code`, **bold** / __bold__, *italic*, # headers, "- "/"* "/ "N. " lists.
// Soft emphasis only: no reverse video, no bright-white bold. Monochrome
// (NO_COLOR) strips markers with no SGR for readable plain text.
write_md_inline :: proc(b: ^strings.Builder, text: string, cols: int) -> int {
	color := !core.ui_color_disabled()
	if !color {
		// Plain: strip markers, no highlighting
		plain := strip_md_markers(text, context.temp_allocator)
		return write_fit(b, plain, cols)
	}

	th := active_theme()
	bold_on := md_sgr_bold()
	dim_on := md_sgr_dim()

	visible := 0
	i := 0
	in_code := false
	in_bold := false
	in_italic := false
	heading := false

	// Line-prefix: headings / bullets / ordered lists
	if len(text) > 0 {
		h := 0
		for h < len(text) && h < 6 && text[h] == '#' {
			h += 1
		}
		if h > 0 && h < len(text) && text[h] == ' ' {
			// Quiet heading: bold title only (no dim # hashes)
			strings.write_string(b, bold_on)
			in_bold = true
			heading = true
			i = h + 1
		} else if len(text) >= 2 &&
		          (text[0] == '-' || text[0] == '*') &&
		          text[1] == ' ' {
			if visible + 2 <= cols {
				// Dim bullet — theme dim, no cyan flash
				strings.write_string(b, dim_on)
				strings.write_string(b, "•")
				md_restore_prose(b, th, false, false, false)
				strings.write_byte(b, ' ')
				visible += 2
			}
			i = 2
		} else {
			// Ordered list: "1. " / "12. "
			j := 0
			for j < len(text) && text[j] >= '0' && text[j] <= '9' {
				j += 1
			}
			if j > 0 &&
			   j + 1 < len(text) &&
			   text[j] == '.' &&
			   text[j + 1] == ' ' {
				// dim "N." + space (visible = digits + '.' + space)
				if visible + j + 2 <= cols {
					strings.write_string(b, dim_on)
					strings.write_string(b, text[:j + 1]) // "12."
					md_restore_prose(b, th, false, false, false)
					strings.write_byte(b, ' ')
					visible += j + 2
				}
				i = j + 2
			}
		}
	}

	for i < len(text) && visible < cols {
		// **bold** or __bold__
		if !in_code && i + 1 < len(text) {
			dbl :=
				(text[i] == '*' && text[i + 1] == '*') ||
				(text[i] == '_' && text[i + 1] == '_')
			if dbl {
				if in_bold && !heading {
					in_bold = false
					md_restore_prose(b, th, in_bold, in_italic, heading)
				} else if !in_bold {
					// Bold only — never bright-white \x1b[97m
					strings.write_string(b, bold_on)
					in_bold = true
				}
				i += 2
				continue
			}
		}
		// *italic*
		if !in_code && text[i] == '*' {
			if in_italic {
				in_italic = false
				md_restore_prose(b, th, in_bold, in_italic, heading)
			} else {
				strings.write_string(b, "\x1b[3m")
				in_italic = true
			}
			i += 1
			continue
		}
		// `inline code` — theme dim, not reverse video / bright fence code
		if text[i] == '`' {
			if in_code {
				in_code = false
				md_restore_prose(b, th, in_bold, in_italic, heading)
			} else {
				strings.write_string(b, dim_on)
				in_code = true
			}
			i += 1
			continue
		}
		_, sz := utf8.decode_rune(text[i:])
		if sz <= 0 {
			break
		}
		strings.write_string(b, text[i:i + sz])
		visible += 1
		i += sz
	}
	if in_code || in_bold || in_italic || heading {
		strings.write_string(b, "\x1b[0m")
	}
	return visible
}

// strip_md_markers removes common markers for approximate display width.
strip_md_markers :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	// strip leading heading hashes
	h := 0
	for h < len(text) && h < 6 && text[h] == '#' {
		h += 1
	}
	if h > 0 && h < len(text) && text[h] == ' ' {
		i = h + 1
	} else if len(text) >= 2 && (text[0] == '-' || text[0] == '*') && text[1] == ' ' {
		strings.write_string(&b, "• ")
		i = 2
	} else {
		j := 0
		for j < len(text) && text[j] >= '0' && text[j] <= '9' {
			j += 1
		}
		if j > 0 && j + 1 < len(text) && text[j] == '.' && text[j + 1] == ' ' {
			// keep "N. " as plain (no extra bullet)
			strings.write_string(&b, text[:j + 1])
			strings.write_byte(&b, ' ')
			i = j + 2
		}
	}
	for i < len(text) {
		if i + 1 < len(text) && text[i] == '*' && text[i + 1] == '*' {
			i += 2
			continue
		}
		if text[i] == '*' || text[i] == '`' {
			i += 1
			continue
		}
		strings.write_byte(&b, text[i])
		i += 1
	}
	return strings.to_string(b)
}

// --- fenced code / mermaid (C1.3) ---

// fence_body_start_and_lang: if first line is a language tag, return body offset + lang.
// Otherwise body starts at 0 and lang is "".
fence_body_start_and_lang :: proc(part: string) -> (body_start: int, lang: string) {
	if part == "" {
		return 0, ""
	}
	// first line ends at \n or EOF
	nl := strings.index_byte(part, '\n')
	first: string
	rest_off: int
	if nl < 0 {
		first = part
		rest_off = len(part)
	} else {
		first = part[:nl]
		rest_off = nl + 1
	}
	// language tag: short, no spaces (allow - + . in langs like c++, objective-c)
	tag := strings.trim_space(first)
	if tag == "" || len(tag) > 32 {
		return 0, ""
	}
	for i in 0 ..< len(tag) {
		ch := tag[i]
		if ch == ' ' || ch == '\t' {
			return 0, ""
		}
	}
	// strip optional leading "lang" only — keep as lowercase for header
	return rest_off, strings.to_lower(tag, context.temp_allocator)
}

// is_mermaid_lang: mermaid and common aliases.
is_mermaid_lang :: proc(lang: string) -> bool {
	switch lang {
	case "mermaid", "mmd", "graph", "flowchart", "sequence", "sequencediagram",
	     "classdiagram", "statediagram", "erdiagram", "gantt", "pie", "mindmap",
	     "timeline", "gitgraph", "journey":
		return true
	}
	return false
}

// fence_header_line: quiet chrome "── mermaid ──" / "── rust ──" / "── code ──"
fence_header_line :: proc(lang: string, allocator := context.allocator) -> string {
	if lang == "" {
		return strings.clone("── code ──", allocator)
	}
	if is_mermaid_lang(lang) {
		// normalize display label
		label := "mermaid"
		if lang != "mermaid" && lang != "mmd" {
			label = fmt.tprintf("mermaid · %s", lang)
		}
		return fmt.aprintf("── %s ──", label, allocator = allocator)
	}
	return fmt.aprintf("── %s ──", lang, allocator = allocator)
}

// fence_footer_line: matching box-drawing rule under header (rune width).
fence_footer_line :: proc(lang: string, allocator := context.allocator) -> string {
	head := fence_header_line(lang, context.temp_allocator)
	n := 0
	for _ in head {
		n += 1
	}
	if n < 11 {
		n = 11
	}
	b := strings.builder_make(allocator)
	for i := 0; i < n; i += 1 {
		strings.write_string(&b, "─")
	}
	return strings.to_string(b)
}

// write_markdown_line: full-line paint without column cap (legacy helper).
write_markdown_line :: proc(b: ^strings.Builder, text: string, base_style: Line_Style) {
	base_on, _ := style_ansi(base_style)
	if base_on != "" {
		strings.write_string(b, base_on)
	}
	_ = write_md_inline(b, text, 10_000)
}

// --- GFM pipe tables (C1.2) ---

// is_table_delimiter_line: GFM `| --- | :---: |` (needs `|` and `-`; optional `:`).
is_table_delimiter_line :: proc(line: string) -> bool {
	s := strings.trim_space(line)
	if s == "" {
		return false
	}
	has_pipe := false
	has_dash := false
	for r in s {
		switch r {
		case '|':
			has_pipe = true
		case '-':
			has_dash = true
		case ':', ' ', '\t':
		// ok
		case:
			return false
		}
	}
	return has_pipe && has_dash
}

// is_table_row_candidate: non-empty line with a column pipe, not a delimiter.
is_table_row_candidate :: proc(line: string) -> bool {
	s := strings.trim_space(line)
	if s == "" || is_table_delimiter_line(s) {
		return false
	}
	return strings.contains(s, "|")
}

// split_table_cells splits a pipe row into trimmed cells (outer empty from leading/trailing | dropped).
split_table_cells :: proc(line: string, allocator := context.allocator) -> [dynamic]string {
	s := strings.trim_space(line)
	parts := strings.split(s, "|", context.temp_allocator)
	out := make([dynamic]string, 0, len(parts), allocator)
	// drop empty leading/trailing from outer pipes
	start := 0
	end := len(parts)
	if end > 0 && strings.trim_space(parts[0]) == "" {
		start = 1
	}
	if end > start && strings.trim_space(parts[end - 1]) == "" {
		end -= 1
	}
	for i in start ..< end {
		append(&out, strings.clone(strings.trim_space(parts[i]), allocator))
	}
	return out
}

// cell_display_width: rune count after stripping md markers (approx).
cell_display_width :: proc(cell: string) -> int {
	stripped := strip_md_markers(cell, context.temp_allocator)
	n := 0
	for _ in stripped {
		n += 1
	}
	return n
}

// format_table_rows: header + body rows (no delimiter) → aligned display lines.
// Returns owned lines (allocator). Header is bold-ish via ** already in cells if any.
format_table_rows :: proc(
	header: []string,
	body: [][]string,
	max_width: int,
	allocator := context.allocator,
) -> [dynamic]string {
	ncols := len(header)
	for row in body {
		if len(row) > ncols {
			ncols = len(row)
		}
	}
	if ncols == 0 {
		return make([dynamic]string, 0, 0, allocator)
	}
	// column widths
	widths := make([]int, ncols, context.temp_allocator)
	for c in 0 ..< ncols {
		w := 1
		if c < len(header) {
			w = max(w, cell_display_width(header[c]))
		}
		for row in body {
			if c < len(row) {
				w = max(w, cell_display_width(row[c]))
			}
		}
		// cap per-col so whole table fits roughly
		cap_c := max(4, (max_width - 3 * ncols) / max(1, ncols))
		widths[c] = min(w, cap_c)
	}

	out := make([dynamic]string, 0, 2 + len(body), allocator)
	append(&out, format_table_data_line(header, widths[:], allocator))
	append(&out, format_table_sep_line(widths[:], allocator))
	for row in body {
		append(&out, format_table_data_line(row, widths[:], allocator))
	}
	return out
}

format_table_data_line :: proc(cells: []string, widths: []int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "│")
	for c in 0 ..< len(widths) {
		cell := ""
		if c < len(cells) {
			cell = cells[c]
		}
		// strip markers for pad width; keep simple plain text in table cells for alignment
		plain := strip_md_markers(cell, context.temp_allocator)
		// truncate plain to width
		trunc := plain
		n := 0
		end := 0
		for r in plain {
			if n >= widths[c] {
				break
			}
			n += 1
			end += utf8.rune_size(r)
		}
		trunc = plain[:end]
		pad := widths[c] - n
		strings.write_byte(&b, ' ')
		strings.write_string(&b, trunc)
		for i := 0; i < pad; i += 1 {
			strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, ' ')
		strings.write_string(&b, "│")
	}
	return strings.to_string(b)
}

format_table_sep_line :: proc(widths: []int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "├")
	for c in 0 ..< len(widths) {
		// widths[c] content + 2 spaces around
		seg := widths[c] + 2
		for i := 0; i < seg; i += 1 {
			strings.write_string(&b, "─")
		}
		if c + 1 < len(widths) {
			strings.write_string(&b, "┼")
		} else {
			strings.write_string(&b, "┤")
		}
	}
	return strings.to_string(b)
}

// try_parse_table_at: if lines[i] is header and lines[i+1] delimiter, return end index
// (exclusive) of table and formatted display lines. else ok=false.
try_parse_table_at :: proc(
	lines: []string,
	i: int,
	max_width: int,
	allocator := context.allocator,
) -> (
	end: int,
	formatted: [dynamic]string,
	ok: bool,
) {
	if i + 1 >= len(lines) {
		return 0, {}, false
	}
	if !is_table_row_candidate(lines[i]) {
		return 0, {}, false
	}
	if !is_table_delimiter_line(lines[i + 1]) {
		return 0, {}, false
	}
	header := split_table_cells(lines[i], context.temp_allocator)
	if len(header) == 0 {
		return 0, {}, false
	}
	// delim cell count should match for well-formed; still accept if close
	delim := split_table_cells(lines[i + 1], context.temp_allocator)
	if len(delim) == 0 {
		return 0, {}, false
	}

	body_dyn := make([dynamic][]string, 0, 8, context.temp_allocator)
	j := i + 2
	for j < len(lines) {
		row_line := lines[j]
		if strings.trim_space(row_line) == "" {
			break
		}
		if is_table_delimiter_line(row_line) {
			// stacked delimiter → stop (malformed residual)
			break
		}
		if !is_table_row_candidate(row_line) {
			break
		}
		cells := split_table_cells(row_line, context.temp_allocator)
		append(&body_dyn, cells[:])
		j += 1
	}
	body := body_dyn[:]
	formatted = format_table_rows(header[:], body, max_width, allocator)
	// free cell clones from split_table_cells when using temp — they're temp if temp_allocator
	return j, formatted, true
}

// md_emit_blank_if_needed: one blank line before fences/tables when prior line is non-empty.
md_emit_blank_if_needed :: proc(
	out: ^[dynamic]string,
	styles: ^[dynamic]Line_Style,
	block_idxs: ^[dynamic]int,
	bi: int,
	allocator := context.allocator,
) {
	if len(out) == 0 {
		return
	}
	last := out[len(out) - 1]
	if strings.trim_space(last) == "" {
		return
	}
	mark_line(out, styles, block_idxs, bi, "", .Normal, allocator)
}

// push_markdown_prose: line-aware assistant prose with GFM tables (C1.2).
// Non-table lines go through wrap_push; tables are emitted as preformatted rows.
// Table styles: header Bold, separator Dim, body Assistant (not full Code block).
push_markdown_prose :: proc(
	out: ^[dynamic]string,
	styles: ^[dynamic]Line_Style,
	block_idxs: ^[dynamic]int,
	bi: int,
	text: string,
	width: int,
	allocator := context.allocator,
) {
	if text == "" {
		return
	}
	lines := strings.split_lines(text, context.temp_allocator)
	prose_b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(lines) {
		end, formatted, ok := try_parse_table_at(lines, i, width, allocator)
		if ok {
			p := strings.to_string(prose_b)
			if p != "" {
				wrap_push(out, styles, block_idxs, bi, p, .Assistant, width, allocator)
				strings.builder_reset(&prose_b)
			}
			md_emit_blank_if_needed(out, styles, block_idxs, bi, allocator)
			for ti in 0 ..< len(formatted) {
				style: Line_Style = .Assistant
				if ti == 0 {
					style = .Bold
				} else if ti == 1 {
					style = .Dim
				}
				mark_line(out, styles, block_idxs, bi, formatted[ti], style, allocator)
			}
			for fl in formatted {
				delete(fl, allocator)
			}
			delete(formatted)
			i = end
			if i < len(lines) && strings.trim_space(lines[i]) == "" {
				i += 1
			}
			continue
		}
		if strings.builder_len(prose_b) > 0 {
			strings.write_byte(&prose_b, '\n')
		}
		strings.write_string(&prose_b, lines[i])
		i += 1
	}
	p := strings.to_string(prose_b)
	if p != "" {
		wrap_push(out, styles, block_idxs, bi, p, .Assistant, width, allocator)
	}
}
