// Package core — local privacy preference (no remote coding-data API).
// Persists [privacy] coding_data_share = true|false in ~/.grok/config.toml.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package core

import "core:fmt"
import "core:os"
import "core:strings"

// g_privacy_share: true = opt-in to optional product analytics/share notes.
// Default false (opt-out / private).
g_privacy_share: bool
g_privacy_loaded: bool

privacy_load_from_config :: proc() {
	if g_privacy_loaded {
		return
	}
	g_privacy_loaded = true
	path := user_config_toml_path(context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		g_privacy_share = false
		return
	}
	// crude scan for coding_data_share = true under any section
	text := string(data)
	lower := strings.to_lower(text, context.temp_allocator)
	if strings.contains(lower, "coding_data_share") {
		// find line
		start := 0
		for i := 0; i <= len(text); i += 1 {
			if i == len(text) || text[i] == '\n' {
				line := strings.trim_space(text[start:i])
				ll := strings.to_lower(line, context.temp_allocator)
				if strings.has_prefix(ll, "coding_data_share") {
					if strings.contains(ll, "true") || strings.contains(ll, "1") {
						g_privacy_share = true
					} else {
						g_privacy_share = false
					}
					return
				}
				start = i + 1
			}
		}
	}
	g_privacy_share = false
}

privacy_coding_data_share :: proc() -> bool {
	privacy_load_from_config()
	return g_privacy_share
}

// set_privacy_coding_data_share updates process + persists [privacy].
set_privacy_coding_data_share :: proc(on: bool) -> string {
	g_privacy_share = on
	g_privacy_loaded = true
	if !ui_persist_enabled() {
		return ""
	}
	val := "true" if on else "false"
	return upsert_section_toml_key("[privacy]", "coding_data_share", val)
}

// privacy_status_text for /privacy.
privacy_status_text :: proc(allocator := context.allocator) -> string {
	privacy_load_from_config()
	share := "opt-in (coding_data_share=true)" if g_privacy_share else "opt-out (coding_data_share=false, default)"
	return fmt.aprintf(
		"## privacy\n" +
		"coding data share: %s\n" +
		"Sessions/memory stay under ~/.grok (local files).\n" +
		"Inference uses your login or XAI_API_KEY only.\n" +
		"There is no remote Grok coding-data preference API in Aether.\n" +
		"Usage: /privacy [opt-in|opt-out]\n",
		share,
		allocator = allocator,
	)
}
