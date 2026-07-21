// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_handle_env_slash_basic :: proc(t: ^testing.T) {
	out := handle_env_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether env"), out)
	testing.expect(t, strings.contains(out, "AETHER_NO_BASH_SOFT"), out)
	testing.expect(t, strings.contains(out, "XAI_API_KEY"), out)
	testing.expect(t, strings.contains(out, "GROK_HOME"), out)
	// never dump raw key material even if set
	testing.expect(t, !strings.contains(out, "sk-"), out)
}

@(test)
test_handle_env_slash_help :: proc(t: ^testing.T) {
	out := handle_env_slash("help", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /env"), out)
	testing.expect(t, strings.contains(out, "filter") || strings.contains(out, "set"), out)
}

@(test)
test_handle_env_slash_filter :: proc(t: ^testing.T) {
	out := handle_env_slash("bash", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "AETHER_NO_BASH_SOFT"), out)
	testing.expect(t, !strings.contains(out, "AETHER_NO_MCP"), out)
}

@(test)
test_handle_env_slash_set_only :: proc(t: ^testing.T) {
	os.set_env("AETHER_NO_BASH_SOFT", "1")
	defer os.unset_env("AETHER_NO_BASH_SOFT")
	out := handle_env_slash("set", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "AETHER_NO_BASH_SOFT"), out)
	testing.expect(t, strings.contains(out, "Y"), out)
}

@(test)
test_handle_env_slash_secret_redacted :: proc(t: ^testing.T) {
	os.set_env("XAI_API_KEY", "super-secret-value-xyz")
	defer os.unset_env("XAI_API_KEY")
	out := handle_env_slash("XAI_API", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "XAI_API_KEY"), out)
	testing.expect(t, strings.contains(out, "***"), out)
	testing.expect(t, !strings.contains(out, "super-secret-value-xyz"), out)
}
