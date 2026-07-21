// Package tools — tool pack selection (M5 hashline opt-in).
// AETHER_TOOL_PACK=hashline (or standard/default) selects schema surface.
// Hashline pack mutually excludes standard read_file / search_replace / grep.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:os"
import "core:strings"

Tool_Pack :: enum {
	Standard,
	Hashline,
}

// tool_pack_from_env: AETHER_TOOL_PACK=hashline|standard (default standard).
tool_pack_from_env :: proc() -> Tool_Pack {
	v := strings.to_lower(
		strings.trim_space(os.get_env("AETHER_TOOL_PACK", context.temp_allocator)),
		context.temp_allocator,
	)
	switch v {
	case "hashline", "hash", "hl":
		return .Hashline
	case "", "standard", "default", "grok", "grokbuild":
		return .Standard
	}
	return .Standard
}

tool_pack_string :: proc(p: Tool_Pack) -> string {
	switch p {
	case .Standard:
		return "standard"
	case .Hashline:
		return "hashline"
	}
	return "standard"
}

// Package-level deny lists (safe to slice; not stack compound literals).
PACK_DENY_WHEN_HASHLINE := [5]string{"read_file", "search_replace", "grep", "write", "delete_file"}
PACK_DENY_WHEN_STANDARD := [3]string{"hashline_read", "hashline_edit", "hashline_grep"}

// deny_for_tool_pack: names to strip from schema when pack is active.
deny_for_tool_pack :: proc(p: Tool_Pack) -> []string {
	switch p {
	case .Hashline:
		// Mutual exclusion with standard edit/read/search
		return PACK_DENY_WHEN_HASHLINE[:]
	case .Standard:
		return PACK_DENY_WHEN_STANDARD[:]
	}
	return nil
}
