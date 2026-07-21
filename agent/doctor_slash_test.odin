// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_doctor_cmd_ok_true_false :: proc(t: ^testing.T) {
	// sh always exists on our targets
	testing.expect(t, doctor_cmd_ok("sh") || doctor_cmd_ok("bash"))
	testing.expect(t, !doctor_cmd_ok(""))
	testing.expect(t, !doctor_cmd_ok("this-binary-should-not-exist-xyzzy-aether"))
}

@(test)
test_handle_doctor_slash_basic :: proc(t: ^testing.T) {
	out := handle_doctor_slash(nil, ".", context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "aether doctor"), "got: %s", out)
	testing.expect(t, strings.contains(out, "summary:"))
	testing.expect(t, strings.contains(out, "auth") || strings.contains(out, "[fail]") || strings.contains(out, "[ok]"))
	testing.expect(t, strings.contains(out, "ripgrep") || strings.contains(out, "rg"))
	// B39 optional host tools section
	testing.expect(t, strings.contains(out, "curl"), out)
	testing.expect(t, strings.contains(out, "gh"), out)
	testing.expect(t, strings.contains(out, "docker"), out)
	testing.expect(t, strings.contains(out, "clipboard"), out)
	testing.expect(t, strings.contains(out, "notify-send") || strings.contains(out, "notify"), out)
}
