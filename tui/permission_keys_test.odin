// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_perm_options_grok_labels :: proc(t: ^testing.T) {
	// Session grants on by default
	opts := tui_perm_options(true, context.temp_allocator)
	testing.expect(t, len(opts) >= 2)
	testing.expect(t, opts[0].dec == .Once)
	testing.expect(t, strings.contains(opts[0].label, "Allow once"))
	// Paint summary has numbered radio rows
	sum := tui_perm_paint_summary("tool args", opts, 0, context.temp_allocator)
	testing.expect(t, strings.contains(sum, "1 (*)"), sum)
	testing.expect(t, strings.contains(sum, "Allow once"), sum)
	testing.expect(t, strings.contains(sum, "1-9 select"), sum)
	// Move highlight
	sum2 := tui_perm_paint_summary("tool args", opts, 1, context.temp_allocator)
	testing.expect(t, strings.contains(sum2, "2 (*)"), sum2)
	// Without grants: only allow/reject once
	opts2 := tui_perm_options(false, context.temp_allocator)
	testing.expect(t, len(opts2) == 2)
	testing.expect(t, opts2[0].dec == .Once)
	testing.expect(t, opts2[1].dec == .Deny)
	_ = core.Ask_Decision.Always
}
