// Package mcp — stdio + Streamable HTTP MCP client (product shell).
// JSON-RPC 2.0 over Content-Length stdio or HTTP POST (+ optional SSE body).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package mcp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

Mcp_Transport :: enum {
	Stdio,
	Http,
}

// Mcp_Server_Config is one [mcp_servers.name] block.
Mcp_Server_Config :: struct {
	name:                string,
	command:             string,
	args:                [dynamic]string,
	env:                 [dynamic][2]string, // KEY, VALUE
	headers:             [dynamic][2]string, // HTTP headers for url servers
	enabled:             bool,
	startup_timeout_sec: int,
	// url set means Streamable HTTP (preferred over command)
	url:                 string,
	// bearer_token_env_var: if set, Authorization: Bearer $ENV (HTTP)
	bearer_token_env_var: string,
}

destroy_server_config :: proc(c: ^Mcp_Server_Config) {
	delete(c.name)
	delete(c.command)
	delete(c.url)
	delete(c.bearer_token_env_var)
	for a in c.args {
		delete(a)
	}
	delete(c.args)
	for e in c.env {
		delete(e[0])
		delete(e[1])
	}
	delete(c.env)
	for h in c.headers {
		delete(h[0])
		delete(h[1])
	}
	delete(c.headers)
}

destroy_server_configs :: proc(cfgs: []Mcp_Server_Config) {
	for &c in cfgs {
		destroy_server_config(&c)
	}
	delete(cfgs)
}

// Mcp_Tool is one tools/list entry, namespaced for the model as server__tool.
Mcp_Tool :: struct {
	server:      string, // owned (server name)
	name:        string, // owned (server tool name)
	qualified:   string, // owned server__name
	description: string, // owned
	schema_json: string, // owned inputSchema JSON object or "{}"
}

destroy_tool :: proc(t: ^Mcp_Tool) {
	delete(t.server)
	delete(t.name)
	delete(t.qualified)
	delete(t.description)
	delete(t.schema_json)
}

// Mcp_Resource is one resources/list entry.
Mcp_Resource :: struct {
	server:      string,
	uri:         string,
	name:        string,
	description: string,
	mime_type:   string,
}

destroy_resource :: proc(r: ^Mcp_Resource) {
	delete(r.server)
	delete(r.uri)
	delete(r.name)
	delete(r.description)
	delete(r.mime_type)
}

// Mcp_Prompt is one prompts/list entry.
Mcp_Prompt :: struct {
	server:         string,
	name:           string,
	description:    string,
	arguments_json: string, // raw arguments array JSON or "[]"
}

destroy_prompt :: proc(p: ^Mcp_Prompt) {
	delete(p.server)
	delete(p.name)
	delete(p.description)
	delete(p.arguments_json)
}

MAX_MCP_CATALOG :: 200
MAX_MCP_RESOURCE_BYTES :: 64_000

// Auth source label for /mcp status (never a secret).
Mcp_Auth_Source :: enum {
	None,
	Headers, // explicit Authorization after expand
	Env, // bearer_token_env_var
	Credentials, // mcp_credentials.json
}

// Mcp_Server is a live connection (stdio or HTTP).
Mcp_Server :: struct {
	name:       string,
	kind:       Mcp_Transport,
	// stdio
	child:      os.Process,
	stdin_w:    ^os.File, // parent write → child stdin
	stdout_r:   ^os.File, // parent read ← child stdout
	// http
	url:        string,
	headers:    [dynamic][2]string,
	session_id: string, // Mcp-Session-Id from server
	auth_source: Mcp_Auth_Source,
	// shared
	next_id:    int,
	alive:      bool,
	tools:      [dynamic]Mcp_Tool,
	resources:  [dynamic]Mcp_Resource,
	prompts:    [dynamic]Mcp_Prompt,
}

// Mcp_Registry holds all connected servers + flat tool/resource/prompt index.
Mcp_Registry :: struct {
	servers:   [dynamic]Mcp_Server,
	// flat lists across servers (copies)
	tools:     [dynamic]Mcp_Tool,
	resources: [dynamic]Mcp_Resource,
	prompts:   [dynamic]Mcp_Prompt,
}

