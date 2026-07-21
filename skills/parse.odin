// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package skills

import "core:fmt"
import "core:os"
import "core:strings"

Skill_Kind :: enum {
	Skill,   // package with SKILL.md
	Command, // flat commands/*.md
}

// Parsed_Skill is metadata + path; body loaded on demand.
Parsed_Skill :: struct {
	name:        string, // owned normalized
	description: string, // owned
	path:        string, // owned path to SKILL.md or command .md
	dir:         string, // owned skill directory (or commands dir)
	kind:        Skill_Kind,
	disabled:    bool, // model cannot invoke; user slash still can
}

destroy_parsed_skill :: proc(s: ^Parsed_Skill, allocator := context.allocator) {
	if s == nil {
		return
	}
	delete(s.name, allocator)
	delete(s.description, allocator)
	delete(s.path, allocator)
	delete(s.dir, allocator)
	s^ = {}
}

// normalize_skill_name: lowercase, spaces/underscores → hyphens, strip invalid.
normalize_skill_name :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	prev_hyphen := false
	for i in 0 ..< len(s) {
		ch := s[i]
		c := ch
		if ch >= 'A' && ch <= 'Z' {
			c = ch + 32
		}
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if c == ' ' || c == '_' {
			c = '-'
			ok = true
		}
		if !ok {
			continue
		}
		if c == '-' {
			if prev_hyphen || strings.builder_len(b) == 0 {
				continue
			}
			prev_hyphen = true
			strings.write_byte(&b, '-')
			continue
		}
		prev_hyphen = false
		strings.write_byte(&b, c)
	}
	out := strings.to_string(b)
	// trim trailing hyphen
	for len(out) > 0 && out[len(out) - 1] == '-' {
		out = out[:len(out) - 1]
	}
	if out == "" {
		return strings.clone("skill", allocator)
	}
	if len(out) > 64 {
		return strings.clone(out[:64], allocator)
	}
	return out
}

// parse_skill_md parses SKILL.md content. dir_name used if name missing.
parse_skill_md :: proc(
	raw: string,
	dir_name: string,
	path: string,
	allocator := context.allocator,
) -> Parsed_Skill {
	name := ""
	desc := ""
	body_start := 0

	trim := strings.trim_left_space(raw)
	if strings.has_prefix(trim, "---") {
		// frontmatter
		rest := trim[3:]
		// skip optional newline after opening ---
		if len(rest) > 0 && rest[0] == '\n' {
			rest = rest[1:]
		} else if len(rest) > 1 && rest[0] == '\r' && rest[1] == '\n' {
			rest = rest[2:]
		}
		end := strings.index(rest, "\n---")
		if end >= 0 {
			fm := rest[:end]
			after := rest[end + 4:] // past \n---
			if len(after) > 0 && after[0] == '\n' {
				after = after[1:]
			} else if len(after) > 1 && after[0] == '\r' {
				after = after[2:] if len(after) > 1 && after[1] == '\n' else after[1:]
			}
			body_start = len(raw) - len(after) // not needed if we use after as body
			_ = body_start
			parse_frontmatter(fm, &name, &desc)
			// body is after
			if name == "" {
				name = dir_name
			}
			if desc == "" {
				desc = first_paragraph(after)
			}
			return Parsed_Skill {
				name        = normalize_skill_name(name, allocator),
				description = strings.clone(truncate_runes(desc, 512), allocator),
				path        = strings.clone(path, allocator),
				dir         = strings.clone(dir_name, allocator), // caller may overwrite with full dir
				kind        = .Skill,
				disabled    = false,
			}
		}
	}

	// no frontmatter
	name = dir_name
	desc = first_paragraph(raw)
	return Parsed_Skill {
		name        = normalize_skill_name(name, allocator),
		description = strings.clone(truncate_runes(desc, 512), allocator),
		path        = strings.clone(path, allocator),
		dir         = strings.clone(dir_name, allocator),
		kind        = .Skill,
		disabled    = false,
	}
}

