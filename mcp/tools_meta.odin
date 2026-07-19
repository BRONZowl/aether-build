package mcp

import "core:fmt"
import "core:strings"
import "core:time"

Search_Hit :: struct {
	score: int,
	idx:   int,
}

// meta_tools_json_schema OpenAI tools entries for MCP meta tools.
meta_tools_json_schema :: proc() -> string {
	return `,` +
		`{"type":"function","function":{"name":"search_tool","description":"Search for MCP integration tools by keyword. Returns matching qualified server__tool names and schemas.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Keywords to match against tool names and descriptions"},"limit":{"type":"integer","description":"Max results (default 5)"}},"required":["query"]}}},` +
		`{"type":"function","function":{"name":"use_tool","description":"Call an MCP integration tool. tool_name must be qualified server__tool (e.g. myserver__list). Use schemas from search_tool.","parameters":{"type":"object","properties":{"tool_name":{"type":"string"},"tool_input":{"type":"object","additionalProperties":true}},"required":["tool_name","tool_input"]}}},` +
		`{"type":"function","function":{"name":"list_mcp_resources","description":"List MCP resources discovered at connect time. Optional server filter and query.","parameters":{"type":"object","properties":{"server":{"type":"string","description":"Optional MCP server name"},"query":{"type":"string","description":"Optional keyword filter"},"limit":{"type":"integer","description":"Max results (default 20)"}},"required":[]}}},` +
		`{"type":"function","function":{"name":"read_mcp_resource","description":"Read an MCP resource by server name and uri (from list_mcp_resources).","parameters":{"type":"object","properties":{"server":{"type":"string"},"uri":{"type":"string"}},"required":["server","uri"]}}},` +
		`{"type":"function","function":{"name":"list_mcp_prompts","description":"List MCP prompts discovered at connect time. Optional server filter and query.","parameters":{"type":"object","properties":{"server":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer"}},"required":[]}}},` +
		`{"type":"function","function":{"name":"get_mcp_prompt","description":"Get an MCP prompt by server and name. Optional arguments object for prompt parameters.","parameters":{"type":"object","properties":{"server":{"type":"string"},"name":{"type":"string"},"arguments":{"type":"object","additionalProperties":true}},"required":["server","name"]}}}`
}

// handle_meta_tool runs MCP catalog/call tools against the registry.
handle_meta_tool :: proc(
	reg: ^Mcp_Registry,
	name: string,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if reg == nil {
		return strings.clone(
			"error: MCP not enabled or no servers connected — configure aether.toml [mcp] and restart",
			allocator,
		)
	}
	if len(reg.servers) == 0 && (name == "search_tool" || name == "use_tool") {
		return strings.clone(
			"error: no MCP servers connected — check aether.toml mcp config and /mcp status",
			allocator,
		)
	}
	switch name {
	case "search_tool":
		return search_tools(reg, arguments_json, allocator)
	case "use_tool":
		return use_tool(reg, arguments_json, allocator)
	case "list_mcp_resources":
		return list_mcp_resources(reg, arguments_json, allocator)
	case "read_mcp_resource":
		return read_mcp_resource(reg, arguments_json, allocator)
	case "list_mcp_prompts":
		return list_mcp_prompts(reg, arguments_json, allocator)
	case "get_mcp_prompt":
		return get_mcp_prompt(reg, arguments_json, allocator)
	case:
		return fmt.aprintf("error: unknown meta tool %s", name, allocator = allocator)
	}
}

