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
test_brand_art_unique_a_monogram :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_ASCII_ART")
	_ = os.unset_env("AETHER_ASCII_ART")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		}
	}
	full := brand_art_lines(.Full)
	testing.expect(t, len(full) == BRAND_FULL_CELLS_H)
	for line in full {
		testing.expect(t, utf8.rune_count_in_string(line) == BRAND_FULL_CELLS_W)
		for r in line {
			testing.expect(t, r >= 0x2800 && r <= 0x28FF)
		}
	}
	// Distinct from Grok logo07
	testing.expect(t, full[0] != `⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄`)
	// Avengers A × SpaceX X monogram
	testing.expect(t, full[0] == `⠀⠀⠀⠀⠀⣀⣤⠶⢛⡛⠶⣤⣀⠀⠀⠀⠀⠀`)

	small := brand_art_lines(.Small)
	testing.expect(t, len(small) == BRAND_SMALL_CELLS_H)
	for line in small {
		testing.expect(t, utf8.rune_count_in_string(line) == BRAND_SMALL_CELLS_W)
	}
	testing.expect(t, small[0] == `⣀⣤⢶⣻⣟⡶⣤⣀`)
}

@(test)
test_brand_welcome_has_menu :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_ASCII_ART")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		}
	}
	s := brand_render_welcome(24, 80, context.allocator)
	defer delete(s)
	testing.expect(t, strings.contains(s, "New session"))
	testing.expect(t, strings.contains(s, "Resume session"))
	testing.expect(t, strings.contains(s, "Quit"))
	testing.expect(t, strings.contains(s, "ctrl+n"))
	testing.expect(t, strings.contains(s, "\n"))
}

@(test)
test_brand_hero_gate :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_ASCII_ART", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_ASCII_ART")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_ASCII_ART", prev)
		}
	}
	testing.expect(t, !brand_use_hero(24, 80))
	testing.expect(t, brand_use_hero(30, 100))
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
