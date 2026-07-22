// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"
import "core:testing"

@(test)
test_utf8_safe_prefix_ascii :: proc(t: ^testing.T) {
	s := "hello world"
	testing.expect(t, utf8_safe_prefix(s, 5) == "hello")
	testing.expect(t, utf8_safe_prefix(s, 100) == s)
	testing.expect(t, utf8_safe_prefix(s, 0) == "")
}

@(test)
test_utf8_safe_prefix_multibyte :: proc(t: ^testing.T) {
	// em dash is e2 80 94 (3 bytes)
	s := "ab—cd" // a b emdash c d
	// full string
	testing.expect(t, utf8_safe_prefix(s, len(s)) == s)
	// cut after "ab" only (drop incomplete emdash)
	// "ab" is 2 bytes; next is e2 — cut at 3 (mid lead) or 4 (mid) should yield "ab"
	testing.expect(t, utf8_safe_prefix(s, 2) == "ab")
	testing.expect(t, utf8_safe_prefix(s, 3) == "ab")
	testing.expect(t, utf8_safe_prefix(s, 4) == "ab")
	// full emdash fits at 5 bytes
	testing.expect(t, utf8_safe_prefix(s, 5) == "ab—")
}

@(test)
test_json_string_escape_invalid_utf8 :: proc(t: ^testing.T) {
	// truncated em-dash lead+cont without final byte
	bad := "x\xe2\x80y"
	esc := json_string_escape(bad, context.temp_allocator)
	// must not contain raw incomplete sequence; replacement or separate escapes
	testing.expect(t, strings.contains(esc, "x"))
	testing.expect(t, strings.contains(esc, "y"))
	testing.expect(t, strings.contains(esc, "\\ufffd") || !strings.contains(esc, "\xe2"))
	// valid escape of quotes
	q := json_string_escape(`say "hi"`, context.temp_allocator)
	testing.expect(t, q == `say \"hi\"`)
}
