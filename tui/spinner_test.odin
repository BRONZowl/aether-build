// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_spinner_frame_at_cycles :: proc(t: ^testing.T) {
	testing.expect(t, len(SPINNER_FRAMES) >= 4)
	for i in 0 ..< len(SPINNER_FRAMES) * 2 {
		f := spinner_frame_at(i)
		testing.expectf(t, f != "", "empty frame at tick %d", i)
		testing.expectf(t, utf8.rune_count(f) >= 1, "frame %q", f)
	}
	testing.expect(t, spinner_frame_at(0) == SPINNER_FRAMES[0])
	testing.expect(t, spinner_frame_at(len(SPINNER_FRAMES)) == SPINNER_FRAMES[0])
}

@(test)
test_spinner_status_text_streaming :: proc(t: ^testing.T) {
	idle := spinner_status_text(false, false, 0, "ready")
	testing.expect(t, idle == "ready")

	ask := spinner_status_text(true, true, 0, "approve tool?")
	testing.expect(t, ask == "approve tool?")

	busy := spinner_status_text(true, false, 0, "sampling…")
	testing.expect(t, strings.has_prefix(busy, SPINNER_FRAMES[0]))
	testing.expect(t, strings.contains(busy, "sampling…"))
}

@(test)
test_spinner_body_line :: proc(t: ^testing.T) {
	line := spinner_body_line(1)
	testing.expect(t, strings.has_prefix(line, SPINNER_FRAMES[1]))
	testing.expect(t, strings.contains(line, SPINNER_BODY_LABEL))
}
