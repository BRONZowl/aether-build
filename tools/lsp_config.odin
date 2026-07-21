// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

// lsp_config — load/merge ~/.grok/lsp.json + <cwd>/.grok/lsp.json (Grok-shaped).
// Reference: crates/codegen/xai-grok-tools/.../lsp/config.rs

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

Lsp_Server_Cfg :: struct {
	name:               string, // owned
	command:            string, // owned
	args:               [dynamic]string, // owned elements
	extensions:         map[string]string, // ".odin" → "odin"; owned keys/values
	settings_json:      string, // owned raw JSON object or ""
	init_options_json:  string, // owned or ""
}

// lsp_enabled: opt-out AETHER_NO_LSP=1
lsp_enabled :: proc() -> bool {
	return !core.feature_killed("AETHER_NO_LSP")
}

// apply_default_extensions fills well-known server → ext map when empty.
apply_default_extensions :: proc(name: string, ext: ^map[string]string) {
	if len(ext) > 0 {
		return
	}
	n := strings.to_lower(name, context.temp_allocator)
	put :: proc(ext: ^map[string]string, k, v: string) {
		ext[strings.clone(k)] = strings.clone(v)
	}
	switch {
	case n == "ols" || strings.contains(n, "odin"):
		put(ext, ".odin", "odin")
	case n == "rust-analyzer" || strings.contains(n, "rust"):
		put(ext, ".rs", "rust")
	case n == "lua_ls" || strings.contains(n, "lua"):
		put(ext, ".lua", "lua")
	case n == "pyright" || n == "basedpyright" || strings.contains(n, "pyright"):
		put(ext, ".py", "python")
	case n == "ruff":
		put(ext, ".py", "python")
	case n == "clangd" || strings.contains(n, "clang"):
		put(ext, ".c", "c")
		put(ext, ".h", "c")
		put(ext, ".cpp", "cpp")
		put(ext, ".hpp", "cpp")
		put(ext, ".cc", "cpp")
		put(ext, ".cxx", "cpp")
	case n == "tsgo" || strings.contains(n, "typescript") || n == "tsserver":
		put(ext, ".ts", "typescript")
		put(ext, ".tsx", "typescriptreact")
		put(ext, ".js", "javascript")
		put(ext, ".jsx", "javascriptreact")
	case n == "gopls" || strings.contains(n, "gopls"):
		put(ext, ".go", "go")
	}
}

free_lsp_server_cfg :: proc(c: ^Lsp_Server_Cfg) {
	delete(c.name)
	delete(c.command)
	for a in c.args {
		delete(a)
	}
	delete(c.args)
	for k, v in c.extensions {
		delete(k)
		delete(v)
	}
	delete(c.extensions)
	delete(c.settings_json)
	delete(c.init_options_json)
	c^ = {}
}

free_lsp_servers :: proc(servers: ^[dynamic]Lsp_Server_Cfg) {
	for &s in servers {
		free_lsp_server_cfg(&s)
	}
	delete(servers^)
	servers^ = {}
}