search_tools :: proc(
	reg: ^Mcp_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	query := ""
	limit := 5
	// light parse
	if strings.contains(arguments_json, "query") {
		// extract "query":"..."
		if q, ok := extract_json_string_field(arguments_json, "query"); ok {
			query = q
		}
	}
	if n, ok := extract_json_int_field(arguments_json, "limit"); ok && n > 0 {
		limit = min(n, 50)
	}
	if query == "" {
		return strings.clone("error: query is required", allocator)
	}
	q_low := strings.to_lower(query, context.temp_allocator)
	hits := make([dynamic]Search_Hit, 0, 16, context.temp_allocator)
	for t, i in reg.tools {
		score := 0
		name_l := strings.to_lower(t.qualified, context.temp_allocator)
		desc_l := strings.to_lower(t.description, context.temp_allocator)
		if name_l == q_low {
			score = 100
		} else if strings.contains(name_l, q_low) {
			score = 50
		} else if strings.contains(desc_l, q_low) {
			score = 20
		} else {
			// token AND
			parts := strings.fields(q_low, context.temp_allocator)
			all := true
			for p in parts {
				if !strings.contains(name_l, p) && !strings.contains(desc_l, p) {
					all = false
					break
				}
			}
			if all && len(parts) > 0 {
				score = 10 * len(parts)
			}
		}
		if score > 0 {
			append(&hits, Search_Hit{score = score, idx = i})
		}
	}
	// sort by score desc (simple insertion)
	for i in 1 ..< len(hits) {
		j := i
		for j > 0 && hits[j - 1].score < hits[j].score {
			hits[j - 1], hits[j] = hits[j], hits[j - 1]
			j -= 1
		}
	}
	if len(hits) == 0 {
		return fmt.aprintf(
			"No MCP tools matched %q (%d tools registered). Try broader keywords or /mcp.",
			query,
			len(reg.tools),
			allocator = allocator,
		)
	}
	n := min(limit, len(hits))
	b := strings.builder_make(allocator)
	strings.write_string(&b, fmt.tprintf("Found %d MCP tool(s) (showing %d):\n\n", len(hits), n))
	for i in 0 ..< n {
		t := reg.tools[hits[i].idx]
		strings.write_string(&b, fmt.tprintf("### %s\n", t.qualified))
		if t.description != "" {
			strings.write_string(&b, t.description)
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, "inputSchema: ")
		sch := t.schema_json
		if len(sch) > 800 {
			sch = fmt.tprintf("%s…", sch[:800])
		}
		strings.write_string(&b, sch)
		strings.write_string(&b, "\n\n")
	}
	strings.write_string(
		&b,
		"Call with use_tool: {\"tool_name\":\"server__tool\",\"tool_input\":{...}}\n",
	)
	return strings.to_string(b)
}

use_tool :: proc(
	reg: ^Mcp_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	tool_name, ok := extract_json_string_field(arguments_json, "tool_name")
	if !ok || tool_name == "" {
		return strings.clone("error: tool_name is required", allocator)
	}
	// tool_input object — extract raw JSON object after "tool_input"
	input_json := "{}"
	if raw, rok := extract_json_object_field(arguments_json, "tool_input"); rok {
		input_json = raw
	}
	server_name, bare, pok := parse_qualified(tool_name)
	if !pok {
		return fmt.aprintf(
			"error: tool_name must be qualified server__tool (got %q). Use search_tool first.",
			tool_name,
			allocator = allocator,
		)
	}
	// find server
	srv: ^Mcp_Server
	for &s in reg.servers {
		if s.name == server_name || sanitize_name(s.name, context.temp_allocator) == server_name {
			srv = &s
			break
		}
	}
	if srv == nil {
		return fmt.aprintf("error: MCP server %q not connected", server_name, allocator = allocator)
	}
	// prefer exact registered tool name
	call_name := bare
	for t in reg.tools {
		if t.qualified == tool_name ||
		   (sanitize_name(t.server, context.temp_allocator) == server_name && t.name == bare) {
			call_name = t.name
			break
		}
	}
	return server_call_tool(srv, call_name, input_json, 120 * time.Second, allocator)
}

find_mcp_server :: proc(reg: ^Mcp_Registry, server_name: string) -> ^Mcp_Server {
	if reg == nil || server_name == "" {
		return nil
	}
	for &s in reg.servers {
		if s.name == server_name || sanitize_name(s.name, context.temp_allocator) == server_name {
			return &s
		}
	}
	return nil
}

