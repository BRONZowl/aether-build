// Package tui — word-wrap regression tests (soft-wrap must not drop first letter).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"

@(test)
test_wrap_soft_keeps_first_letter :: proc(t: ^testing.T) {
	// width 8: "Hello " fits; "World" wraps — must start with W not o
	lines := wrap_text_lines("Hello World", 8, context.temp_allocator)
	testing.expect(t, len(lines) >= 2, "expected wrap to two+ lines")
	joined := strings.join(lines, "|", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Hello"), joined)
	testing.expect(t, strings.contains(joined, "World"), joined)
	testing.expect(t, !strings.contains(joined, "orld") || strings.contains(joined, "World"), joined)
	// Second line must begin with W
	found_world_line := false
	for ln in lines {
		if strings.has_prefix(strings.trim_left_space(ln), "World") {
			found_world_line = true
			break
		}
		if strings.has_prefix(ln, "orld") {
			testing.expect(t, false, "dropped first letter: line starts with orld")
		}
	}
	testing.expect(t, found_world_line, joined)
}

@(test)
test_wrap_long_token_hard_break :: proc(t: ^testing.T) {
	// No spaces: hard break every 4 runes; no dropped characters overall
	src := "abcdefghij"
	lines := wrap_text_lines(src, 4, context.temp_allocator)
	rebuilt := strings.join(lines, "", context.temp_allocator)
	testing.expect(t, rebuilt == src, rebuilt)
	testing.expect(t, len(lines) >= 2)
}

@(test)
test_wrap_explicit_newline :: proc(t: ^testing.T) {
	lines := wrap_text_lines("aa\nbb", 20, context.temp_allocator)
	testing.expectf(t, len(lines) == 2, "expected 2 lines, got %d", len(lines))
	testing.expect(t, lines[0] == "aa", lines[0])
	testing.expect(t, lines[1] == "bb", lines[1])
}

@(test)
test_wrap_short_unchanged :: proc(t: ^testing.T) {
	lines := wrap_text_lines("hi", 40, context.temp_allocator)
	testing.expect(t, len(lines) == 1)
	testing.expect(t, lines[0] == "hi")
}

@(test)
test_wrap_push_preserves_world :: proc(t: ^testing.T) {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 8, context.temp_allocator)
	idxs := make([dynamic]int, 0, 8, context.temp_allocator)
	wrap_push(&out, &styles, &idxs, 0, "Hello World", .Assistant, 8, context.temp_allocator)
	joined := strings.join(out[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "World"), joined)
	testing.expect(t, !strings.has_prefix(strings.trim_space(joined), "orld"))
	for ln in out {
		testing.expect(t, !strings.has_prefix(ln, "orld"), ln)
	}
}

// Narrower width must produce more soft-wrap lines (resize reflow contract).
@(test)
test_wrap_reflows_when_width_shrinks :: proc(t: ^testing.T) {
	src := "The quick brown fox jumps over the lazy dog near the river bank."
	wide := wrap_text_lines(src, 40, context.temp_allocator)
	narrow := wrap_text_lines(src, 12, context.temp_allocator)
	testing.expect(t, len(narrow) > len(wide), "narrow should wrap to more lines")
	// All source words still present after reflow
	joined := strings.join(narrow, " ", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "quick"), joined)
	testing.expect(t, strings.contains(joined, "river"), joined)
	testing.expect(t, strings.contains(joined, "bank"), joined)
}

@(test)
test_frame_needs_full_clear_on_resize :: proc(t: ^testing.T) {
	// First paint
	testing.expect(t, frame_needs_full_clear(0, 0, 80, 24))
	testing.expect(t, frame_needs_full_clear(0, 24, 80, 24))
	// Unchanged geometry — typing path (no erase)
	testing.expect(t, !frame_needs_full_clear(80, 24, 80, 24))
	// Width or height change — resize reflow path
	testing.expect(t, frame_needs_full_clear(80, 24, 60, 24))
	testing.expect(t, frame_needs_full_clear(80, 24, 80, 40))
}

// Regression: invalid UTF-8 must not SIGILL in write_fit (resume/render path).
// Old code used rune_size(U+FFFD)=3 while only 1 invalid byte was consumed.
@(test)
test_write_fit_invalid_utf8_no_trap :: proc(t: ^testing.T) {
	buf := [5]u8{'a', 0xFF, 0xFE, 'b', 'c'}
	text := string(buf[:])
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	n := write_fit(&b, text, 10)
	s := strings.to_string(b)
	testing.expect(t, n == 5, "five source units (a, bad, bad, b, c)")
	testing.expect(t, len(s) == 5, s)
	// Truncate mid-stream
	strings.builder_reset(&b)
	n = write_fit(&b, text, 2)
	s = strings.to_string(b)
	testing.expect(t, n == 2)
	testing.expect(t, len(s) == 2)
	// Multi-byte emoji still counts as one display rune, three bytes
	emoji := "x👍y"
	strings.builder_reset(&b)
	n = write_fit(&b, emoji, 2)
	s = strings.to_string(b)
	testing.expect(t, n == 2)
	testing.expect(t, strings.has_prefix(s, "x"), s)
	testing.expect(t, len(s) == 1 + len("👍"), s)
}
