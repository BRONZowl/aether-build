package tools

// delete_file — remove a single file within the workspace (not directories).

import "core:fmt"
import "core:os"
import "core:strings"

tool_delete_file :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	// Accept target_file (Cursor) or file_path (alias)
	path := jstr(obj, "target_file")
	if path == "" {
		path = jstr(obj, "file_path")
	}
	if path == "" {
		return strings.clone("error: target_file is required", allocator)
	}

	abs, inside := resolve_in_workspace(workspace, path, context.temp_allocator)
	if !inside {
		return strings.clone("error: deletes outside workspace are denied", allocator)
	}

	if !os.exists(abs) {
		return fmt.aprintf("error: file not found: %s", path, allocator = allocator)
	}
	if os.is_directory(abs) {
		return fmt.aprintf(
			"error: %s is a directory (delete_file only removes files)",
			path,
			allocator = allocator,
		)
	}
	file_rewind_push_before_mutation(abs, path, .Delete)
	if err := os.remove(abs); err != nil {
		return fmt.aprintf("error: delete failed: %v", err, allocator = allocator)
	}
	return fmt.aprintf("Deleted file %s.", path, allocator = allocator)
}