list_mcp_resources :: proc(
	reg: ^Mcp_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	server_f, _ := extract_json_string_field(arguments_json, "server")
	query, _ := extract_json_string_field(arguments_json, "query")
	limit := 20
	if n, ok := extract_json_int_field(arguments_json, "limit"); ok && n > 0 {
		limit = min(n, 100)
	}
	q_low := strings.to_lower(query, context.temp_allocator)
	// First pass count
	total := 0
	for r in reg.resources {
		if server_f != "" &&
		   r.server != server_f &&
		   sanitize_name(r.server, context.temp_allocator) != server_f {
			continue
		}
		if q_low != "" {
			blob := strings.to_lower(
				fmt.tprintf("%s %s %s %s", r.uri, r.name, r.description, r.server),
				context.temp_allocator,
			)
			if !strings.contains(blob, q_low) {
				continue
			}
		}
		total += 1
	}
	if total == 0 {
		return fmt.aprintf(
			"No MCP resources matched (registry has %d). Servers without resources/list stay empty.",
			len(reg.resources),
			allocator = allocator,
		)
	}
	b := strings.builder_make(allocator)
	shown := 0
	strings.write_string(&b, fmt.tprintf("Found %d resource(s) (showing up to %d):\n\n", total, limit))
	for r in reg.resources {
		if shown >= limit {
			break
		}
		if server_f != "" &&
		   r.server != server_f &&
		   sanitize_name(r.server, context.temp_allocator) != server_f {
			continue
		}
		if q_low != "" {
			blob := strings.to_lower(
				fmt.tprintf("%s %s %s %s", r.uri, r.name, r.description, r.server),
				context.temp_allocator,
			)
			if !strings.contains(blob, q_low) {
				continue
			}
		}
		strings.write_string(
			&b,
			fmt.tprintf(
				"- server=%s uri=%s name=%s mime=%s\n  %s\n",
				r.server,
				r.uri,
				r.name if r.name != "" else "(unnamed)",
				r.mime_type if r.mime_type != "" else "-",
				r.description,
			),
		)
		shown += 1
	}
	return strings.to_string(b)
}

read_mcp_resource :: proc(
	reg: ^Mcp_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	server_name, _ := extract_json_string_field(arguments_json, "server")
	uri, _ := extract_json_string_field(arguments_json, "uri")
	if server_name == "" || uri == "" {
		return strings.clone("error: server and uri are required", allocator)
	}
	srv := find_mcp_server(reg, server_name)
	if srv == nil {
		return fmt.aprintf("error: MCP server %q not connected", server_name, allocator = allocator)
	}
	return server_read_resource(srv, uri, 120 * time.Second, allocator)
}

list_mcp_prompts :: proc(
	reg: ^Mcp_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	server_f, _ := extract_json_string_field(arguments_json, "server")
	query, _ := extract_json_string_field(arguments_json, "query")
	limit := 20
	if n, ok := extract_json_int_field(arguments_json, "limit"); ok && n > 0 {
		limit = min(n, 100)
	}
	q_low := strings.to_lower(query, context.temp_allocator)
	total := 0
	for p in reg.prompts {
		if server_f != "" &&
		   p.server != server_f &&
		   sanitize_name(p.server, context.temp_allocator) != server_f {
			continue
		}
		if q_low != "" {
			blob := strings.to_lower(
				fmt.tprintf("%s %s %s", p.name, p.description, p.server),
				context.temp_allocator,
			)
			if !strings.contains(blob, q_low) {
				continue
			}
		}
		total += 1
	}
	if total == 0 {
		return fmt.aprintf(
			"No MCP prompts matched (registry has %d). Servers without prompts/list stay empty.",
			len(reg.prompts),
			allocator = allocator,
		)
	}
	b := strings.builder_make(allocator)
	shown := 0
	strings.write_string(&b, fmt.tprintf("Found %d prompt(s) (showing up to %d):\n\n", total, limit))
	for p in reg.prompts {
		if shown >= limit {
			break
		}
		if server_f != "" &&
		   p.server != server_f &&
		   sanitize_name(p.server, context.temp_allocator) != server_f {
			continue
		}
		if q_low != "" {
			blob := strings.to_lower(
				fmt.tprintf("%s %s %s", p.name, p.description, p.server),
				context.temp_allocator,
			)
			if !strings.contains(blob, q_low) {
				continue
			}
		}
		strings.write_string(
			&b,
			fmt.tprintf(
				"- server=%s name=%s\n  %s\n  arguments: %s\n",
				p.server,
				p.name,
				p.description,
				p.arguments_json if p.arguments_json != "" else "[]",
			),
		)
		shown += 1
	}
	return strings.to_string(b)
}

