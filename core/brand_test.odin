// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

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
test_brand_art_grok_shell_with_a :: proc(t: ^testing.T) {
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
	// Same outer envelope as Grok logo07 (first + last lines)
	testing.expect(t, full[0] == `⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄`)
	testing.expect(t, full[6] == `⠐⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀`)
	// Center differs from Grok (thinner A fill, not open diagonal)
	testing.expect(t, full[2] != `⠀⠀⣼⡟⠁⠀⠀⠀⢀⡴⠻⣿⡀⠀`)
	testing.expect(t, full[3] != `⠀⠀⣿⡇⠀⠀⠀⠔⠁⠀⠀⣿⡇⠀`)
	// Current thin-A center line
	testing.expect(t, full[3] == `⠀⠀⣿⡇⢠⠏⠉⠉⢧⠀⠀⣿⡇⠀`)

	small := brand_art_lines(.Small)
	testing.expect(t, len(small) == BRAND_SMALL_CELLS_H)
	for line in small {
		testing.expect(t, utf8.rune_count_in_string(line) == BRAND_SMALL_CELLS_W)
	}
	testing.expect(t, small[0] == `⠀⠀⠀⣀⣤⣤⣀⠀⠀⡠`)
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
}

@(test)
test_brand_startup_slash_tips_consistent :: proc(t: ^testing.T) {
	set := brand_startup_slash_tips(context.allocator)
	defer delete(set)
	testing.expect(t, strings.contains(set, "/quit"), set)
	testing.expect(t, strings.contains(set, "/help"), set)
	testing.expect(t, !strings.contains(set, "/exit"), set)

	welcome := brand_welcome_tips(context.allocator)
	defer delete(welcome)
	testing.expect(t, strings.contains(welcome, set), welcome)
	testing.expect(t, strings.has_prefix(welcome, "type a message"), welcome)

	resume := brand_resume_tips_notice(context.allocator)
	defer delete(resume)
	testing.expect(t, strings.contains(resume, set), resume)
	testing.expect(t, strings.has_prefix(resume, "tips:"), resume)

	repl := brand_repl_no_art_banner(context.allocator)
	defer delete(repl)
	testing.expect(t, strings.contains(repl, set), repl)
	testing.expect(t, !strings.contains(repl, "/exit"), repl)
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
