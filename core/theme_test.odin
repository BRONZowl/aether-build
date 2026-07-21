// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:os"
import "core:testing"

@(test)
test_normalize_theme_aliases :: proc(t: ^testing.T) {
	n, ok := normalize_theme_name("TokyoNight")
	testing.expect(t, ok && n == "tokyonight")
	n, ok = normalize_theme_name("grok-day")
	testing.expect(t, ok && n == "light")
	n, ok = normalize_theme_name("rose-pine")
	testing.expect(t, ok && n == "rosepine")
	n, ok = normalize_theme_name("not-a-theme")
	testing.expect(t, !ok)
	n, ok = normalize_theme_name("auto")
	testing.expect(t, ok && n == "dark")
}

@(test)
test_set_cycle_theme :: proc(t: ^testing.T) {
	reset_ui_theme()
	defer reset_ui_theme()
	testing.expect(t, get_ui_theme_name() == "dark")
	testing.expect(t, set_ui_theme_name("tokyo"))
	testing.expect(t, get_ui_theme_name() == "tokyonight")
	next := cycle_ui_theme_name()
	testing.expect(t, next == "rosepine", next)
	testing.expect(t, !set_ui_theme_name("nope"))
}

@(test)
test_ui_color_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_COLOR", context.temp_allocator)
	os.set_env("AETHER_NO_COLOR", "1")
	defer {
		if prev != "" {
			os.set_env("AETHER_NO_COLOR", prev)
		} else {
			os.unset_env("AETHER_NO_COLOR")
		}
	}
	testing.expect(t, ui_color_disabled())
}

@(test)
test_vim_mode_toggle :: proc(t: ^testing.T) {
	set_vim_mode(false)
	testing.expect(t, !vim_mode_enabled())
	testing.expect(t, toggle_vim_mode())
	testing.expect(t, vim_mode_enabled())
	set_vim_mode(false)
	testing.expect(t, !vim_mode_enabled())
}

@(test)
test_compact_mode_toggle :: proc(t: ^testing.T) {
	set_compact_mode(false)
	testing.expect(t, !compact_mode_enabled())
	testing.expect(t, toggle_compact_mode())
	testing.expect(t, compact_mode_enabled())
	set_compact_mode(false)
	testing.expect(t, !compact_mode_enabled())
}

@(test)
test_timestamps_toggle :: proc(t: ^testing.T) {
	set_timestamps(false)
	testing.expect(t, !timestamps_enabled())
	testing.expect(t, toggle_timestamps())
	testing.expect(t, timestamps_enabled())
	set_timestamps(false)
	testing.expect(t, !timestamps_enabled())
}
