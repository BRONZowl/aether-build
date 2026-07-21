// Schema golden / property tests — P0 safety rails for tool registry refactor.
// Ensures tools_json_schema remains a valid JSON array and core tool names stay stable.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// CORE_TOOL_NAMES: tools always present in the default (flags-off) schema.
// Keep in sync when adding local tools to tools_json_schema.
CORE_TOOL_NAMES :: []string {
	"run_terminal_cmd",
	"read_file",
	"search_replace",
	"write",
	"delete_file",
	"grep",
	"list_dir",
	"glob",
	"web_search",
	"web_fetch",
	"todo_write",
	"ask_user_question",
	"lsp",
	"monitor",
	"scheduler_create",
	"scheduler_list",
	"scheduler_delete",
	"update_goal",
	"image_gen",
	"image_edit",
	"image_to_video",
	"reference_to_video",
}

schema_parses_as_array :: proc(schema: string) -> bool {
	val, err := json.parse(
		transmute([]byte)schema,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return false
	}
	_, ok := val.(json.Array)
	return ok
}

schema_has_tool_name :: proc(schema, name: string) -> bool {
	needle := strings.concatenate({`"name":"`, name, `"`}, context.temp_allocator)
	return strings.contains(schema, needle)
}

@(test)
test_schema_core_is_valid_json_array :: proc(t: ^testing.T) {
	schema := tools_json_schema(false, false, false, false, false, nil, context.allocator)
	defer delete(schema)
	testing.expect(t, len(schema) > 2, "schema non-empty")
	testing.expect(t, schema[0] == '[', "starts with [")
	testing.expect(t, schema[len(schema) - 1] == ']', "ends with ]")
	testing.expect(t, schema_parses_as_array(schema), "parses as JSON array")
}

@(test)
test_schema_core_contains_stable_tool_names :: proc(t: ^testing.T) {
	schema := tools_json_schema(false, false, false, false, false, nil, context.allocator)
	defer delete(schema)
	for name in CORE_TOOL_NAMES {
		testing.expectf(t, schema_has_tool_name(schema, name), "missing core tool %s", name)
	}
	// Flag-gated tools absent when flags off
	testing.expect(t, !schema_has_tool_name(schema, "spawn_subagent"))
	testing.expect(t, !schema_has_tool_name(schema, "search_tool"))
	testing.expect(t, !schema_has_tool_name(schema, "skill"))
	testing.expect(t, !schema_has_tool_name(schema, "enter_plan_mode"))
	testing.expect(t, !schema_has_tool_name(schema, "memory_search"))
}

@(test)
test_schema_flag_matrix_includes_optional_tools :: proc(t: ^testing.T) {
	// MCP
	s := tools_json_schema(true, false, false, false, false, nil, context.allocator)
	defer delete(s)
	testing.expect(t, schema_parses_as_array(s))
	testing.expect(t, schema_has_tool_name(s, "search_tool"))
	testing.expect(t, schema_has_tool_name(s, "use_tool"))
	testing.expect(t, schema_has_tool_name(s, "list_mcp_resources"))

	// Skills
	s2 := tools_json_schema(false, true, false, false, false, nil, context.allocator)
	defer delete(s2)
	testing.expect(t, schema_has_tool_name(s2, "skill"))

	// Spawn / tasks
	s3 := tools_json_schema(false, false, true, false, false, nil, context.allocator)
	defer delete(s3)
	testing.expect(t, schema_has_tool_name(s3, "spawn_subagent"))
	testing.expect(t, schema_has_tool_name(s3, "get_task_output"))
	testing.expect(t, schema_has_tool_name(s3, "kill_task"))
	testing.expect(t, schema_has_tool_name(s3, "wait_tasks"))

	// Plan
	s4 := tools_json_schema(false, false, false, true, false, nil, context.allocator)
	defer delete(s4)
	testing.expect(t, schema_has_tool_name(s4, "enter_plan_mode"))
	testing.expect(t, schema_has_tool_name(s4, "exit_plan_mode"))

	// Memory
	s5 := tools_json_schema(false, false, false, false, true, nil, context.allocator)
	defer delete(s5)
	testing.expect(t, schema_has_tool_name(s5, "memory_search"))
	testing.expect(t, schema_has_tool_name(s5, "memory_get"))
}

@(test)
test_schema_deny_list_strips_named_tools :: proc(t: ^testing.T) {
	deny := []string{"read_file", "grep", "image_gen"}
	schema := tools_json_schema(false, false, false, false, false, deny, context.allocator)
	defer delete(schema)
	testing.expect(t, schema_parses_as_array(schema))
	testing.expect(t, !schema_has_tool_name(schema, "read_file"))
	testing.expect(t, !schema_has_tool_name(schema, "grep"))
	testing.expect(t, !schema_has_tool_name(schema, "image_gen"))
	// Unrelated core tools remain
	testing.expect(t, schema_has_tool_name(schema, "write"))
	testing.expect(t, schema_has_tool_name(schema, "list_dir"))
}

@(test)
test_schema_hashline_pack_when_env_set :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_TOOL_PACK", context.temp_allocator)
	_ = os.set_env("AETHER_TOOL_PACK", "hashline")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_TOOL_PACK")
		} else {
			_ = os.set_env("AETHER_TOOL_PACK", prev)
		}
	}
	schema := tools_json_schema(false, false, false, false, false, nil, context.allocator)
	defer delete(schema)
	testing.expect(t, schema_parses_as_array(schema))
	testing.expect(t, schema_has_tool_name(schema, "hashline_read"))
	testing.expect(t, schema_has_tool_name(schema, "hashline_edit"))
	testing.expect(t, schema_has_tool_name(schema, "hashline_grep"))
}

@(test)
test_schema_all_flags_on_is_valid :: proc(t: ^testing.T) {
	schema := tools_json_schema(true, true, true, true, true, nil, context.allocator)
	defer delete(schema)
	testing.expect(t, schema_parses_as_array(schema))
	testing.expect(t, schema_has_tool_name(schema, "read_file"))
	testing.expect(t, schema_has_tool_name(schema, "search_tool"))
	testing.expect(t, schema_has_tool_name(schema, "skill"))
	testing.expect(t, schema_has_tool_name(schema, "spawn_subagent"))
	testing.expect(t, schema_has_tool_name(schema, "enter_plan_mode"))
	testing.expect(t, schema_has_tool_name(schema, "memory_search"))
}
