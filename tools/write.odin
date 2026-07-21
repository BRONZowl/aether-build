// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

// write — OpenCode/Grok-shaped full-file create/overwrite.
// Reference: crates/.../opencode/write/mod.rs

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

tool_write :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	file_path := jstr(obj, "file_path")
	if file_path == "" {
		return strings.clone("error: file_path is required", allocator)
	}
	// content may be empty string; missing key → ""
	content := jstr(obj, "content")
	// If key missing, jstr returns ""; treat as empty content (valid).
	// Require key? Grok required content — empty is OK. Missing same as empty.

	abs, inside := resolve_in_workspace(workspace, file_path, context.temp_allocator)
	if !inside {
		return strings.clone("error: writes outside workspace are denied", allocator)
	}

	existed := os.exists(abs) && !os.is_directory(abs)
	file_rewind_push_before_mutation(abs, file_path, .Write)

	dir := filepath.dir(abs)
	if dir != "" && dir != "." {
		_ = os.make_directory_all(dir)
	}
	if err := os.write_entire_file(abs, transmute([]byte)content); err != nil {
		return fmt.aprintf("error: write failed: %v", err, allocator = allocator)
	}
	if existed {
		return fmt.aprintf(
			"Wrote file successfully to %s.",
			file_path,
			allocator = allocator,
		)
	}
	return fmt.aprintf("The file %s has been created.", file_path, allocator = allocator)
}
