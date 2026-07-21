// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_estimate_tokens_and_pct :: proc(t: ^testing.T) {
	testing.expect(t, estimate_tokens(0) == 0)
	testing.expect(t, estimate_tokens(4) == 1)
	testing.expect(t, estimate_tokens(5) == 2)
	testing.expect(t, estimate_tokens(100) > estimate_tokens(40))
	testing.expect(t, context_usage_pct(0, 100) == 0)
	testing.expect(t, context_usage_pct(50, 100) == 50)
	testing.expect(t, context_usage_pct(200, 100) == 100)
	bar := usage_bar(50, context.allocator)
	defer delete(bar)
	testing.expect(t, strings.contains(bar, "#"))
	testing.expect(t, strings.contains(bar, "-"))
}

@(test)
test_format_context_status :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-ctx-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sess := new_session("test-model", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	append(&sess.msgs, Chat_Message{role = .User, content = strings.clone("hello world for context")})
	append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone("hi there reply")})

	out := format_context_status(&sess, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "usage:"), "got: %s", out)
	testing.expect(t, strings.contains(out, "messages:"))
	testing.expect(t, strings.contains(out, "test-model"))
	testing.expect(t, strings.contains(out, "tokens"))
}
