// Package agent — subagent personas (M9).
// Discover ~/.grok/personas/*.md and <cwd>/.grok/personas/*.md
// Optional frontmatter: name, description; body = instructions.
// spawn_subagent / task accept persona=<name>.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

Persona :: struct {
	name:         string, // owned
	description:  string, // owned
	instructions: string, // owned body
	path:         string, // owned source path
}

destroy_persona :: proc(p: ^Persona) {
	delete(p.name)
	delete(p.description)
	delete(p.instructions)
	delete(p.path)
}

destroy_personas :: proc(list: []Persona) {
	for &p in list {
		destroy_persona(&p)
	}
	delete(list)
}

personas_enabled :: proc() -> bool {
	if core.feature_killed("AETHER_NO_PERSONAS") {
		return false
	}
	return true
}

// discover_personas: user then project (project wins on name collision).
discover_personas :: proc(cwd: string, allocator := context.allocator) -> []Persona {
	out := make([dynamic]Persona, 0, 8, allocator)
	if !personas_enabled() {
		return out[:]
	}
	home := core.grok_home(context.temp_allocator)
	user_dir, _ := filepath.join({home, "personas"}, context.temp_allocator)
	scan_personas_dir(user_dir, &out, allocator)

	base := cwd if cwd != "" else "."
	proj, _ := filepath.join({base, ".grok", "personas"}, context.temp_allocator)
	scan_personas_dir(proj, &out, allocator) // later upserts win
	return out[:]
}

scan_personas_dir :: proc(
	dir: string,
	out: ^[dynamic]Persona,
	allocator := context.allocator,
) {
	if dir == "" || !os.exists(dir) || !os.is_directory(dir) {
		return
	}
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in fis {
		if fi.type == .Directory {
			continue
		}
		if !strings.has_suffix(fi.name, ".md") {
			continue
		}
		path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {
			continue
		}
		stem := filepath.stem(fi.name)
		p := parse_persona_md(string(data), stem, path, allocator)
		upsert_persona(out, p)
	}
}

upsert_persona :: proc(out: ^[dynamic]Persona, p: Persona) {
	for i in 0 ..< len(out) {
		if out[i].name == p.name {
			destroy_persona(&out[i])
			out[i] = p
			return
		}
	}
	append(out, p)
}

// parse_persona_md: optional --- frontmatter with name/description
parse_persona_md :: proc(
	body, default_name, path: string,
	allocator := context.allocator,
) -> Persona {
	p := Persona {
		name = strings.clone(default_name, allocator),
		path = strings.clone(path, allocator),
	}
	text := body
	if strings.has_prefix(text, "---") {
		// find closing ---
		rest := text[3:]
		// skip first newline
		if len(rest) > 0 && rest[0] == '\n' {
			rest = rest[1:]
		} else if len(rest) > 1 && rest[0] == '\r' && rest[1] == '\n' {
			rest = rest[2:]
		}
		end := strings.index(rest, "\n---")
		if end >= 0 {
			fm := rest[:end]
			text = rest[end + 4:]
			if strings.has_prefix(text, "\n") {
				text = text[1:]
			}
			// parse name: / description:
			for line in strings.split_lines(fm, context.temp_allocator) {
				trim := strings.trim_space(line)
				if strings.has_prefix(trim, "name:") {
					v := strings.trim_space(trim[len("name:"):])
					v = strings.trim(v, "\"'")
					if v != "" {
						delete(p.name)
						p.name = strings.clone(v, allocator)
					}
				} else if strings.has_prefix(trim, "description:") {
					v := strings.trim_space(trim[len("description:"):])
					v = strings.trim(v, "\"'")
					p.description = strings.clone(v, allocator)
				}
			}
		}
	}
	p.instructions = strings.clone(strings.trim_space(text), allocator)
	return p
}

find_persona :: proc(list: []Persona, name: string) -> ^Persona {
	n := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	if n == "" {
		return nil
	}
	for i in 0 ..< len(list) {
		if strings.to_lower(list[i].name, context.temp_allocator) == n {
			return &list[i]
		}
	}
	return nil
}

// persona_instructions_for: load and return instructions body (owned) or "" if missing.
persona_instructions_for :: proc(
	name, cwd: string,
	allocator := context.allocator,
) -> (
	instructions: string,
	err: string,
) {
	if strings.trim_space(name) == "" {
		return "", ""
	}
	if !personas_enabled() {
		return "", "personas disabled (AETHER_NO_PERSONAS=1)"
	}
	list := discover_personas(cwd, context.allocator)
	defer destroy_personas(list)
	p := find_persona(list, name)
	if p == nil {
		return "", fmt.tprintf("unknown persona %q (add ~/.grok/personas/%s.md)", name, name)
	}
	if p.instructions == "" {
		return "", fmt.tprintf("persona %q has empty instructions", name)
	}
	return strings.clone(p.instructions, allocator), ""
}

format_personas_list :: proc(cwd: string, allocator := context.allocator) -> string {
	if !personas_enabled() {
		return strings.clone("personas: DISABLED (AETHER_NO_PERSONAS=1)", allocator)
	}
	list := discover_personas(cwd, context.allocator)
	defer destroy_personas(list)
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "personas: %d  (spawn_subagent persona=name)\n", len(list))
	if len(list) == 0 {
		strings.write_string(
			&b,
			"  (none)  add ~/.grok/personas/<name>.md or <cwd>/.grok/personas/<name>.md\n",
		)
		return strings.to_string(b)
	}
	for p in list {
		desc := p.description if p.description != "" else "(no description)"
		fmt.sbprintf(&b, "  %s  %s\n      %s\n", p.name, desc, p.path)
	}
	return strings.to_string(b)
}
