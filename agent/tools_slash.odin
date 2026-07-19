// Package agent — /tools model tool catalog (B45).
package agent

import "core:fmt"
import "core:strings"
import "aether:tools"

// handle_tools_slash lists tools currently exposed to the model (from schema).
// Optional arg filters by substring (case-insensitive).
handle_tools_slash :: proc(arg: string, allocator := context.allocator) -> string {
	filter := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if filter == "help" || filter == "?" {
		return strings.clone(
			"Usage: /tools [filter]\n" +
			"List model tools (names + short descriptions) for this process.\n" +
			"Optional filter matches name or description (case-insensitive).",
			allocator,
		)
	}

	// Match typical turn enablement (best-effort product view).
	with_mcp := mcp_enabled_for_turn()
	with_skills := skills_enabled_for_turn()
	with_spawn := subagents_enabled()
	with_plan := plan_mode_enabled()
	with_memory := tools.memory_enabled()

	schema := tools.tools_json_schema(
		with_mcp,
		with_skills,
		with_spawn,
		with_plan,
		with_memory,
		nil,
		context.temp_allocator,
	)

	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether tools (model)\n")
	strings.write_string(
		&b,
		fmt.tprintf(
			"flags: mcp=%v skills=%v subagents=%v plan=%v memory=%v\n\n",
			with_mcp,
			with_skills,
			with_spawn,
			with_plan,
			with_memory,
		),
	)

	n := 0
	pos := 0
	for {
		name, desc, next, ok := tools_schema_next(schema, pos)
		if !ok {
			break
		}
		pos = next
		if filter != "" {
			nl := strings.to_lower(name, context.temp_allocator)
			dl := strings.to_lower(desc, context.temp_allocator)
			if !strings.contains(nl, filter) && !strings.contains(dl, filter) {
				continue
			}
		}
		n += 1
		// trim description
		d := desc
		if len(d) > 90 {
			d = fmt.tprintf("%s…", d[:90])
		}
		strings.write_string(&b, fmt.tprintf("  %-22s %s\n", name, d))
	}
	if n == 0 {
		if filter != "" {
			strings.write_string(&b, fmt.tprintf("(no tools matching %q)\n", arg))
		} else {
			strings.write_string(&b, "(no tools in schema)\n")
		}
	} else {
		strings.write_string(&b, fmt.tprintf("\n%d tool(s). Filter: /tools <substr>\n", n))
	}
	return strings.to_string(b)
}

// tools_schema_next finds next "name":"…" and nearby "description":"…" after pos.
tools_schema_next :: proc(schema: string, pos: int) -> (name, desc: string, next: int, ok: bool) {
	if pos < 0 || pos >= len(schema) {
		return "", "", pos, false
	}
	// locate function name key
	marker := `"name":"`
	i := strings.index(schema[pos:], marker)
	if i < 0 {
		return "", "", len(schema), false
	}
	i += pos + len(marker)
	// read until unescaped "
	j := i
	for j < len(schema) {
		if schema[j] == '"' && (j == i || schema[j - 1] != '\\') {
			break
		}
		j += 1
	}
	if j >= len(schema) {
		return "", "", len(schema), false
	}
	name = schema[i:j]
	// skip trivial "type":"function" names if any — we want function.name
	// Our schema uses "function":{"name":"…" so previous char context is fine.
	// description often follows soon after
	rest := schema[j:]
	dmark := `"description":"`
	di := strings.index(rest, dmark)
	// don't walk into next tool: cap search window
	nmark := `"name":"`
	ni := strings.index(rest[1:], nmark) // next name after this one
	desc = ""
	if di >= 0 && (ni < 0 || di < ni+1) {
		ds := j + di + len(dmark)
		de := ds
		for de < len(schema) {
			if schema[de] == '"' && schema[de - 1] != '\\' {
				break
			}
			de += 1
		}
		if de <= len(schema) {
			desc = schema[ds:de]
		}
	}
	return name, desc, j + 1, true
}


