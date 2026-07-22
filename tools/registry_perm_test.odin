// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:testing"
import "aether:core"

// P2.3: registry.perm stays aligned with core.tool_class (permission SoT).
@(test)
test_registry_perm_matches_core_tool_class :: proc(t: ^testing.T) {
	for spec in TOOL_REGISTRY {
		testing.expectf(t, spec.perm != "", "registry entry %s missing perm", spec.name)
		got := core.tool_class(spec.name)
		testing.expectf(
			t,
			got == spec.perm,
			"tool %s: registry.perm=%s core.tool_class=%s",
			spec.name,
			spec.perm,
			got,
		)
	}
}

@(test)
test_tool_class_table_covers_common_tools :: proc(t: ^testing.T) {
	testing.expect(t, core.tool_class("read_file") == "Read")
	testing.expect(t, core.tool_class("write") == "Edit")
	testing.expect(t, core.tool_class("run_terminal_cmd") == "Bash")
	testing.expect(t, core.tool_class("use_tool") == "Other")
	testing.expect(t, core.is_file_edit_tool("write"))
	testing.expect(t, !core.is_file_edit_tool("image_gen"))
	testing.expect(t, core.is_write_or_shell("run_terminal_cmd"))
	testing.expect(t, core.is_write_or_shell("use_tool"))
	testing.expect(t, !core.is_write_or_shell("read_file"))
}
