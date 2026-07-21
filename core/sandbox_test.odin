// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_sandbox_mode_from_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_OS_SANDBOX", context.temp_allocator)
	prev_no := os.get_env("AETHER_NO_OS_SANDBOX", context.temp_allocator)
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_OS_SANDBOX", prev)
		} else {
			_ = os.unset_env("AETHER_OS_SANDBOX")
		}
		if prev_no != "" {
			_ = os.set_env("AETHER_NO_OS_SANDBOX", prev_no)
		} else {
			_ = os.unset_env("AETHER_NO_OS_SANDBOX")
		}
	}

	_ = os.unset_env("AETHER_NO_OS_SANDBOX")
	_ = os.unset_env("AETHER_OS_SANDBOX")
	testing.expect(t, sandbox_mode_from_env() == .Off)

	_ = os.set_env("AETHER_OS_SANDBOX", "soft")
	testing.expect(t, sandbox_mode_from_env() == .Soft)

	_ = os.set_env("AETHER_OS_SANDBOX", "bwrap")
	testing.expect(t, sandbox_mode_from_env() == .Bwrap)

	_ = os.set_env("AETHER_OS_SANDBOX", "landlock")
	testing.expect(t, sandbox_mode_from_env() == .Bwrap)

	_ = os.set_env("AETHER_NO_OS_SANDBOX", "1")
	testing.expect(t, sandbox_mode_from_env() == .Off)
}

@(test)
test_build_sandboxed_shell_argv_off_soft :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_OS_SANDBOX", context.temp_allocator)
	prev_no := os.get_env("AETHER_NO_OS_SANDBOX", context.temp_allocator)
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_OS_SANDBOX", prev)
		} else {
			_ = os.unset_env("AETHER_OS_SANDBOX")
		}
		if prev_no != "" {
			_ = os.set_env("AETHER_NO_OS_SANDBOX", prev_no)
		} else {
			_ = os.unset_env("AETHER_NO_OS_SANDBOX")
		}
	}

	_ = os.unset_env("AETHER_NO_OS_SANDBOX")
	_ = os.set_env("AETHER_OS_SANDBOX", "off")
	argv := build_sandboxed_shell_argv("/tmp/ws", "echo hi", context.allocator)
	defer {
		for s in argv {
			delete(s)
		}
		delete(argv)
	}
	testing.expect(t, len(argv) == 3)
	testing.expect(t, argv[0] == "sh")
	testing.expect(t, argv[1] == "-c")
	testing.expect(t, argv[2] == "echo hi")

	_ = os.set_env("AETHER_OS_SANDBOX", "soft")
	argv2 := build_sandboxed_shell_argv("/tmp/ws", "ls", context.allocator)
	defer {
		for s in argv2 {
			delete(s)
		}
		delete(argv2)
	}
	testing.expect(t, len(argv2) == 3)
	testing.expect(t, argv2[0] == "sh")
}

@(test)
test_build_sandboxed_shell_argv_bwrap_when_available :: proc(t: ^testing.T) {
	if !bwrap_available() {
		return // skip when bubblewrap not installed
	}
	prev := os.get_env("AETHER_OS_SANDBOX", context.temp_allocator)
	prev_no := os.get_env("AETHER_NO_OS_SANDBOX", context.temp_allocator)
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_OS_SANDBOX", prev)
		} else {
			_ = os.unset_env("AETHER_OS_SANDBOX")
		}
		if prev_no != "" {
			_ = os.set_env("AETHER_NO_OS_SANDBOX", prev_no)
		} else {
			_ = os.unset_env("AETHER_NO_OS_SANDBOX")
		}
	}
	_ = os.unset_env("AETHER_NO_OS_SANDBOX")
	_ = os.set_env("AETHER_OS_SANDBOX", "bwrap")
	argv := build_sandboxed_shell_argv("/tmp", "true", context.allocator)
	defer {
		for s in argv {
			delete(s)
		}
		delete(argv)
	}
	testing.expect(t, len(argv) > 3)
	testing.expect(t, argv[0] == "bwrap")
	// last three should be sh -c true
	testing.expect(t, argv[len(argv) - 3] == "sh")
	testing.expect(t, argv[len(argv) - 2] == "-c")
	testing.expect(t, argv[len(argv) - 1] == "true")
}

@(test)
test_sandbox_status_line :: proc(t: ^testing.T) {
	line := sandbox_status_line(context.allocator)
	defer delete(line)
	testing.expect(t, strings.contains(line, "os-sandbox:"))
	testing.expect(t, strings.contains(line, "AETHER_OS_SANDBOX"))
}

@(test)
test_sandbox_mode_string :: proc(t: ^testing.T) {
	testing.expect(t, sandbox_mode_string(.Off) == "off")
	testing.expect(t, sandbox_mode_string(.Soft) == "soft")
	testing.expect(t, sandbox_mode_string(.Bwrap) == "bwrap")
}