// g_registry process-global for slash / tools (set by host).
g_registry: ^Mcp_Registry

set_registry :: proc(r: ^Mcp_Registry) {
	g_registry = r
}

get_registry :: proc() -> ^Mcp_Registry {
	return g_registry
}

// qualify_tool_name builds server__tool (sanitize server).
qualify_tool_name :: proc(server, tool: string, allocator := context.allocator) -> string {
	s := sanitize_name(server, context.temp_allocator)
	return fmt.aprintf("%s__%s", s, tool, allocator = allocator)
}

sanitize_name :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		ok :=
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= 'a' && ch <= 'z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '_' ||
			ch == '-'
		if ok {
			strings.write_byte(&b, ch)
		} else {
			strings.write_byte(&b, '_')
		}
	}
	out := strings.to_string(b)
	if out == "" {
		return strings.clone("server", allocator)
	}
	return out
}

// parse_qualified splits "server__tool" → (server, tool, ok).
parse_qualified :: proc(q: string) -> (server: string, tool: string, ok: bool) {
	// last occurrence of __  — tool names may contain _
	idx := -1
	for i in 0 ..< len(q) - 1 {
		if q[i] == '_' && q[i + 1] == '_' {
			idx = i
			// keep first __ as separator (server is left side)
			break
		}
	}
	if idx < 0 || idx == 0 || idx + 2 >= len(q) {
		return "", "", false
	}
	return q[:idx], q[idx + 2:], true
}

// load_mcp_configs_from_paths merges mcp_servers from files (later overrides same name).
load_mcp_configs :: proc(allocator := context.allocator) -> []Mcp_Server_Config {
	out := make([dynamic]Mcp_Server_Config, 0, 8, allocator)
	home := core.grok_home(context.temp_allocator)
	home_cfg := fmt.tprintf("%s/config.toml", home)
	if os.exists(home_cfg) {
		append_configs_from_file(&out, home_cfg, allocator)
	}
	// project aether.toml
	if p := find_project_toml(context.temp_allocator); p != "" {
		append_configs_from_file(&out, p, allocator)
	}
	return out[:]
}

find_project_toml :: proc(allocator := context.allocator) -> string {
	// Walk cwd up a few levels for aether.toml
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || cwd == "" {
		cwd = "."
	}
	dir := cwd
	for _ in 0 ..< 8 {
		cand, _ := filepath.join({dir, "aether.toml"}, context.temp_allocator)
		if os.exists(cand) {
			return strings.clone(cand, allocator)
		}
		cand2, _ := filepath.join({dir, "aether", "aether.toml"}, context.temp_allocator)
		if os.exists(cand2) {
			return strings.clone(cand2, allocator)
		}
		parent := filepath.dir(dir)
		if parent == dir || parent == "" {
			break
		}
		dir = parent
	}
	return ""
}

