// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package mcp

import "core:os"
import "core:strconv"
import "core:strings"

// append_configs_from_file parses [mcp_servers.name] blocks into out.
// Later sections with the same name replace earlier entries.
append_configs_from_file :: proc(
	out: ^[dynamic]Mcp_Server_Config,
	path: string,
	allocator := context.allocator,
) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	section := ""
	cur: Mcp_Server_Config
	cur.enabled = true
	cur.startup_timeout_sec = 30
	cur.args = make([dynamic]string, 0, 4, allocator)
	cur.env = make([dynamic][2]string, 0, 4, allocator)
	cur.headers = make([dynamic][2]string, 0, 4, allocator)
	have := false

	flush_cur :: proc(
		out: ^[dynamic]Mcp_Server_Config,
		cur: ^Mcp_Server_Config,
		have: ^bool,
		allocator := context.allocator,
	) {
		if !have^ {
			return
		}
		replaced := false
		for i in 0 ..< len(out) {
			if out[i].name == cur.name {
				destroy_server_config(&out[i])
				out[i] = cur^
				replaced = true
				break
			}
		}
		if !replaced {
			append(out, cur^)
		}
		// reset cur shell (caller owns moved strings)
		cur^ = Mcp_Server_Config {
			enabled              = true,
			startup_timeout_sec  = 30,
			args                 = make([dynamic]string, 0, 4, allocator),
			env                  = make([dynamic][2]string, 0, 4, allocator),
			headers              = make([dynamic][2]string, 0, 4, allocator),
			bearer_token_env_var = "",
		}
		have^ = false
	}

	for line in strings.split_lines(string(data), context.temp_allocator) {
		trim := strings.trim_space(line)
		if trim == "" || strings.has_prefix(trim, "#") {
			continue
		}
		if strings.has_prefix(trim, "[") && strings.has_suffix(trim, "]") {
			if have && strings.has_prefix(section, "[mcp_servers.") {
				flush_cur(out, &cur, &have, allocator)
			}
			section = trim
			if strings.has_prefix(section, "[mcp_servers.") && strings.has_suffix(section, "]") {
				inner := section[len("[mcp_servers."):len(section) - 1]
				cur.name = strings.clone(strings.trim_space(inner), allocator)
				have = true
			}
			continue
		}
		if !have || !strings.has_prefix(section, "[mcp_servers.") {
			continue
		}
		key, val, ok := split_kv(trim)
		if !ok {
			continue
		}
		switch key {
		case "command":
			delete(cur.command)
			cur.command = strings.clone(unquote(val), allocator)
		case "url":
			delete(cur.url)
			cur.url = strings.clone(unquote(val), allocator)
		case "enabled":
			v := unquote(val)
			cur.enabled = v == "true" || v == "1"
		case "startup_timeout_sec":
			if n, nok := strconv.parse_int(unquote(val)); nok && n > 0 {
				cur.startup_timeout_sec = n
			}
		case "args":
			parse_string_array(val, &cur.args, allocator)
		case "env":
			parse_env_table(val, &cur.env, allocator)
		case "headers":
			parse_env_table(val, &cur.headers, allocator)
		case "bearer_token_env_var":
			delete(cur.bearer_token_env_var)
			cur.bearer_token_env_var = strings.clone(unquote(val), allocator)
		}
	}
	if have && strings.has_prefix(section, "[mcp_servers.") {
		flush_cur(out, &cur, &have, allocator)
	} else if have {
		destroy_server_config(&cur)
	}
}

split_kv :: proc(line: string) -> (key: string, val: string, ok: bool) {
	eq := strings.index_byte(line, '=')
	if eq < 0 {
		return "", "", false
	}
	key = strings.trim_space(line[:eq])
	val = strings.trim_space(line[eq + 1:])
	return key, val, key != ""
}

unquote :: proc(s: string) -> string {
	v := strings.trim_space(s)
	if len(v) >= 2 {
		q := v[0]
		if (q == '"' || q == '\'') && v[len(v) - 1] == q {
			return v[1:len(v) - 1]
		}
	}
	return v
}

parse_string_array :: proc(val: string, out: ^[dynamic]string, allocator := context.allocator) {
	v := strings.trim_space(val)
	if strings.has_prefix(v, "[") && strings.has_suffix(v, "]") {
		inner := strings.trim_space(v[1:len(v) - 1])
		if inner == "" {
			return
		}
		start := 0
		in_q := false
		qch: u8 = 0
		for i in 0 ..< len(inner) {
			ch := inner[i]
			if in_q {
				if ch == qch {
					in_q = false
				}
				continue
			}
			if ch == '"' || ch == '\'' {
				in_q = true
				qch = ch
				continue
			}
			if ch == ',' {
				part := strings.trim_space(inner[start:i])
				if part != "" {
					append(out, strings.clone(unquote(part), allocator))
				}
				start = i + 1
			}
		}
		part := strings.trim_space(inner[start:])
		if part != "" {
			append(out, strings.clone(unquote(part), allocator))
		}
		return
	}
	if v != "" {
		append(out, strings.clone(unquote(v), allocator))
	}
}

// parse_env_table handles: { KEY = "val", OTHER = "x" }
parse_env_table :: proc(val: string, out: ^[dynamic][2]string, allocator := context.allocator) {
	v := strings.trim_space(val)
	if !strings.has_prefix(v, "{") || !strings.has_suffix(v, "}") {
		return
	}
	inner := strings.trim_space(v[1:len(v) - 1])
	if inner == "" {
		return
	}
	start := 0
	for i in 0 ..= len(inner) {
		at_end := i == len(inner)
		if !at_end && inner[i] != ',' {
			continue
		}
		part := strings.trim_space(inner[start:i] if !at_end else inner[start:])
		start = i + 1
		if part == "" {
			continue
		}
		eq := strings.index_byte(part, '=')
		if eq < 0 {
			continue
		}
		k := unquote(strings.trim_space(part[:eq]))
		vv := unquote(strings.trim_space(part[eq + 1:]))
		append(out, [2]string{strings.clone(k, allocator), strings.clone(vv, allocator)})
	}
}
