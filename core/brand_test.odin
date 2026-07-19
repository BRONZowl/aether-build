package core

import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_brand_pick_tier_sizes :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	prev2 := os.get_env("AETHER_ASCII_ART", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_ASCII_ART")
	_ = os.unset_env("AETHER_ASCII_ART")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		}
		if prev2 != "" {
			_ = os.set_env("AETHER_ASCII_ART", prev2)
		}
	}

	testing.expect(t, brand_pick_tier(10, 80) == .Chip)
	testing.expect(t, brand_pick_tier(14, 18) == .Chip || brand_pick_tier(14, 18) == .Small)
	testing.expect(t, brand_pick_tier(16, 40) == .Small)
	testing.expect(t, brand_pick_tier(24, 80) == .Full)
}

@(test)
test_brand_art_disabled :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	_ = os.set_env("AETHER_NO_ASCII_ART", "1")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		} else {
			_ = os.unset_env("AETHER_NO_ASCII_ART")
		}
	}
	testing.expect(t, !brand_art_enabled())
	testing.expect(t, brand_pick_tier(40, 80) == .None)
	s := brand_render(40, 80, context.allocator)
	defer delete(s)
	testing.expect(t, s == "")
}

@(test)
test_brand_art_lines_content :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_ASCII_ART")
	_ = os.unset_env("AETHER_ASCII_ART")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		}
	}
	full := brand_art_lines(.Full)
	// Grok logo07 layout: 7 rows × 14 braille cells, fixed width
	testing.expect(t, len(full) == BRAND_FULL_CELLS_H)
	for line in full {
		testing.expect(t, utf8.rune_count_in_string(line) == BRAND_FULL_CELLS_W)
		// every cell is U+2800..U+28FF (braille block)
		for r in line {
			testing.expect(t, r >= 0x2800 && r <= 0x28FF)
		}
	}
	joined := strings.join(full, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "⣿") || strings.contains(joined, "⣾") || strings.contains(joined, "⣤"))

	small := brand_art_lines(.Small)
	testing.expect(t, len(small) == BRAND_SMALL_CELLS_H)
	for line in small {
		testing.expect(t, utf8.rune_count_in_string(line) == BRAND_SMALL_CELLS_W)
		for r in line {
			testing.expect(t, r >= 0x2800 && r <= 0x28FF)
		}
	}

	chip := brand_art_lines(.Chip)
	testing.expect(t, len(chip) == 1)
	testing.expect(t, strings.contains(chip[0], "aether"))
}

@(test)
test_brand_center_line :: proc(t: ^testing.T) {
	line := BRAND_ART_FULL[0]
	w := brand_line_cells(line)
	out := brand_center_line(line, w + 10, context.allocator)
	defer delete(out)
	// 5 spaces of left pad when centering in w+10
	testing.expect(t, strings.has_prefix(out, "     "))
	testing.expect(t, strings.has_suffix(out, line) || strings.contains(out, line))
}

@(test)
test_brand_render_joins :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_ASCII_ART")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		}
	}
	s := brand_render(24, 80, context.allocator)
	defer delete(s)
	testing.expect(t, strings.contains(s, "\n"))
	testing.expect(t, len(s) > 20)
}
