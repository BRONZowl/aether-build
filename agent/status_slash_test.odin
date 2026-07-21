// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_version_slash :: proc(t: ^testing.T) {
	v := handle_version_slash(context.allocator)
	defer delete(v)
	testing.expect(t, strings.contains(v, "aether"))
	testing.expect(t, strings.contains(v, "proxy-client"))
}

@(test)
test_handle_status_slash_basic :: proc(t: ^testing.T) {
	// no session pointer
	st := handle_status_slash(nil, "grok-4.5", .Ask, context.allocator)
	defer delete(st)
	testing.expectf(t, strings.contains(st, "aether status"), "got: %s", st)
	testing.expect(t, strings.contains(st, "model:"))
	testing.expect(t, strings.contains(st, "grok-4.5"))
	testing.expect(t, strings.contains(st, "perm:"))
	testing.expect(t, strings.contains(st, "ask") || strings.contains(st, "Ask") || strings.contains(st, "perm:"))
	testing.expect(t, strings.contains(st, "memory:"))
	testing.expect(t, strings.contains(st, "hooks:"))
}

@(test)
test_plan_state_to_string_inactive :: proc(t: ^testing.T) {
	s := plan_state_to_string(plan_mode_state())
	testing.expect(t, s != "")
}
