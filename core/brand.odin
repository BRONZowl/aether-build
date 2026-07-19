// Package core — Aether brand / welcome art.
//
// Welcome *layout* follows Grok Build (stacked / hero, height tiers, menu).
// Glyph is original Aether: bold geometric "A" Braille monogram — letterform
// peak with crossbar and solid legs, not Grok's open-ring mark.
package core

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// Height tiers for when art is shown.
BRAND_SMALL_MIN_ROWS :: 14
BRAND_FULL_MIN_ROWS :: 20
BRAND_SMALL_MIN_COLS :: 20
BRAND_FULL_MIN_COLS :: 28

// Hero box (side-by-side logo + menu) — Grok HERO_BOX_MIN_WIDTH = 90.
BRAND_HERO_MIN_COLS :: 90

// Monogram canvas (braille cells).
BRAND_FULL_CELLS_W :: 15
BRAND_FULL_CELLS_H :: 6
BRAND_SMALL_CELLS_W :: 9
BRAND_SMALL_CELLS_H :: 3

Brand_Tier :: enum {
	None,
	Chip,
	Small,
	Full,
}

// Full mark — bold geometric A (peak + crossbar + solid legs). Unique letterform.
BRAND_ART_FULL := [6]string {
	`⠀⠀⠀⠀⢀⣴⠞⠛⠳⣦⡀⠀⠀⠀⠀`,
	`⠀⠀⢀⣴⠟⠁⣠⣤⣄⠈⠻⣦⡀⠀⠀`,
	`⢀⣴⠟⠁⣠⣾⣋⣀⣙⣷⣄⠈⠻⣦⡀`,
	`⣿⡇⠀⠈⠉⠉⠉⠉⠉⠉⠉⠁⠀⢸⣿`,
	`⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿`,
	`⣿⡇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿`,
}

// Small mark — compact geometric A.
BRAND_ART_SMALL := [3]string {
	`⠀⢀⣴⠞⠛⠳⣦⡀⠀`,
	`⣴⡟⢁⣴⠿⣦⡈⢻⣦`,
	`⣿⡇⠉⠉⠉⠉⠉⢸⣿`,
}

BRAND_ART_CHIP :: "◇ aether · odin"

// Welcome menu (stacked + hero) — Grok layout: label left, shortcut right.
// Keys match Aether TUI bindings (Ctrl+N / Ctrl+S / Ctrl+Q).
Brand_Menu_Item :: struct {
	label: string,
	key:   string,
}

BRAND_MENU := [3]Brand_Menu_Item {
	{"New session", "ctrl+n"},
	{"Resume session", "ctrl+s"},
	{"Quit", "ctrl+q"},
}

BRAND_SUBTITLE :: "Thanks for trying Aether — /about · /help · /feedback"

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

// brand_pick_tier: Grok-shaped height tiers.
brand_pick_tier :: proc(rows, cols: int) -> Brand_Tier {
	if !brand_art_enabled() {
		return .None
	}
	if rows < 1 && cols < 1 {
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

// brand_use_hero: wide side-by-side logo+menu (Grok hero box).
brand_use_hero :: proc(rows, cols: int) -> bool {
	if !brand_art_enabled() {
		return false
	}
	if cols < BRAND_HERO_MIN_COLS {
		return false
	}
	// Need room for full logo height + chrome
	if rows < BRAND_FULL_CELLS_H + 6 {
		return false
	}
	return true
}

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

brand_chip_slice :: proc() -> []string {
	return BRAND_CHIP_LINES[:]
}

BRAND_CHIP_LINES := [1]string{BRAND_ART_CHIP}

brand_pick_art :: proc(rows, cols: int) -> []string {
	// Hero always uses full logo (Grok full_logo_* helpers).
	if brand_use_hero(rows, cols) {
		return BRAND_ART_FULL[:]
	}
	return brand_art_lines(brand_pick_tier(rows, cols))
}

brand_line_cells :: proc(line: string) -> int {
	return utf8.rune_count_in_string(line)
}

brand_art_visual_width :: proc(tier: Brand_Tier) -> int {
	lines := brand_art_lines(tier)
	max_w := 0
	for line in lines {
		w := brand_line_cells(line)
		if w > max_w {
			max_w = w
		}
	}
	if max_w == 0 {
		return 24
	}
	return max_w
}

// brand_menu_width: Grok menu column — max(logo width, 30, content).
brand_menu_width :: proc(tier: Brand_Tier) -> int {
	w := brand_art_visual_width(tier)
	if w < 30 {
		w = 30
	}
	for item in BRAND_MENU {
		need := len(item.label) + 4 + len(item.key)
		if need > w {
			w = need
		}
	}
	return w
}

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

// brand_menu_row: "Label          key" padded to menu_w (Grok render_menu).
brand_menu_row :: proc(label, key: string, menu_w: int, allocator := context.allocator) -> string {
	// label left, key right, spaces between
	lw := len(label)
	kw := len(key)
	if menu_w < lw + kw + 1 {
		return fmt.aprintf("%s %s", label, key, allocator = allocator)
	}
	gap := menu_w - lw - kw
	b := strings.builder_make(allocator)
	strings.write_string(&b, label)
	for i := 0; i < gap; i += 1 {
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, key)
	return strings.to_string(b)
}

// brand_render: joined logo lines (optional center). For REPL /about.
brand_render :: proc(
	rows: int = 24,
	cols: int = 80,
	allocator := context.allocator,
	force_tier: Brand_Tier = .None,
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

// brand_render_welcome: full stacked welcome (logo + menu + tip) for REPL.
// Matches Grok stacked welcome content (no box).
brand_render_welcome :: proc(
	rows: int = 24,
	cols: int = 80,
	allocator := context.allocator,
) -> string {
	if !brand_art_enabled() {
		return strings.clone("", allocator)
	}
	tier := brand_pick_tier(rows, cols)
	if brand_use_hero(rows, cols) {
		tier = .Full
	}
	lines := brand_art_lines(tier)
	if len(lines) == 0 {
		return strings.clone("", allocator)
	}
	menu_w := brand_menu_width(tier)
	b := strings.builder_make(allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, brand_center_line(line, cols, context.temp_allocator))
	}
	strings.write_byte(&b, '\n') // logo_gap
	for item in BRAND_MENU {
		strings.write_byte(&b, '\n')
		row := brand_menu_row(item.label, item.key, menu_w, context.temp_allocator)
		strings.write_string(&b, brand_center_line(row, cols, context.temp_allocator))
	}
	strings.write_byte(&b, '\n')
	strings.write_byte(&b, '\n')
	tip := brand_welcome_tips(context.temp_allocator)
	strings.write_string(&b, brand_center_line(tip, cols, context.temp_allocator))
	return strings.to_string(b)
}

brand_render_for_about :: proc(allocator := context.allocator) -> string {
	if !brand_art_enabled() {
		return strings.clone("", allocator)
	}
	return brand_render(24, 80, allocator, .Full)
}

brand_welcome_tips :: proc(allocator := context.allocator) -> string {
	return strings.clone("type a message · /about · /help · /keys · /exit", allocator)
}

brand_status_line :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf("%s  %s", BRAND_ART_CHIP, version_string(), allocator = allocator)
}

brand_hero_subtitle :: proc() -> string {
	return BRAND_SUBTITLE
}
