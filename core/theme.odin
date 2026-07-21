// Package core — UI theme name registry (C2.1).
// TUI maps names to SGR palettes; core only stores the active name + cycle order.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:os"
import "core:strings"

// Canonical theme keys (first alias is the stable name).
UI_THEME_NAMES :: [5]string{"dark", "light", "tokyonight", "rosepine", "oscura"}

// g_ui_theme_name process-global; empty → "dark".
// Always points at a static/canonical name (never heap-owned) so tests and
// config loaders can set/reset without tracking-allocator bad frees.
g_ui_theme_name: string

// intern_theme_name returns a stable string from UI_THEME_NAMES (or "dark").
intern_theme_name :: proc(canon: string) -> string {
	for n in UI_THEME_NAMES {
		if n == canon {
			return n
		}
	}
	return "dark"
}

// normalize_theme_name maps Grok aliases → canonical key; ok=false if unknown.
normalize_theme_name :: proc(raw: string) -> (string, bool) {
	s := strings.to_lower(strings.trim_space(raw), context.temp_allocator)
	if s == "" {
		return "dark", true
	}
	switch s {
	case "dark", "default", "groknight", "grok-night", "grok_night":
		return "dark", true
	case "light", "day", "grokday", "grok-day", "grok_day":
		return "light", true
	case "tokyonight", "tokyo-night", "tokyo_night", "tokyo":
		return "tokyonight", true
	case "rosepine", "rose-pine", "rose_pine", "rose", "rosepine-moon", "rose-pine-moon":
		return "rosepine", true
	case "oscura", "oscura-midnight", "oscura_midnight":
		return "oscura", true
	// auto/system → dark for now (no portal polling)
	case "auto", "system":
		return "dark", true
	}
	return "", false
}

// set_ui_theme_name stores canonical name. Returns false if unknown.
set_ui_theme_name :: proc(raw: string) -> bool {
	canon, ok := normalize_theme_name(raw)
	if !ok {
		return false
	}
	g_ui_theme_name = intern_theme_name(canon)
	return true
}

// get_ui_theme_name returns canonical name (never empty).
get_ui_theme_name :: proc() -> string {
	if g_ui_theme_name == "" {
		return "dark"
	}
	return g_ui_theme_name
}

// cycle_ui_theme_name advances to next built-in; returns new name.
cycle_ui_theme_name :: proc() -> string {
	cur := get_ui_theme_name()
	names := UI_THEME_NAMES
	idx := 0
	for i in 0 ..< len(names) {
		if names[i] == cur {
			idx = i
			break
		}
	}
	next := names[(idx + 1) % len(names)]
	_ = set_ui_theme_name(next)
	return next
}

// list_ui_theme_names human-readable list for /theme list.
list_ui_theme_names :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"themes: dark (default), light, tokyonight, rosepine, oscura\n" +
		"aliases: groknight, grokday, tokyo, rose, …  auto→dark\n" +
		"current: %s",
		get_ui_theme_name(),
		allocator = allocator,
	)
}

// ui_color_disabled when NO_COLOR / AETHER_NO_COLOR set.
ui_color_disabled :: proc() -> bool {
	if v := os.get_env("NO_COLOR", context.temp_allocator); v != "" {
		return true
	}
	if v := os.get_env("AETHER_NO_COLOR", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return true
	}
	return false
}

// reset_ui_theme for tests (static names — no free).
reset_ui_theme :: proc() {
	g_ui_theme_name = ""
}
