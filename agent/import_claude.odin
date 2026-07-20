// Package agent — /import-claude: merge Claude MCP + permission-ish settings.
// Best-effort; never overwrites secrets blindly. Writes under ~/.grok.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// claude_settings_candidates returns paths to scan (temp-owned strings OK for display).
claude_settings_candidates :: proc(cwd: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	home, _ := os.user_home_dir(context.temp_allocator)
	if home != "" {
		append(&out, fmt.aprintf("%s/.claude.json", home, allocator = allocator))
		append(&out, fmt.aprintf("%s/.claude/settings.json", home, allocator = allocator))
		append(&out, fmt.aprintf("%s/.claude/settings.local.json", home, allocator = allocator))
		append(&out, fmt.aprintf("%s/.claude/mcp.json", home, allocator = allocator))
	}
	base := cwd if cwd != "" else "."
	append(&out, fmt.aprintf("%s/.mcp.json", base, allocator = allocator))
	append(&out, fmt.aprintf("%s/.claude/settings.json", base, allocator = allocator))
	append(&out, fmt.aprintf("%s/.claude.json", base, allocator = allocator))
	return out[:]
}

// extract_mcp_servers_json_blob finds mcpServers object text for reporting.
// Full merge: if file is .mcp.json or has mcpServers, append TOML stubs to config.
import_claude_merge :: proc(cwd: string, dry_run: bool, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## import-claude\n")
	cands := claude_settings_candidates(cwd, context.temp_allocator)
	found := 0
	imported_mcp := 0
	imported_env := 0

	for p in cands {
		if !os.exists(p) || os.is_directory(p) {
			continue
		}
		found += 1
		fmt.sbprintf(&b, "found: %s\n", p)
		data, err := os.read_entire_file(p, context.temp_allocator)
		if err != nil {
			fmt.sbprintf(&b, "  (read error)\n")
			continue
		}
		text := string(data)
		// MCP servers object
		if n := import_mcp_servers_from_json(text, dry_run, context.temp_allocator); n > 0 {
			imported_mcp += n
			fmt.sbprintf(&b, "  mcpServers → %d server(s) %s\n", n, "would import" if dry_run else "merged into config.toml")
		}
		// env map
		if n := import_env_from_json(text, dry_run, context.temp_allocator); n > 0 {
			imported_env += n
			fmt.sbprintf(&b, "  env → %d key(s) noted %s\n", n, "(dry-run)" if dry_run else "(see [import_claude.env] notes file)")
		}
		// permissions allow/deny arrays → session deny file note
		if strings.contains(text, "permissions") || strings.contains(text, "allow") {
			fmt.sbprintf(&b, "  permissions: present — review manually; use /permissions and config [permission]\n")
		}
	}

	if found == 0 {
		strings.write_string(&b, "(no Claude settings files found near home/cwd)\n")
	}
	fmt.sbprintf(
		&b,
		"\nSummary: files=%d  mcp_servers=%d  env_keys=%d  dry_run=%v\n",
		found,
		imported_mcp,
		imported_env,
		dry_run,
	)
	if dry_run {
		strings.write_string(&b, "Run /import-claude apply to write merges.\n")
	} else if imported_mcp > 0 {
		strings.write_string(&b, "Restart aether or /mcps reconnect to load new MCP servers.\n")
	}
	strings.write_string(
		&b,
		"Sessions: /import <path.json>  ·  Hooks/skills still manual.\n",
	)
	return strings.to_string(b)
}

