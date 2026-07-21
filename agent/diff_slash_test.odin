// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_truncate_diff_lines :: proc(t: ^testing.T) {
	src := "a\nb\nc\nd\ne\n"
	out := truncate_diff_lines(src, 3, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "a\nb\nc\n"))
	testing.expect(t, strings.contains(out, "truncated") || strings.contains(out, "…"))
	full := truncate_diff_lines("one\n", 10, context.allocator)
	defer delete(full)
	testing.expect(t, full == "one\n")
}

@(test)
test_handle_diff_slash_help :: proc(t: ^testing.T) {
	h := handle_diff_slash(".", "help", context.allocator)
	defer delete(h)
	testing.expect(t, strings.contains(h, "Usage: /diff"))
	testing.expect(t, strings.contains(h, "full"))
}

@(test)
test_handle_diff_slash_in_repo :: proc(t: ^testing.T) {
	// Workspace root is a git repo when tests run from monorepo
	out := handle_diff_slash(".", "stat", context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "git status"), "got: %s", out)
	testing.expect(t, strings.contains(out, "git diff --stat") || strings.contains(out, "diff"))
}
