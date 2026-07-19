package core

import "core:os"
import "core:strings"
import "core:testing"

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
	testing.expect(t, brand_pick_tier(14, 30) == .Chip || brand_pick_tier(14, 30) == .Small)
	testing.expect(t, brand_pick_tier(14, 40) == .Small)
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
	testing.expect(t, len(full) == 9)
	joined := strings.join(full, "\n", context.temp_allocator)
	// peak + framed wordmark
	testing.expect(t, strings.contains(joined, "▲") || strings.contains(joined, "╱"))
	testing.expect(t, strings.contains(joined, "A  E  T  H  E  R") || strings.contains(joined, "A E T H E R"))
	testing.expect(t, strings.contains(joined, "odin"))
	testing.expect(t, strings.contains(joined, "╭") && strings.contains(joined, "╯"))

	small := brand_art_lines(.Small)
	testing.expect(t, len(small) == 4)
	small_j := strings.join(small, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(small_j, "A E T H E R") || strings.contains(small_j, "▲"))

	chip := brand_art_lines(.Chip)
	testing.expect(t, len(chip) == 1)
	testing.expect(t, strings.contains(chip[0], "aether"))
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
