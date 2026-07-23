// Package tui — empty-session welcome screen.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
//
// Stacked layout: vertically padded, horizontally centered logo → flex → tip.
// Logo: Grok-style Braille shell with "A" in the center (core.brand).
// See LICENSE and NOTICE for Apache-2.0 terms and Grok Build lineage.
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "aether:core"

// welcome_is_active: empty transcript, not streaming, art enabled.
welcome_is_active :: proc(s: ^App_State) -> bool {
	return len(s.blocks) == 0 && !s.streaming && core.brand_art_enabled()
}

// write_welcome_body paints the opening into the body region: centered logo only
// (no hero border box, no version / "Thanks for…" chrome).
write_welcome_body :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	if body_h < 1 {
		return
	}
	write_welcome_stacked(b, s, cols, body_h)
}

// --- Stacked (centered logo) ------------------------------------------------

write_welcome_stacked :: proc(b: ^strings.Builder, s: ^App_State, cols: int, body_h: int) {
	// Prefer full mark when the terminal is wide enough for the old hero path.
	tier := core.brand_pick_tier(body_h, cols)
	if core.brand_use_hero(body_h, cols) {
		tier = .Full
	}
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
	// top_pad ≈ remaining / 3 (stable logo position)
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
		flex = 1 // keep Min(1) flex gap when possible
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
		// Menu rows: slightly brighter; logo dim
		style: Line_Style = .Dim
		if strings.contains(line, "ctrl+") {
			style = .Normal
		}
		write_row_content(b, line, style, cols, true)
	}
}
