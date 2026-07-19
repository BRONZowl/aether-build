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
	testing.expect(t, brand_pick_tier(16, 30) == .Small || brand_pick_tier(16, 30) == .Chip)
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
	testing.expect(t, len(full) == 6)
	joined := strings.join(full, "\n", context.temp_allocator)
	// wordmark uses box-drawing aether block (┌─┐… or peak ╱)
	testing.expect(t, strings.contains(joined, "╱") || strings.contains(joined, "┌"))
	testing.expect(t, strings.contains(joined, "odin") || strings.contains(joined, "aether"))

	small := brand_art_lines(.Small)
	testing.expect(t, len(small) == 3)
	testing.expect(t, strings.contains(small[0], "aether"))

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
