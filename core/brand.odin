// Package core — Aether brand / welcome Braille art (V1 visual parity).
//
// Layout matches Grok Build welcome logos (logo07 / logo05):
//   - U+2800 Braille block medium
//   - Fixed canvas: full 14×7 cells, small 10×5 cells (every line same width)
//   - Open form, soft strokes, top-right fleck, bottom-left taper
//   - Height-tiered pick (small / full / chip)
// Glyph is an open Aether "A" monogram — same layout language, not Grok's mark.
package core

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// Height tiers — same spirit as Grok's 22/26 window floors; slightly more
// permissive so mid-size panes still get a monogram.
BRAND_SMALL_MIN_ROWS :: 14
BRAND_FULL_MIN_ROWS :: 20
// Width floors (columns) so fixed-width monograms do not clip.
BRAND_SMALL_MIN_COLS :: 20
BRAND_FULL_MIN_COLS :: 28

// Fixed canvas sizes (braille cells) — match Grok logo05 / logo07.
BRAND_FULL_CELLS_W :: 14
BRAND_FULL_CELLS_H :: 7
BRAND_SMALL_CELLS_W :: 10
BRAND_SMALL_CELLS_H :: 5

Brand_Tier :: enum {
	None,
	Chip,  // single line
	Small, // logo05 scale (10×5)
	Full,  // logo07 scale (14×7)
}

// Full welcome art — open "A" on Grok logo07 canvas (14 cells × 7 rows).
// Same layout envelope: top cap + right fleck, open body, bottom arc, left taper.
BRAND_ART_FULL := [7]string {
	`⠀⠀⠀⠀⠀⣀⣠⣤⣤⡀⠀⠀⡠⠀`,
	`⠀⠀⠀⣠⣾⠟⠁⡀⠙⢿⣦⡾⠀⠀`,
	`⠀⠀⣾⡟⢁⡴⠋⠉⠳⣄⠙⣿⡆⠀`,
	`⠀⠀⣿⡷⠋⠀⠀⠀⠀⠈⢷⣿⠃⠀`,
	`⠀⠀⠹⣷⡀⠀⠀⠀⠀⣠⣾⠏⠀⠀`,
	`⠀⠀⠀⠙⠿⣶⣶⣶⣾⣿⠷⠂⠀⠀`,
	`⠠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀`,
}

// Small monogram — Grok logo05 canvas (10 cells × 5 rows).
BRAND_ART_SMALL := [5]string {
	`⠀⠀⢀⣤⡶⢶⣤⡀⡠⠂`,
	`⢀⣴⡿⣫⠴⠦⣝⢿⣧⡀`,
	`⣿⡟⠈⠁⠀⠀⠈⠁⣿⡗`,
	`⠈⠳⣄⣀⣤⣤⣤⡔⠛⠁`,
	`⠐⠀⠀⠉⠉⠉⠁⠀⠀⠀`,
}

// Chip for tiny terminals or compact header.
BRAND_ART_CHIP :: "⣿ aether · odin"

// brand_art_enabled: AETHER_NO_ASCII_ART or AETHER_ASCII_ART=off disables.
brand_art_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") ||
	   strings.equal_fold(v, "yes") ||
	   strings.equal_fold(v, "on") {
		return false
	}
	v := strings.to_lower(
		strings.trim_space(os.get_env("AETHER_ASCII_ART", context.temp_allocator)),
		context.temp_allocator,
	)
	switch v {
	case "0", "off", "false", "no", "none", "hide":
		return false
	case "", "1", "on", "true", "yes", "auto", "welcome":
		return true
	}
	return true
}