// parse_lsp_servers_json parses a top-level object of server configs into out (appends).
// Existing same-name entries in out are replaced (caller merges project over user).
parse_lsp_servers_json :: proc(
	raw: string,
	out: ^[dynamic]Lsp_Server_Cfg,
	allocator := context.allocator,
) -> string /* err */ {
	if strings.trim_space(raw) == "" {
		return ""
	}
	val, err := json.parse(transmute([]byte)raw, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil {
		return "invalid lsp.json"
	}
	root, ok := val.(json.Object)
	if !ok {
		return "lsp.json must be an object"
	}
	for name, v in root {
		so, is_obj := v.(json.Object)
		if !is_obj {
			continue
		}
		cmd := ""
		if cv, has := so["command"]; has {
			if s, is_s := cv.(json.String); is_s {
				cmd = string(s)
			}
		}
		if cmd == "" {
			continue
		}
		// replace existing same name
		for i := 0; i < len(out); i += 1 {
			if out[i].name == name {
				free_lsp_server_cfg(&out[i])
				ordered_remove(out, i)
				break
			}
		}
		cfg := Lsp_Server_Cfg {
			name              = strings.clone(name, allocator),
			command           = strings.clone(cmd, allocator),
			args              = make([dynamic]string, 0, 4, allocator),
			extensions        = make(map[string]string, allocator),
			settings_json     = "",
			init_options_json = "",
		}
		if av, has := so["args"]; has {
			if arr, is_a := av.(json.Array); is_a {
				for item in arr {
					if s, is_s := item.(json.String); is_s {
						append(&cfg.args, strings.clone(string(s), allocator))
					}
				}
			}
		}
		// extensions / extensionToLanguage / extensionToLanguageId
		ext_key := ""
		if _, has_ext := so["extensions"]; has_ext {
			ext_key = "extensions"
		} else if _, has_etl := so["extensionToLanguage"]; has_etl {
			ext_key = "extensionToLanguage"
		} else if _, has_etlid := so["extensionToLanguageId"]; has_etlid {
			ext_key = "extensionToLanguageId"
		}
		if ext_key != "" {
			if eo, is_o := so[ext_key].(json.Object); is_o {
				for ek, ev in eo {
					if s, is_s := ev.(json.String); is_s {
						k := ek
						if !strings.has_prefix(k, ".") {
							k = fmt.tprintf(".%s", k)
						}
						cfg.extensions[strings.clone(k, allocator)] = strings.clone(string(s), allocator)
					}
				}
			}
		}
		apply_default_extensions(cfg.name, &cfg.extensions)
		if sv, has := so["settings"]; has {
			cfg.settings_json = lsp_json_value_string(sv, allocator)
		}
		if iv0, has_io := so["initializationOptions"]; has_io {
			cfg.init_options_json = lsp_json_value_string(iv0, allocator)
		} else if iv1, has_io2 := so["initialization_options"]; has_io2 {
			cfg.init_options_json = lsp_json_value_string(iv1, allocator)
		}
		append(out, cfg)
	}
	return ""
}

lsp_json_value_string :: proc(v: json.Value, allocator := context.allocator) -> string {
	// marshal via crude rebuild
	return lsp_json_encode(v, allocator)
}

// load_lsp_servers merges user then project lsp.json for workspace.
load_lsp_servers :: proc(workspace: string, allocator := context.allocator) -> [dynamic]Lsp_Server_Cfg {
	out := make([dynamic]Lsp_Server_Cfg, 0, 8, allocator)
	home := core.grok_home(context.temp_allocator)
	user_path, _ := filepath.join({home, "lsp.json"}, context.temp_allocator)
	if data, err := os.read_entire_file(user_path, context.temp_allocator); err == nil {
		_ = parse_lsp_servers_json(string(data), &out, allocator)
	}
	if workspace != "" {
		proj, _ := filepath.join({workspace, ".grok", "lsp.json"}, context.temp_allocator)
		if data, err := os.read_entire_file(proj, context.temp_allocator); err == nil {
			_ = parse_lsp_servers_json(string(data), &out, allocator)
		}
	}
	return out
}

// resolve_lsp_server picks server + languageId for a file path.
resolve_lsp_server :: proc(
	servers: []Lsp_Server_Cfg,
	file_path: string,
) -> (
	server_name: string,
	lang_id: string,
	ok: bool,
) {
	ext := filepath.ext(file_path)
	if ext == "" {
		return "", "", false
	}
	// normalize ".ODIN" → ".odin"
	ext_l := strings.to_lower(ext, context.temp_allocator)
	if !strings.has_prefix(ext_l, ".") {
		ext_l = fmt.tprintf(".%s", ext_l)
	}
	for s in servers {
		if lid, has := s.extensions[ext_l]; has {
			return s.name, lid, true
		}
		// also try case-sensitive original
		if lid, has := s.extensions[ext]; has {
			return s.name, lid, true
		}
	}
	return "", "", false
}

// find_lsp_server_cfg by name
find_lsp_server_cfg :: proc(servers: []Lsp_Server_Cfg, name: string) -> (Lsp_Server_Cfg, bool) {
	for s in servers {
		if s.name == name {
			return s, true
		}
	}
	return {}, false
}

// --- JSON encode helpers (Content-Length / didOpen need proper escaping) ---

lsp_json_quote :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", u32(ch)))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

lsp_json_encode :: proc(v: json.Value, allocator := context.allocator) -> string {
	#partial switch t in v {
	case json.Null:
		return strings.clone("null", allocator)
	case json.Boolean:
		return strings.clone("true" if bool(t) else "false", allocator)
	case json.Integer:
		return fmt.aprintf("%d", i64(t), allocator = allocator)
	case json.Float:
		return fmt.aprintf("%v", f64(t), allocator = allocator)
	case json.String:
		return lsp_json_quote(string(t), allocator)
	case json.Array:
		b := strings.builder_make(allocator)
		strings.write_byte(&b, '[')
		for item, i in t {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, lsp_json_encode(item, context.temp_allocator))
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b)
	case json.Object:
		b := strings.builder_make(allocator)
		strings.write_byte(&b, '{')
		first := true
		for key, val in t {
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			strings.write_string(&b, lsp_json_quote(key, context.temp_allocator))
			strings.write_byte(&b, ':')
			strings.write_string(&b, lsp_json_encode(val, context.temp_allocator))
		}
		strings.write_byte(&b, '}')
		return strings.to_string(b)
	}
	return strings.clone("null", allocator)
}

// path_to_file_uri → file:///abs (minimal; absolute paths only)
path_to_file_uri :: proc(abs_path: string, allocator := context.allocator) -> string {
	p := abs_path
	// already absolute preferred
	if strings.has_prefix(p, "file://") {
		return strings.clone(p, allocator)
	}
	// ensure leading /
	if !strings.has_prefix(p, "/") {
		p = fmt.tprintf("/%s", p)
	}
	return fmt.aprintf("file://%s", p, allocator = allocator)
}

// file_uri_to_path strips file:// prefix for display
file_uri_to_path :: proc(uri: string) -> string {
	if strings.has_prefix(uri, "file://") {
		rest := uri[len("file://"):]
		// file:///path → /path
		return rest
	}
	return uri
}
