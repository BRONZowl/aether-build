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

// Chat APIs reject U+0000 in message content; must not emit \u0000.
@(test)
test_json_string_escape_null_becomes_fffd :: proc(t: ^testing.T) {
	buf := [5]u8{'a', 0x00, 'b', 0x00, 'c'}
	esc := json_string_escape(string(buf[:]), context.temp_allocator)
	testing.expect(t, !strings.contains(esc, "\\u0000"), esc)
	testing.expect(t, strings.contains(esc, "\\ufffd"), esc)
	testing.expect(t, strings.contains(esc, "a") && strings.contains(esc, "c"), esc)
}

// Overlong UTF-8 (e.g. C0 AC for '/') must not be emitted raw — API JSON rejects it.
@(test)
test_json_string_escape_overlong_utf8 :: proc(t: ^testing.T) {
	// overlong encoding of 0x2f
	buf := [3]u8{'x', 0xc0, 0xac}
	esc := json_string_escape(string(buf[:]), context.temp_allocator)
	testing.expect(t, !strings.contains(esc, "\xc0"), esc)
	testing.expect(t, strings.contains(esc, "\\ufffd"), esc)
	testing.expect(t, strings.has_prefix(esc, "x"), esc)
}

@(test)
test_utf8_decode_valid_overlong_and_emoji :: proc(t: ^testing.T) {
	// overlong encoding of '/'
	ol_buf := [2]u8{0xc0, 0xac}
	_, _, ok := utf8_decode_valid(string(ol_buf[:]), 0)
	testing.expect(t, !ok)
	// thumbs up emoji (valid 4-byte)
	emoji := "👍"
	cp, n, ok2 := utf8_decode_valid(emoji, 0)
	testing.expect(t, ok2 && n == 4 && cp > 0x10000)
}
