// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_handle_soft_bash_slash_on :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()
	testing.expect(t, core.bash_soft_enabled())
	out := handle_soft_bash_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "soft-bash"), out)
	testing.expect(t, strings.contains(out, "enabled:"), out)
	testing.expect(t, strings.contains(out, "yes"), out)
	testing.expect(t, strings.contains(out, "Hard-deny") || strings.contains(out, "hard-deny"), out)
	testing.expect(t, strings.contains(out, "git") || strings.contains(out, "Auto-allow"), out)
}

@(test)
test_handle_soft_bash_slash_help :: proc(t: ^testing.T) {
	out := handle_soft_bash_slash("help", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /soft-bash"), out)
	testing.expect(t, strings.contains(out, "on|off"), out)
	testing.expect(t, strings.contains(out, "check"), out)
}

@(test)
test_handle_soft_bash_slash_process_toggle :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()

	off := handle_soft_bash_slash("off", context.allocator)
	defer delete(off)
	testing.expect(t, strings.contains(off, "soft-bash = off"), off)
	testing.expect(t, !core.bash_soft_enabled())

	on := handle_soft_bash_slash("on", context.allocator)
	defer delete(on)
	testing.expect(t, strings.contains(on, "soft-bash = on"), on)
	testing.expect(t, core.bash_soft_enabled())
}

@(test)
test_handle_soft_bash_slash_env_blocks_on :: proc(t: ^testing.T) {
	os.set_env("AETHER_NO_BASH_SOFT", "1")
	defer {
		os.unset_env("AETHER_NO_BASH_SOFT")
		core.bash_soft_clear_process_override()
	}
	core.bash_soft_clear_process_override()
	out := handle_soft_bash_slash("on", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "DISABLED") || strings.contains(out, "AETHER_NO_BASH_SOFT"), out)
	testing.expect(t, !core.bash_soft_enabled())
}

@(test)
test_handle_soft_bash_slash_off_env :: proc(t: ^testing.T) {
	os.set_env("AETHER_NO_BASH_SOFT", "1")
	defer os.unset_env("AETHER_NO_BASH_SOFT")
	out := handle_soft_bash_slash("status", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "no") || strings.contains(out, "off"), out)
}

@(test)
test_soft_bash_check_auto_allow :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()
	out := handle_soft_bash_slash("check git status", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "AUTO-ALLOW") || strings.contains(out, "auto-allow"), out)
	testing.expect(t, strings.contains(out, "git status"), out)
}

@(test)
test_soft_bash_check_hard_deny :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()
	out := handle_soft_bash_slash("check rm -rf /", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "HARD-DENY") || strings.contains(out, "hard-deny"), out)
}

@(test)
test_soft_bash_check_ask :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()
	out := handle_soft_bash_slash("check npm install lodash", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "ASK") || strings.contains(out, "ask"), out)
}

@(test)
test_soft_bash_check_usage :: proc(t: ^testing.T) {
	out := handle_soft_bash_slash("check", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage:") || strings.contains(out, "check"), out)
}

@(test)
test_soft_bash_check_when_off :: proc(t: ^testing.T) {
	os.unset_env("AETHER_NO_BASH_SOFT")
	core.bash_soft_clear_process_override()
	defer core.bash_soft_clear_process_override()
	_ = handle_soft_bash_slash("off", context.allocator)
	out := handle_soft_bash_slash("check ls", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "off") || strings.contains(out, "no soft"), out)
}
