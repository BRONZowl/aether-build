// Package tui — Grok Build–parity welcome screen (empty session).
//
// Stacked layout (narrow): centered logo → gap → menu → flex → tip
// Hero layout (cols ≥ 90): bordered box, logo left, version+menu right
// Logo: Grok-style Braille shell with "A" in the center (core.brand).
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "aether:core"

// welcome_is_active: empty transcript, not streaming, art enabled.
welcome_is_active :: proc(s: ^App_State) -> bool {
	return len(s.blocks) == 0 && !s.streaming && core.brand_art_enabled()
}

// write_welcome_body paints the Grok-style opening into the body region.
write_welcome_body :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	if body_h < 1 {
		return
	}
	if core.brand_use_hero(body_h, cols) {
		write_welcome_hero(b, s, cols, body_h)
		return
	}
	write_welcome_stacked(b, s, cols, body_h)
}

// --- Stacked (Grok narrow welcome) ------------------------------------------

write_welcome_stacked :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	// Tier by content height (Grok pick_logo(window_height)).
	tier := core.brand_pick_tier(body_h, cols)
	logo := core.brand_art_lines(tier)
	menu_w := core.brand_menu_width(tier)
	menu_n := len(core.BRAND_MENU)
	logo_n := len(logo)
	logo_gap := 1 if logo_n > 0 else 0
	tip := core.brand_welcome_tips(context.temp_allocator)
	tip_h := 1 if tip != "" else 0
	tip_gap := 1 if tip_h > 0 else 0

	// fixed_below ≈ tip + gap (prompt/version live outside body in Aether chrome)
	fixed_below := tip_h + tip_gap
	fixed_above := logo_n + logo_gap
	// top_pad ≈ remaining / 3 (Grok uses default menu height for stable logo pos)
	content_mid := menu_n + fixed_below
	remaining := body_h - fixed_above - content_mid
	top_pad := 0
	if remaining > 0 {
		top_pad = remaining / 3
	}
	// Build row list then paint into body_h
	rows := make([dynamic]string, 0, body_h + 4, context.temp_allocator)
	for i := 0; i < top_pad; i += 1 {
		append(&rows, "")
	}
	for line in logo {
		append(&rows, core.brand_center_line(line, cols, context.temp_allocator))
	}
	if logo_gap > 0 {
		append(&rows, "")
	}
	for item in core.BRAND_MENU {
		row := core.brand_menu_row(item.label, item.key, menu_w, context.temp_allocator)
		append(&rows, core.brand_center_line(row, cols, context.temp_allocator))
	}
	// flex: remaining blank lines before tip
	used := len(rows) + tip_h + tip_gap
	flex := body_h - used
	if flex < 1 {
		flex = 1 // Grok keeps Min(1) flex gap when possible
	}
	for i := 0; i < flex; i += 1 {
		append(&rows, "")
	}
	if tip_h > 0 {
		append(&rows, core.brand_center_line(tip, cols, context.temp_allocator))
	}
	// paint exactly body_h rows
	for i in 0 ..< body_h {
		line := ""
		if i < len(rows) {
			line = rows[i]
		}
		// Menu rows: slightly brighter; logo dim (Grok gray logo resting)
		style: Line_Style = .Dim
		// detect menu band by content
		if strings.contains(line, "ctrl+") {
			style = .Normal
		}
		write_row_content(b, line, style, cols, true)
	}
}

// --- Hero box (Grok wide welcome) -------------------------------------------

