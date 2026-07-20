// Package tui — Grok-shaped tool card titles for scrollback.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
//
// Collapsed headers mirror Grok Build tool blocks:
//   Read path · $ command · Edited path · Wrote path · …
// rather than raw "▸ [tool] read_file · args…".
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:path/filepath"
import "core:strings"

// tool_args_json: args blob from rebuild body ("args: …\n---\nRESULT" or args-only).
tool_args_json :: proc(body: string) -> string {
	t := strings.trim_space(body)
	if strings.has_prefix(t, "args:") {
		rest := strings.trim_left_space(t[len("args:"):])
		if idx := strings.index(rest, "\n---\n"); idx >= 0 {
			return strings.trim_space(rest[:idx])
		}
		// first line only if multi-line without ---
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			return strings.trim_space(rest[:nl])
		}
		return rest
	}
	return ""
}

// json_string_field: light extract of "key":"value" from tool args JSON.
// Handles optional spaces; returns unescaped path-ish strings (no full JSON decode).
json_string_field :: proc(json, key: string) -> string {
	if json == "" || key == "" {
		return ""
	}
	// "key"
	needle := fmt.tprintf("\"%s\"", key)
	i := strings.index(json, needle)
	if i < 0 {
		return ""
	}
	rest := json[i + len(needle):]
	// skip whitespace and :
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != ':' {
		return ""
	}
	rest = rest[1:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != '"' {
		return ""
	}
	rest = rest[1:]
	// read until unescaped "
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	esc := false
	for j in 0 ..< len(rest) {
		c := rest[j]
		if esc {
			switch c {
			case 'n':
				strings.write_byte(&b, '\n')
			case 't':
				strings.write_byte(&b, '\t')
			case 'r':
				strings.write_byte(&b, '\r')
			case '"', '\\', '/':
				strings.write_byte(&b, c)
			case:
				strings.write_byte(&b, c)
			}
			esc = false
			continue
		}
		if c == '\\' {
			esc = true
			continue
		}
		if c == '"' {
			return strings.to_string(b)
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// tool_path_display: basename for long paths (Grok collapsed header style).
tool_path_display :: proc(path: string) -> string {
	p := strings.trim_space(path)
	if p == "" {
		return ""
	}
	// collapse home later if needed; basename is enough for short headers
	base := filepath.base(p)
	if base == "" || base == "." || base == "/" {
		return p
	}
	// keep short relative paths as-is
	if !strings.contains(p, "/") && !strings.contains(p, "\\") {
		return p
	}
	// if short enough, show full relative-ish path
	if len(p) <= 40 {
		return p
	}
	return base
}

// tool_display_title: one-line Grok-shaped title for a tool card.
// body is rebuild format (args / result); failed adds muted " · fail" at call site if needed.
tool_display_title :: proc(name, body: string) -> string {
	args := tool_args_json(body)
	n := name if name != "" else "tool"

	switch n {
	case "read_file":
		path := json_string_field(args, "target_file")
		if path == "" {
			path = json_string_field(args, "file_path")
		}
		if path != "" {
			return fmt.tprintf("Read %s", tool_path_display(path))
		}
		return "Read"
	case "run_terminal_cmd", "bash", "shell":
		cmd := json_string_field(args, "command")
		cmd = strings.trim_space(cmd)
		if cmd == "" {
			return "$ …"
		}
		// flatten newlines; cap length
		cmd, _ = strings.replace_all(cmd, "\n", " ", context.temp_allocator)
		if len(cmd) > 72 {
			cmd = fmt.tprintf("%s…", cmd[:71])
		}
		return fmt.tprintf("$ %s", cmd)
	case "search_replace":
		path := json_string_field(args, "file_path")
		if path == "" {
			path = json_string_field(args, "target_file")
		}
		if path != "" {
			return fmt.tprintf("Edited %s", tool_path_display(path))
		}
		return "Edited"
	case "write":
		path := json_string_field(args, "file_path")
		if path == "" {
			path = json_string_field(args, "path")
		}
		if path != "" {
			return fmt.tprintf("Wrote %s", tool_path_display(path))
		}
		return "Wrote"
	case "delete_file":
		path := json_string_field(args, "target_file")
		if path == "" {
			path = json_string_field(args, "file_path")
		}
		if path != "" {
			return fmt.tprintf("Deleted %s", tool_path_display(path))
		}
		return "Deleted"
	case "grep":
		pat := json_string_field(args, "pattern")
		if pat != "" {
			if len(pat) > 40 {
				pat = fmt.tprintf("%s…", pat[:39])
			}
			return fmt.tprintf("Searched %s", pat)
		}
		return "Searched"
	case "glob":
		pat := json_string_field(args, "glob_pattern")
		if pat == "" {
			pat = json_string_field(args, "pattern")
		}
		if pat != "" {
			return fmt.tprintf("Glob %s", pat)
		}
		return "Glob"
	case "list_dir":
		path := json_string_field(args, "target_directory")
		if path == "" {
			path = json_string_field(args, "path")
		}
		if path != "" {
			return fmt.tprintf("Listed %s", tool_path_display(path))
		}
		return "Listed"
	case "web_search":
		q := json_string_field(args, "query")
		if q != "" {
			if len(q) > 48 {
				q = fmt.tprintf("%s…", q[:47])
			}
			return fmt.tprintf("Searched web %s", q)
		}
		return "Searched web"
	case "web_fetch":
		url := json_string_field(args, "url")
		if url != "" {
			if len(url) > 48 {
				url = fmt.tprintf("%s…", url[:47])
			}
			return fmt.tprintf("Fetched %s", url)
		}
		return "Fetched"
	case "todo_write", "todo":
		return "Todos"
	case "lsp":
		op := json_string_field(args, "operation")
		if op != "" {
			return fmt.tprintf("LSP %s", op)
		}
		return "LSP"
	case "spawn_subagent", "task":
		desc := json_string_field(args, "description")
		if desc == "" {
			desc = json_string_field(args, "subagent_type")
		}
		if desc != "" {
			return fmt.tprintf("Task %s", desc)
		}
		return "Task"
	case "skill":
		sk := json_string_field(args, "skill")
		if sk != "" {
			return fmt.tprintf("Skill %s", sk)
		}
		return "Skill"
	case "use_tool":
		tn := json_string_field(args, "tool_name")
		if tn != "" {
			return fmt.tprintf("MCP %s", tn)
		}
		return "MCP"
	case "search_tool":
		q := json_string_field(args, "query")
		if q != "" {
			return fmt.tprintf("MCP search %s", q)
		}
		return "MCP search"
	case "memory_search":
		q := json_string_field(args, "query")
		if q != "" {
			return fmt.tprintf("Memory %s", q)
		}
		return "Memory"
	case "memory_get":
		path := json_string_field(args, "path")
		if path != "" {
			return fmt.tprintf("Memory %s", tool_path_display(path))
		}
		return "Memory"
	case "image_gen", "image_edit":
		return "Imagine"
	case "image_to_video", "reference_to_video":
		return "Video"
	case "enter_plan_mode":
		return "Enter plan mode"
	case "exit_plan_mode":
		return "Exit plan mode"
	case "monitor":
		return "Monitor"
	case "scheduler_create", "scheduler_list", "scheduler_delete":
		return "Scheduler"
	case "update_goal":
		return "Goal"
	}

	// Fallback: humanize snake_case tool name (no [tool] wrapper).
	return tool_humanize_name(n)
}

// tool_humanize_name: "run_terminal_cmd" → "Run terminal cmd"
tool_humanize_name :: proc(name: string) -> string {
	if name == "" {
		return "Tool"
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	cap_next := true
	for r in name {
		if r == '_' || r == '-' {
			strings.write_byte(&b, ' ')
			cap_next = true
			continue
		}
		if cap_next && r >= 'a' && r <= 'z' {
			strings.write_rune(&b, r - 32)
			cap_next = false
		} else {
			strings.write_rune(&b, r)
			cap_next = false
		}
	}
	return strings.to_string(b)
}
