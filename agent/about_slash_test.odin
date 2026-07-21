// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_about_slash :: proc(t: ^testing.T) {
	out := handle_about_slash(context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether"), out)
	testing.expect(t, strings.contains(out, "/help") || strings.contains(out, "Discover"), out)
	testing.expect(t, strings.contains(out, "/keys"), out)
	testing.expect(t, strings.contains(out, "/tools"), out)
	testing.expect(t, strings.contains(out, "/doctor") || strings.contains(out, "/soft-bash"), out)
	testing.expect(t, strings.contains(out, "proxy-client") || strings.contains(out, "version"), out)
}
