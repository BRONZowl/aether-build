// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_handle_config_slash_basic :: proc(t: ^testing.T) {
	out := handle_config_slash(nil, "grok-4.5", .Ask, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether config"), out)
	testing.expect(t, strings.contains(out, "model:"), out)
	testing.expect(t, strings.contains(out, "grok-4.5"), out)
	testing.expect(t, strings.contains(out, "permission:"), out)
	testing.expect(t, strings.contains(out, "ask"), out)
	testing.expect(t, strings.contains(out, "theme:"), out)
	testing.expect(t, strings.contains(out, "GROK_HOME:"), out)
	testing.expect(t, strings.contains(out, "user config:"), out)
	testing.expect(t, strings.contains(out, "sessions:"), out)
	testing.expect(t, strings.contains(out, "memory root:"), out)
	// never dump raw API key material
	testing.expect(t, !strings.contains(out, "sk-"), out)
}

@(test)
test_handle_config_slash_env_redacts_key :: proc(t: ^testing.T) {
	prev := os.get_env("XAI_API_KEY", context.temp_allocator)
	os.set_env("XAI_API_KEY", "sk-secret-should-not-appear")
	defer {
		if prev != "" {
			os.set_env("XAI_API_KEY", prev)
		} else {
			os.unset_env("XAI_API_KEY")
		}
	}
	out := handle_config_slash(nil, "m", .Auto, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "XAI_API_KEY=***set***"), out)
	testing.expect(t, !strings.contains(out, "sk-secret-should-not-appear"), out)
	testing.expect(t, strings.contains(out, "auto"), out)
}

@(test)
test_handle_config_slash_with_session :: proc(t: ^testing.T) {
	dir := "/tmp/aether-config-slash-test"
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	sess := new_session("cfg-model", dir, dir, false, .Read_Only)
	defer destroy_session(&sess)
	out := handle_config_slash(&sess, "cfg-model", .Read_Only, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "cfg-model"), out)
	testing.expect(t, strings.contains(out, "read-only") || strings.contains(out, "read_only"), out)
	testing.expect(t, strings.contains(out, dir) || strings.contains(out, "cwd:"), out)
	_ = core.version_string() // keep core import used if compiler is picky
}
