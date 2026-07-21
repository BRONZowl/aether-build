// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_handle_features_slash_basic :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()
	out := handle_features_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether features"), out)
	testing.expect(t, strings.contains(out, "bash-soft"), out)
	testing.expect(t, strings.contains(out, "memory"), out)
	testing.expect(t, strings.contains(out, "plan-mode"), out)
	testing.expect(t, strings.contains(out, "subagents"), out)
}

@(test)
test_handle_features_slash_help :: proc(t: ^testing.T) {
	out := handle_features_slash("help", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /features"), out)
}

@(test)
test_handle_features_slash_filter :: proc(t: ^testing.T) {
	out := handle_features_slash("bash", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "bash-soft"), out)
	testing.expect(t, !strings.contains(out, "timestamps"), out)
}

@(test)
test_handle_features_slash_kill_switch :: proc(t: ^testing.T) {
	os.set_env("AETHER_NO_MCP", "1")
	defer os.unset_env("AETHER_NO_MCP")
	out := handle_features_slash("mcp", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "mcp"), out)
	// should show unset mark for mcp when kill switch set
	testing.expect(t, strings.contains(out, "·") || strings.contains(out, "AETHER_NO_MCP"), out)
}
