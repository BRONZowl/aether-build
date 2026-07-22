// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
// TUI loading spinner (Grok-shaped braille frames).
package tui

import "core:fmt"
import "core:strings"

// Braille progress frames (U+280B …) — one column each, match Grok turn-status.
SPINNER_FRAMES := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"}

// Advance frame about every 80ms while a turn is active.
SPINNER_NS :: i64(80_000_000)

// Body placeholder before first streamed tokens (Grok Waiting for response…).
SPINNER_BODY_LABEL :: "Waiting for response…"

// spinner_frame_at returns the braille glyph for tick (wraps).
spinner_frame_at :: proc(tick: int) -> string {
	n := len(SPINNER_FRAMES)
	if n == 0 {
		return "·"
	}
	i := tick % n
	if i < 0 {
		i += n
	}
	return SPINNER_FRAMES[i]
}

// spinner_status_prefix: "⠋ " for status bar while streaming.
spinner_status_prefix :: proc(tick: int, allocator := context.temp_allocator) -> string {
	return fmt.tprintf("%s ", spinner_frame_at(tick))
}

// spinner_body_line: "⠋ Waiting for response…" for empty live draft.
spinner_body_line :: proc(tick: int, allocator := context.temp_allocator) -> string {
	return fmt.tprintf("%s %s", spinner_frame_at(tick), SPINNER_BODY_LABEL)
}

// spinner_status_text prefixes status with a frame when streaming (not during ask).
spinner_status_text :: proc(
	streaming: bool,
	ask_active: bool,
	tick: int,
	status: string,
	allocator := context.temp_allocator,
) -> string {
	if !streaming || ask_active {
		return status
	}
	st := status if status != "" else "sampling…"
	return strings.concatenate({spinner_status_prefix(tick), st}, allocator)
}