// brand_pick_tier: size-aware tier (Grok layout floors, Aether art).
brand_pick_tier :: proc(rows, cols: int) -> Brand_Tier {
	if !brand_art_enabled() {
		return .None
	}
	if rows < 1 && cols < 1 {
		// unknown size: prefer small for REPL/about
		return .Small
	}
	r := rows
	c := cols
	if r <= 0 {
		r = 24
	}
	if c <= 0 {
		c = 80
	}
	if r < BRAND_SMALL_MIN_ROWS || c < 16 {
		return .Chip
	}
	if r >= BRAND_FULL_MIN_ROWS && c >= BRAND_FULL_MIN_COLS {
		return .Full
	}
	if r >= BRAND_SMALL_MIN_ROWS && c >= BRAND_SMALL_MIN_COLS {
		return .Small
	}
	return .Chip
}

// brand_art_lines: static string views for the tier (do not free).
// Returns empty slice for .None.
brand_art_lines :: proc(tier: Brand_Tier) -> []string {
	switch tier {
	case .None:
		return nil
	case .Chip:
		return brand_chip_slice()
	case .Small:
		return BRAND_ART_SMALL[:]
	case .Full:
		return BRAND_ART_FULL[:]
	}
	return nil
}

// brand_chip_slice: addressable chip line.
brand_chip_slice :: proc() -> []string {
	return BRAND_CHIP_LINES[:]
}

BRAND_CHIP_LINES := [1]string{BRAND_ART_CHIP}

// brand_pick_art: convenience — lines for rows/cols.
brand_pick_art :: proc(rows, cols: int) -> []string {
	return brand_art_lines(brand_pick_tier(rows, cols))
}

// brand_line_cells: braille / rune count (Grok visual width uses unicode width;
// braille cells are 1 col each in modern terminals).
brand_line_cells :: proc(line: string) -> int {
	return utf8.rune_count_in_string(line)
}

// brand_art_visual_width: max cell width of art lines for a tier.
brand_art_visual_width :: proc(tier: Brand_Tier) -> int {
	lines := brand_art_lines(tier)
	max_w := 0
	for line in lines {
		w := brand_line_cells(line)
		if w > max_w {
			max_w = w
		}
	}
	return max_w
}

// brand_center_line: left-pad with spaces so `line` is centered in `cols`.
// Returns a temp-allocator or given-allocator string; empty pad if cols too narrow.
brand_center_line :: proc(line: string, cols: int, allocator := context.allocator) -> string {
	if cols <= 0 {
		return strings.clone(line, allocator)
	}
	w := brand_line_cells(line)
	if w >= cols {
		return strings.clone(line, allocator)
	}
	pad := (cols - w) / 2
	if pad <= 0 {
		return strings.clone(line, allocator)
	}
	b := strings.builder_make(allocator)
	for i := 0; i < pad; i += 1 {
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, line)
	return strings.to_string(b)
}

// brand_render: joined art, owned by allocator.
// When cols > 0, each line is centered like Grok's Alignment::Center logo.
brand_render :: proc(
	rows: int = 24,
	cols: int = 80,
	allocator := context.allocator,
	force_tier: Brand_Tier = .None, // .None = auto pick; else force when enabled
) -> string {
	if !brand_art_enabled() {
		return strings.clone("", allocator)
	}
	tier := force_tier
	if tier == .None {
		tier = brand_pick_tier(rows, cols)
	}
	lines := brand_art_lines(tier)
	if len(lines) == 0 {
		return strings.clone("", allocator)
	}
	b := strings.builder_make(allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		if cols > 0 {
			centered := brand_center_line(line, cols, context.temp_allocator)
			strings.write_string(&b, centered)
		} else {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b)
}

// brand_render_for_about: full-tier art when enabled (ignore tiny rows).
brand_render_for_about :: proc(allocator := context.allocator) -> string {
	if !brand_art_enabled() {
		return strings.clone("", allocator)
	}
	return brand_render(24, 80, allocator)
}

// brand_welcome_tips: short discover line under art (Grok: menu/tips under logo).
brand_welcome_tips :: proc(allocator := context.allocator) -> string {
	return strings.clone("/about · /help · /keys · /tools · /exit", allocator)
}

// brand_status_line: one-liner for headers when full art hidden.
brand_status_line :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf("%s  %s", BRAND_ART_CHIP, version_string(), allocator = allocator)
}