get_mcp_prompt :: proc(
	reg: ^Mcp_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	server_name, _ := extract_json_string_field(arguments_json, "server")
	name, _ := extract_json_string_field(arguments_json, "name")
	if server_name == "" || name == "" {
		return strings.clone("error: server and name are required", allocator)
	}
	args_json := "{}"
	if raw, rok := extract_json_object_field(arguments_json, "arguments"); rok {
		args_json = raw
	}
	srv := find_mcp_server(reg, server_name)
	if srv == nil {
		return fmt.aprintf("error: MCP server %q not connected", server_name, allocator = allocator)
	}
	return server_get_prompt(srv, name, args_json, 120 * time.Second, allocator)
}

// --- tiny JSON field extractors (no full re-parse for meta args) ---

extract_json_string_field :: proc(raw: string, key: string) -> (string, bool) {
	// "key"\s*:\s*"value"
	pat := fmt.tprintf("\"%s\"", key)
	i := strings.index(raw, pat)
	if i < 0 {
		return "", false
	}
	rest := raw[i + len(pat):]
	// skip space and :
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != ':' {
		return "", false
	}
	rest = rest[1:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != '"' {
		return "", false
	}
	rest = rest[1:]
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	esc := false
	for j in 0 ..< len(rest) {
		ch := rest[j]
		if esc {
			strings.write_byte(&b, ch)
			esc = false
			continue
		}
		if ch == '\\' {
			esc = true
			continue
		}
		if ch == '"' {
			return strings.to_string(b), true
		}
		strings.write_byte(&b, ch)
	}
	return "", false
}

extract_json_int_field :: proc(raw: string, key: string) -> (int, bool) {
	pat := fmt.tprintf("\"%s\"", key)
	i := strings.index(raw, pat)
	if i < 0 {
		return 0, false
	}
	rest := raw[i + len(pat):]
	for len(rest) > 0 && rest[0] != ':' {
		rest = rest[1:]
	}
	if len(rest) == 0 {
		return 0, false
	}
	rest = rest[1:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
		rest = rest[1:]
	}
	n := 0
	got := false
	for j in 0 ..< len(rest) {
		ch := rest[j]
		if ch >= '0' && ch <= '9' {
			n = n * 10 + int(ch - '0')
			got = true
		} else if got {
			break
		} else {
			break
		}
	}
	return n, got
}

extract_json_object_field :: proc(raw: string, key: string) -> (string, bool) {
	pat := fmt.tprintf("\"%s\"", key)
	i := strings.index(raw, pat)
	if i < 0 {
		return "", false
	}
	rest := raw[i + len(pat):]
	for len(rest) > 0 && rest[0] != ':' {
		rest = rest[1:]
	}
	if len(rest) == 0 {
		return "", false
	}
	rest = rest[1:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != '{' {
		return "", false
	}
	depth := 0
	in_str := false
	esc := false
	for j in 0 ..< len(rest) {
		ch := rest[j]
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
			depth += 1
		} else if ch == '}' {
			depth -= 1
			if depth == 0 {
				return rest[:j + 1], true
			}
		}
	}
	return "", false
}
