// Package tools — local tool registry for the headless agent.
// Rust reference: xai-grok-tools (GrokBuild implementations).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

DEFAULT_OUTPUT_CAP :: 40_000
DEFAULT_BASH_CAP :: 20_000

// tools_json_schema returns the OpenAI-style tools array JSON for chat completions.
// Built from TOOL_REGISTRY (tools/registry.odin). deny_names removes tools by name
// (e.g. search_replace for explore subagents). Pack mutual-exclusion is applied too.
tools_json_schema :: proc(
	with_mcp := false,
	with_skills := false,
	with_spawn := false,
	with_plan := false,
	with_memory := false,
	deny_names: []string = nil,
	allocator := context.allocator,
) -> string {
	return tools_json_schema_from_registry(
		with_mcp,
		with_skills,
		with_spawn,
		with_plan,
		with_memory,
		deny_names,
		allocator,
	)
}

// filter_tools_schema removes function tools whose name is in deny_names.
filter_tools_schema :: proc(schema: string, deny_names: []string, allocator := context.allocator) -> string {
	// Split on `},{"type":"function"` boundaries — fragile but schema is controlled.
	// Safer: rebuild by checking each `"name":"X"` for deny.
	// Walk objects: for each `"function":{"name":"FOO"` if FOO denied skip until matching depth.
	if len(schema) < 2 || schema[0] != '[' {
		return strings.clone(schema, allocator)
	}
	inner := schema[1:len(schema) - 1]
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	// split top-level objects by tracking braces
	start := 0
	depth := 0
	in_str := false
	esc := false
	for i in 0 ..< len(inner) {
		ch := inner[i]
		if in_str {
			if esc {
				esc = false
				continue
			}
			if ch == '\\' {
				esc = true
				continue
			}
			if ch == '"' {
				in_str = false
			}
			continue
		}
		if ch == '"' {
			in_str = true
			continue
		}
		if ch == '{' {
			if depth == 0 {
				start = i
			}
			depth += 1
		} else if ch == '}' {
			depth -= 1
			if depth == 0 {
				obj := inner[start:i + 1]
				if !tool_obj_denied(obj, deny_names) {
					append(&parts, obj)
				}
			}
		}
	}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for p, i in parts {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, p)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

tool_obj_denied :: proc(obj: string, deny_names: []string) -> bool {
	for d in deny_names {
		needle := fmt.tprintf(`"name":"%s"`, d)
		if strings.contains(obj, needle) {
			return true
		}
	}
	return false
}

// tool_name_denied reports whether name is in deny list.
tool_name_denied :: proc(name: string, deny_names: []string) -> bool {
	for d in deny_names {
		if d == name {
			return true
		}
	}
	return false
}

// dispatch runs a local tool by name with JSON arguments string.
// Agent-owned tools (local=false in TOOL_REGISTRY) are handled in agent/loop.
// workspace is the absolute cwd for path safety.
dispatch :: proc(
	name: string,
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	switch name {
	case "run_terminal_cmd":
		return tool_run_terminal_cmd(arguments_json, workspace, allocator)
	case "read_file":
		return tool_read_file(arguments_json, workspace, allocator)
	case "search_replace":
		return tool_search_replace(arguments_json, workspace, allocator)
	case "write":
		return tool_write(arguments_json, workspace, allocator)
	case "delete_file":
		return tool_delete_file(arguments_json, workspace, allocator)
	case "grep":
		return tool_grep(arguments_json, workspace, allocator)
	case "list_dir":
		return tool_list_dir(arguments_json, workspace, allocator)
	case "glob":
		return tool_glob(arguments_json, workspace, allocator)
	case "web_search":
		return tool_web_search(arguments_json, allocator)
	case "web_fetch":
		return tool_web_fetch_stub(arguments_json, allocator)
	case "todo_write":
		return tool_todo_write(arguments_json, allocator)
	case "lsp":
		return tool_lsp(arguments_json, workspace, allocator)
	case "memory_search":
		return tool_memory_search(arguments_json, workspace, allocator)
	case "memory_get":
		return tool_memory_get(arguments_json, allocator)
	case "hashline_read":
		return tool_hashline_read(arguments_json, workspace, allocator)
	case "hashline_edit":
		return tool_hashline_edit(arguments_json, workspace, allocator)
	case "hashline_grep":
		return tool_hashline_grep(arguments_json, workspace, allocator)
	case:
		return fmt.aprintf("unknown tool: %s", name, allocator = allocator)
	}
}

// --- shared JSON helpers ---

json_obj :: proc(arguments_json: string) -> (json.Object, bool) {
	val, err := json.parse(
		transmute([]byte)arguments_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return nil, false
	}
	obj, ok := val.(json.Object)
	return obj, ok
}

jstr :: proc(obj: json.Object, key: string, default := "") -> string {
	v, ok := obj[key]
	if !ok {
		return default
	}
	s, is_str := v.(json.String)
	if is_str {
		return string(s)
	}
	return default
}

jbool :: proc(obj: json.Object, key: string, default := false) -> bool {
	v, ok := obj[key]
	if !ok {
		return default
	}
	#partial switch b in v {
	case json.Boolean:
		return bool(b)
	case json.String:
		return string(b) == "true" || string(b) == "1"
	}
	return default
}

jint :: proc(obj: json.Object, key: string, default := 0) -> int {
	v, ok := obj[key]
	if !ok {
		return default
	}
	#partial switch n in v {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	case json.String:
		parsed, ok2 := parse_positive_int(string(n))
		if ok2 {
			return parsed
		}
	}
	return default
}

parse_positive_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	n := 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n * 10 + int(ch - '0')
	}
	return n, true
}

// resolve_in_workspace resolves path relative to workspace; returns path and whether inside workspace.
// Relative paths are always treated as inside (joined under workspace). Absolute paths must stay under workspace.
resolve_in_workspace :: proc(
	workspace: string,
	path: string,
	allocator := context.allocator,
) -> (abs: string, inside: bool) {
	p := path
	if p == "" {
		p = "."
	}

	// Relative → join under workspace (always allowed)
	if !os.is_absolute_path(p) {
		j, jerr := filepath.join({workspace, p}, allocator)
		if jerr != nil {
			return strings.clone(p, allocator), false
		}
		return j, true
	}

	// Absolute path: must be under workspace root
	ws := workspace
	if ws_abs, werr := filepath.abs(workspace, context.temp_allocator); werr == nil {
		ws = ws_abs
	}
	target := p
	if t_abs, terr := filepath.abs(p, context.temp_allocator); terr == nil {
		target = t_abs
	}

	if target == ws {
		return strings.clone(target, allocator), true
	}
	// require path separator after workspace prefix (avoid /tmp/foo matching /tmp/foobar)
	if strings.has_prefix(target, ws) && len(target) > len(ws) {
		ch := target[len(ws)]
		if ch == '/' || ch == '\\' {
			return strings.clone(target, allocator), true
		}
	}
	return strings.clone(target, allocator), false
}

cap_output :: proc(s: string, max: int, allocator := context.allocator) -> string {
	if len(s) <= max {
		return strings.clone(s, allocator)
	}
	return fmt.aprintf("%s\n...[truncated %d bytes]", s[:max], len(s) - max, allocator = allocator)
}