// parse_command_md turns a flat commands/foo.md into a Parsed_Skill (kind=Command).
parse_command_md :: proc(
	raw: string,
	file_stem: string,
	path: string,
	dir: string,
	allocator := context.allocator,
) -> Parsed_Skill {
	desc := first_line_heading_or_text(raw)
	if desc == "" {
		desc = "User command"
	}
	return Parsed_Skill {
		name        = normalize_skill_name(file_stem, allocator),
		description = strings.clone(truncate_runes(desc, 512), allocator),
		path        = strings.clone(path, allocator),
		dir         = strings.clone(dir, allocator),
		kind        = .Command,
		disabled    = false,
	}
}

first_line_heading_or_text :: proc(body: string) -> string {
	lines := strings.split_lines(body, context.temp_allocator)
	for line in lines {
		t := strings.trim_space(line)
		if t == "" {
			continue
		}
		if strings.has_prefix(t, "#") {
			t = strings.trim_space(strings.trim_left(t, "#"))
		}
		return t
	}
	return ""
}

parse_frontmatter :: proc(fm: string, name: ^string, desc: ^string) {
	// simple key: value and key: > folded
	lines := strings.split_lines(fm, context.temp_allocator)
	i := 0
	for i < len(lines) {
		line := lines[i]
		trim := strings.trim_space(line)
		if trim == "" || strings.has_prefix(trim, "#") {
			i += 1
			continue
		}
		colon := strings.index_byte(trim, ':')
		if colon < 0 {
			i += 1
			continue
		}
		key := strings.trim_space(trim[:colon])
		val := strings.trim_space(trim[colon + 1:])
		key_l := strings.to_lower(key, context.temp_allocator)

		// folded / multi-line >
		if val == ">" || val == "|" {
			i += 1
			b := strings.builder_make(context.temp_allocator)
			for i < len(lines) {
				nl := lines[i]
				// continuation: indented or non-key line
				if len(nl) > 0 && (nl[0] == ' ' || nl[0] == '\t') {
					if strings.builder_len(b) > 0 {
						strings.write_byte(&b, ' ')
					}
					strings.write_string(&b, strings.trim_space(nl))
					i += 1
					continue
				}
				// bare continuation without indent for >
				if !strings.contains(nl, ":") && strings.trim_space(nl) != "" {
					if strings.builder_len(b) > 0 {
						strings.write_byte(&b, ' ')
					}
					strings.write_string(&b, strings.trim_space(nl))
					i += 1
					continue
				}
				break
			}
			val = strings.to_string(b)
		} else {
			// strip quotes
			if len(val) >= 2 &&
			   ((val[0] == '"' && val[len(val) - 1] == '"') ||
				   (val[0] == '\'' && val[len(val) - 1] == '\'')) {
				val = val[1:len(val) - 1]
			}
			i += 1
		}

		switch key_l {
		case "name":
			name^ = val
		case "description":
			desc^ = val
		}
	}
}

first_paragraph :: proc(body: string) -> string {
	// skip leading blanks and # headings
	lines := strings.split_lines(body, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	started := false
	for line in lines {
		t := strings.trim_space(line)
		if !started {
			if t == "" || strings.has_prefix(t, "#") {
				continue
			}
			started = true
			strings.write_string(&b, t)
			continue
		}
		if t == "" {
			break
		}
		if strings.has_prefix(t, "#") {
			break
		}
		strings.write_byte(&b, ' ')
		strings.write_string(&b, t)
	}
	return strings.to_string(b)
}

truncate_runes :: proc(s: string, max_chars: int) -> string {
	if len(s) <= max_chars {
		return s
	}
	return fmt.tprintf("%s…", s[:max_chars - 1])
}

// load_skill_body reads full file; caps at max_bytes.
load_skill_body :: proc(path: string, max_bytes := 80_000, allocator := context.allocator) -> (string, string /* err */) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", fmt.tprintf("read %s: %v", path, err)
	}
	s := string(data)
	if len(s) > max_bytes {
		return fmt.aprintf(
			"%s\n\n…[truncated %d bytes]",
			s[:max_bytes],
			len(s) - max_bytes,
			allocator = allocator,
		), ""
	}
	return strings.clone(s, allocator), ""
}
