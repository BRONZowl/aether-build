// Package core — Aether brand / welcome ASCII art (V1 visual parity).
// Pattern reference: Grok height-tiered welcome logo (not Grok Braille assets).
// Original Aether wordmark for dual-product identity.
package core

import "core:fmt"
import "core:os"
import "core:strings"

// Height tiers (rows) — art only when the terminal has room.
BRAND_SMALL_MIN_ROWS :: 14
BRAND_FULL_MIN_ROWS :: 20
// Width floors (columns) so wordmarks do not wrap badly.
BRAND_SMALL_MIN_COLS :: 28
BRAND_FULL_MIN_COLS :: 42

Brand_Tier :: enum {
	None,
	Chip,  // single line
	Small, // ~3 lines
	Full,  // ~6 lines
}

// Full wordmark (~6 lines, ~40 cols). Box-drawing + simple peak (aether sky).
BRAND_ART_FULL := [6]string {
	`      ╱╲`,
	`     ╱  ╲     ┌─┐┌─┐┌┬┐┬ ┬┌─┐┬─┐`,
	`    ╱ /\ ╲    ├─┤├┤  │ ├─┤├┤ ├┬┘`,
	`   ╱ /  \ ╲   ┴ ┴└─┘ ┴ ┴ ┴└─┘┴└─`,
	`  ╱_______\╲  odin agent · xAI`,
	`              ` + VERSION,
}

// Small wordmark (~3 lines).
BRAND_ART_SMALL := [3]string {
	`  ╱╲  aether`,
	` ╱__╲ odin · grok`,
	`      ` + VERSION,
}

// Chip for tiny terminals or compact header.
BRAND_ART_CHIP :: "◇ aether"

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

// brand_pick_tier: size-aware tier (Grok-shaped presence, Aether art).
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
	if r < BRAND_SMALL_MIN_ROWS || c < 20 {
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
		// package-level single-element via static array slice
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

// brand_render: joined art (+ optional trailing newline), owned by allocator.
// empty string if disabled / none tier and allow_chip=false.
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
		// auto: None means "auto pick", not "no art" — use pick
		tier = brand_pick_tier(rows, cols)
	}
	// force_tier of None after enable still auto-picks above.
	// To force empty, caller disables env.
	lines := brand_art_lines(tier)
	if len(lines) == 0 {
		return strings.clone("", allocator)
	}
	b := strings.builder_make(allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}

// brand_render_for_about: mid-tier art always when enabled (ignore tiny rows).
brand_render_for_about :: proc(allocator := context.allocator) -> string {
	if !brand_art_enabled() {
		return strings.clone("", allocator)
	}
	// Prefer full if wide enough assumption; about is not size-bound tightly
	return brand_render(24, 80, allocator)
}

// brand_welcome_tips: short discover line under art.
brand_welcome_tips :: proc(allocator := context.allocator) -> string {
	return strings.clone("/about · /help · /keys · /tools · /exit", allocator)
}

// brand_status_line: one-liner for headers when full art hidden.
brand_status_line :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf("%s  %s", BRAND_ART_CHIP, version_string(), allocator = allocator)
}