write_welcome_hero :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	logo := core.BRAND_ART_FULL[:]
	logo_w := core.BRAND_FULL_CELLS_W
	logo_h := len(logo)
	// Grok: box_width = content.width - 6, max 120
	box_w := cols - 6
	if box_w > 120 {
		box_w = 120
	}
	if box_w < 40 {
		// fall back stacked
		write_welcome_stacked(b, s, cols, body_h)
		return
	}
	// left col: logo + pads (Grok LOGO_H_PAD=3, left pad shave 1)
	left_pad := 2 // LOGO_H_PAD - 1
	right_pad := 3
	left_col := logo_w + left_pad + right_pad
	inner_w := box_w - 2 // borders
	if left_col + 20 > inner_w {
		left_col = max(logo_w + 2, inner_w / 3)
	}
	right_w := inner_w - left_col
	if right_w < 16 {
		write_welcome_stacked(b, s, cols, body_h)
		return
	}

	// Right column content: version, subtitle, gap, menu
	ver := core.version_string()
	sub := core.brand_hero_subtitle()
	menu_n := len(core.BRAND_MENU)
	// right_col_height = 1(version) + 1(subtitle) + 1(gap) + menu
	right_h := 1 + 1 + 1 + menu_n
	inner_h := max(logo_h, right_h)
	// box = borders + v_pad*2 + inner
	v_pad := 1
	box_h := 2 + v_pad * 2 + inner_h
	if box_h + 2 > body_h {
		// not enough height — stacked
		write_welcome_stacked(b, s, cols, body_h)
		return
	}

	// horizontal center the box
	box_x_pad := (cols - box_w) / 2
	if box_x_pad < 0 {
		box_x_pad = 0
	}
	// vertical: leave room for tip under box + flex
	tip := core.brand_welcome_tips(context.temp_allocator)
	tip_h := 1
	// top pad so box sits upper-center like Grok
	top_pad := max(0, (body_h - box_h - tip_h - 1) / 3)

	// Build full box lines
	box_lines := make([dynamic]string, 0, box_h, context.temp_allocator)
	// top border
	append(&box_lines, hero_h_border(box_w, true))
	// v_pad
	for i := 0; i < v_pad; i += 1 {
		append(&box_lines, hero_empty_row(box_w))
	}
	// content rows
	for r in 0 ..< inner_h {
		left := hero_left_cell(logo, r, left_pad, logo_w, right_pad, left_col)
		right := hero_right_cell(r, ver, sub, right_w, menu_n)
		// assemble: │ left right │
		line := fmt.tprintf("│%s%s│", left, right)
		// ensure exact box_w runes is hard; pad/truncate with spaces by byte width approx
		line = hero_fit_box_row(line, box_w)
		append(&box_lines, line)
	}
	for i := 0; i < v_pad; i += 1 {
		append(&box_lines, hero_empty_row(box_w))
	}
	append(&box_lines, hero_h_border(box_w, false))

	// Paint into body
	painted := 0
	for i := 0; i < top_pad && painted < body_h; i += 1 {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	for _, bi in box_lines {
		if painted >= body_h {
			break
		}
		// center box line in terminal cols
		centered := core.brand_center_line(box_lines[bi], cols, context.temp_allocator)
		write_row_content(b, centered, .Dim, cols, true)
		painted += 1
	}
	// flex + tip
	if painted < body_h - tip_h {
		// at least one blank
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	for painted < body_h - tip_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	if painted < body_h {
		write_row_content(
			b,
			core.brand_center_line(tip, cols, context.temp_allocator),
			.Dim,
			cols,
			true,
		)
		painted += 1
	}
	for painted < body_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
}

hero_h_border :: proc(box_w: int, top: bool) -> string {
	// ╭───╮ / ╰───╯
	inner := box_w - 2
	if inner < 0 {
		inner = 0
	}
	b := strings.builder_make(context.temp_allocator)
	if top {
		strings.write_string(&b, "╭")
	} else {
		strings.write_string(&b, "╰")
	}
	for i := 0; i < inner; i += 1 {
		strings.write_string(&b, "─")
	}
	if top {
		strings.write_string(&b, "╮")
	} else {
		strings.write_string(&b, "╯")
	}
	return strings.to_string(b)
}

hero_empty_row :: proc(box_w: int) -> string {
	inner := box_w - 2
	if inner < 0 {
		inner = 0
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "│")
	for i := 0; i < inner; i += 1 {
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, "│")
	return strings.to_string(b)
}

hero_left_cell :: proc(
	logo: []string,
	row: int,
	left_pad: int,
	logo_w: int,
	right_pad: int,
	left_col: int,
) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < left_pad; i += 1 {
		strings.write_byte(&b, ' ')
	}
	if row < len(logo) {
		strings.write_string(&b, logo[row])
		// pad to logo_w with braille blank
		lw := utf8.rune_count_in_string(logo[row])
		for i := lw; i < logo_w; i += 1 {
			strings.write_string(&b, "⠀")
		}
	} else {
		for i := 0; i < logo_w; i += 1 {
			strings.write_string(&b, "⠀")
		}
	}
	for i := 0; i < right_pad; i += 1 {
		strings.write_byte(&b, ' ')
	}
	// ensure left_col width in runes is approximate (spaces + braille = 1 col each)
	s := strings.to_string(b)
	// pad/trunc to left_col display cells
	for utf8.rune_count_in_string(s) < left_col {
		s = fmt.tprintf("%s ", s)
	}
	// if over, leave as-is (braille may count differently)
	return s
}

hero_right_cell :: proc(
	row: int,
	ver: string,
	sub: string,
	right_w: int,
	menu_n: int,
) -> string {
	// row map: 0=version, 1=subtitle, 2=blank, 3..=menu
	text := ""
	switch row {
	case 0:
		text = ver
	case 1:
		// truncate subtitle to right_w
		text = sub
		if len(text) > right_w {
			text = text[:max(0, right_w - 1)]
		}
	case 2:
		text = ""
	case:
		mi := row - 3
		if mi >= 0 && mi < menu_n {
			item := core.BRAND_MENU[mi]
			text = core.brand_menu_row(item.label, item.key, right_w - 2, context.temp_allocator)
		}
	}
	// pad to right_w
	b := strings.builder_make(context.temp_allocator)
	// 2-col inset like Grok H_INSET
	strings.write_string(&b, "  ")
	strings.write_string(&b, text)
	s := strings.to_string(b)
	for utf8.rune_count_in_string(s) < right_w {
		s = fmt.tprintf("%s ", s)
	}
	// hard truncate by runes if needed
	if utf8.rune_count_in_string(s) > right_w {
		// simple byte truncate fallback
		if len(s) > right_w * 3 {
			s = s[:right_w * 3]
		}
	}
	return s
}

hero_fit_box_row :: proc(line: string, box_w: int) -> string {
	// Ensure string displays near box_w; pad with spaces if short.
	n := utf8.rune_count_in_string(line)
	if n == box_w {
		return line
	}
	if n < box_w {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, line)
		// insert spaces before final │ if present
		// simpler: append spaces before last char if last is │
		s := strings.to_string(b)
		for utf8.rune_count_in_string(s) < box_w {
			// insert space before trailing border
			if strings.has_suffix(s, "│") {
				s = fmt.tprintf("%s │", s[:len(s) - len("│")])
			} else {
				s = fmt.tprintf("%s ", s)
			}
		}
		return s
	}
	return line
}