// import_mcp_servers_from_json: parse mcpServers map; append TOML blocks if missing.
import_mcp_servers_from_json :: proc(text: string, dry_run: bool, allocator := context.allocator) -> int {
	// Prefer encoding/json object parse
	v, err := json.parse(transmute([]byte)text, allocator = context.temp_allocator)
	if err != nil {
		return 0
	}
	defer json.destroy_value(v)
	obj, ok := v.(json.Object)
	if !ok {
		return 0
	}
	servers_v, has := obj["mcpServers"]
	if !has {
		// some files are the servers object itself with command keys
		if _, has_cmd := obj["command"]; has_cmd {
			return 0 // single server without name — skip
		}
		return 0
	}
	servers, sok := servers_v.(json.Object)
	if !sok {
		return 0
	}
	n := 0
	for name, sv in servers {
		sobj, is_o := sv.(json.Object)
		if !is_o {
			continue
		}
		cmd := jstr(sobj, "command")
		url := jstr(sobj, "url")
		if cmd == "" && url == "" {
			continue
		}
		// args array
		args_line := ""
		if av, ah := sobj["args"]; ah {
			if arr, is_a := av.(json.Array); is_a {
				parts: [dynamic]string
				for item in arr {
					if s, is_s := item.(json.String); is_s {
						append(&parts, string(s))
					}
				}
				if len(parts) > 0 {
					args_line = strings.join(parts[:], " ", context.temp_allocator)
				}
			}
		}
		section := fmt.tprintf("[mcp_servers.%s]", sanitize_toml_key(name))
		// skip if already present
		cfg_path := core.user_config_toml_path(context.temp_allocator)
		existing := ""
		if data, rerr := os.read_entire_file(cfg_path, context.temp_allocator); rerr == nil {
			existing = string(data)
		}
		if strings.contains(existing, section) {
			continue
		}
		n += 1
		if dry_run {
			continue
		}
		// append section
		block: string
		qurl := fmt.tprintf("\"%s\"", strings.replace_all(url, "\"", "\\\"", context.temp_allocator) or_else url)
		qcmd := fmt.tprintf("\"%s\"", strings.replace_all(cmd, "\"", "\\\"", context.temp_allocator) or_else cmd)
		if url != "" {
			block = fmt.tprintf(
				"\n%s\nenabled = true\nurl = %s\n",
				section,
				qurl,
			)
		} else {
			block = fmt.tprintf(
				"\n%s\nenabled = true\ncommand = %s\n",
				section,
				qcmd,
			)
			if args_line != "" {
				block = fmt.tprintf("%s# args: %s\n", block, args_line)
			}
		}
		// write append
		_ = core.ensure_dir(filepath.dir(cfg_path))
		combined := fmt.tprintf("%s%s", existing, block)
		_ = os.write_entire_file(cfg_path, transmute([]byte)combined)
	}
	return n
}

import_env_from_json :: proc(text: string, dry_run: bool, allocator := context.allocator) -> int {
	v, err := json.parse(transmute([]byte)text, allocator = context.temp_allocator)
	if err != nil {
		return 0
	}
	defer json.destroy_value(v)
	obj, ok := v.(json.Object)
	if !ok {
		return 0
	}
	env_v, has := obj["env"]
	if !has {
		return 0
	}
	env_o, eok := env_v.(json.Object)
	if !eok {
		return 0
	}
	n := 0
	// Write notes file rather than exporting secrets into shell
	home := core.grok_home(context.temp_allocator)
	notes_path, _ := filepath.join({home, "import_claude_env.txt"}, context.temp_allocator)
	lines := make([dynamic]string, 0, 8, context.temp_allocator)
	for k, vv in env_o {
		if s, is_s := vv.(json.String); is_s {
			n += 1
			append(&lines, fmt.tprintf("%s=%s\n", k, string(s)))
		}
	}
	if n > 0 && !dry_run {
		_ = core.ensure_dir(home)
		body := strings.concatenate(lines[:], context.temp_allocator)
		// append
		existing := ""
		if data, rerr := os.read_entire_file(notes_path, context.temp_allocator); rerr == nil {
			existing = string(data)
		}
		_ = os.write_entire_file(notes_path, transmute([]byte)fmt.tprintf("%s%s", existing, body))
	}
	return n
}

jstr :: proc(obj: json.Object, key: string) -> string {
	if v, ok := obj[key]; ok {
		if s, is_s := v.(json.String); is_s {
			return string(s)
		}
	}
	return ""
}

sanitize_toml_key :: proc(name: string) -> string {
	// keep alnum _ -
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(name) {
		c := name[i]
		ok :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '_' ||
			c == '-'
		if ok {
			strings.write_byte(&b, c)
		} else {
			strings.write_byte(&b, '_')
		}
	}
	s := strings.to_string(b)
	if s == "" {
		return "imported"
	}
	return s
}

// handle_import_claude_slash: scan | apply | dry-run
handle_import_claude_slash :: proc(arg, cwd: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /import-claude [scan|apply|dry-run]\n" +
			"  scan (default)  list Claude files + dry merge report\n" +
			"  apply           merge mcpServers into ~/.grok/config.toml\n" +
			"  dry-run         same as scan\n",
			allocator,
		)
	}
	dry := a != "apply" && a != "write" && a != "import"
	return import_claude_merge(cwd, dry, allocator)
}