// start_registry connects enabled stdio + HTTP servers. Partial success OK.
start_registry :: proc(
	cfgs: []Mcp_Server_Config,
	quiet: bool,
	allocator := context.allocator,
) -> ^Mcp_Registry {
	reg := new(Mcp_Registry, allocator)
	reg.servers = make([dynamic]Mcp_Server, 0, len(cfgs), allocator)
	reg.tools = make([dynamic]Mcp_Tool, 0, 32, allocator)
	reg.resources = make([dynamic]Mcp_Resource, 0, 16, allocator)
	reg.prompts = make([dynamic]Mcp_Prompt, 0, 16, allocator)

	for c in cfgs {
		if !c.enabled {
			continue
		}
		srv: Mcp_Server
		err: string
		if c.url != "" {
			srv, err = http_connect(c, quiet, allocator)
		} else if c.command != "" {
			srv, err = stdio_connect(c, quiet, allocator)
		} else {
			if !quiet {
				fmt.eprintf("aether: mcp %s: need command= or url=\n", c.name)
			}
			continue
		}
		if err != "" {
			if !quiet {
				fmt.eprintf("aether: mcp %s: %s\n", c.name, err)
			}
			continue
		}
		append(&reg.servers, srv)
		for t in srv.tools {
			append(
				&reg.tools,
				Mcp_Tool {
					server      = strings.clone(t.server, allocator),
					name        = strings.clone(t.name, allocator),
					qualified   = strings.clone(t.qualified, allocator),
					description = strings.clone(t.description, allocator),
					schema_json = strings.clone(t.schema_json, allocator),
				},
			)
		}
		for r in srv.resources {
			append(
				&reg.resources,
				Mcp_Resource {
					server      = strings.clone(r.server, allocator),
					uri         = strings.clone(r.uri, allocator),
					name        = strings.clone(r.name, allocator),
					description = strings.clone(r.description, allocator),
					mime_type   = strings.clone(r.mime_type, allocator),
				},
			)
		}
		for p in srv.prompts {
			append(
				&reg.prompts,
				Mcp_Prompt {
					server         = strings.clone(p.server, allocator),
					name           = strings.clone(p.name, allocator),
					description    = strings.clone(p.description, allocator),
					arguments_json = strings.clone(p.arguments_json, allocator),
				},
			)
		}
		if !quiet {
			kind := "http" if srv.kind == .Http else "stdio"
			fmt.eprintf(
				"aether: mcp %s: connected %s (%d tools, %d resources, %d prompts)\n",
				c.name,
				kind,
				len(srv.tools),
				len(srv.resources),
				len(srv.prompts),
			)
		}
	}
	return reg
}

stop_registry :: proc(reg: ^Mcp_Registry) {
	if reg == nil {
		return
	}
	for &s in reg.servers {
		server_close(&s)
	}
	for &t in reg.tools {
		destroy_tool(&t)
	}
	for &r in reg.resources {
		destroy_resource(&r)
	}
	for &p in reg.prompts {
		destroy_prompt(&p)
	}
	delete(reg.tools)
	delete(reg.resources)
	delete(reg.prompts)
	delete(reg.servers)
	free(reg)
}

// server_close tears down stdio process or HTTP session strings.
server_close :: proc(s: ^Mcp_Server) {
	if s == nil {
		return
	}
	#partial switch s.kind {
	case .Stdio:
		stdio_close(s)
	case .Http:
		http_close(s)
	case:
		// free common fields if half-init
		destroy_server_catalog(s)
		delete(s.name)
	}
}

destroy_server_catalog :: proc(s: ^Mcp_Server) {
	for &t in s.tools {
		destroy_tool(&t)
	}
	delete(s.tools)
	for &r in s.resources {
		destroy_resource(&r)
	}
	delete(s.resources)
	for &p in s.prompts {
		destroy_prompt(&p)
	}
	delete(s.prompts)
}

// status_text for /mcp slash.
status_text :: proc(reg: ^Mcp_Registry, allocator := context.allocator) -> string {
	if reg == nil || len(reg.servers) == 0 {
		return strings.clone("mcp: no servers connected", allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(
		&b,
		fmt.tprintf(
			"mcp: %d server(s), %d tool(s), %d resource(s), %d prompt(s)\n",
			len(reg.servers),
			len(reg.tools),
			len(reg.resources),
			len(reg.prompts),
		),
	)
	for s in reg.servers {
		auth := ""
		if s.kind == .Http {
			auth = fmt.tprintf("  auth=%s", auth_source_string(s.auth_source))
		}
		kind := "stdio" if s.kind == .Stdio else "http"
		strings.write_string(
			&b,
			fmt.tprintf(
				"  %s  %s  tools=%d  resources=%d  prompts=%d  alive=%v%s\n",
				s.name,
				kind,
				len(s.tools),
				len(s.resources),
				len(s.prompts),
				s.alive,
				auth,
			),
		)
	}
	return strings.to_string(b)
}
