package skills

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// Skills_Config from [skills] in config.toml / aether.toml + env.
Skills_Config :: struct {
	paths:    [dynamic]string, // extra roots
	ignore:   [dynamic]string, // path prefixes
	disabled: [dynamic]string, // skill names
}

destroy_skills_config :: proc(c: ^Skills_Config) {
	for p in c.paths {
		delete(p)
	}
	delete(c.paths)
	for p in c.ignore {
		delete(p)
	}
	delete(c.ignore)
	for p in c.disabled {
		delete(p)
	}
	delete(c.disabled)
}

// load_skills_config merges home + project toml [skills] and env.
load_skills_config :: proc(allocator := context.allocator) -> Skills_Config {
	cfg := Skills_Config {
		paths    = make([dynamic]string, 0, 4, allocator),
		ignore   = make([dynamic]string, 0, 4, allocator),
		disabled = make([dynamic]string, 0, 4, allocator),
	}
	home := core.grok_home(context.temp_allocator)
	home_cfg := fmt.tprintf("%s/config.toml", home)
	if os.exists(home_cfg) {
		load_skills_section_from_file(&cfg, home_cfg, allocator)
	}
	// project aether.toml (same walk as MCP)
	if p := find_project_aether_toml(context.temp_allocator); p != "" {
		load_skills_section_from_file(&cfg, p, allocator)
	}
	// env AETHER_SKILLS_DISABLED=a,b,c
	if v := os.get_env("AETHER_SKILLS_DISABLED", context.temp_allocator); v != "" {
		for part in strings.split(v, ",", context.temp_allocator) {
			n := normalize_skill_name(strings.trim_space(part), context.temp_allocator)
			if n != "" && n != "skill" {
				append_unique_str(&cfg.disabled, n, allocator)
			}
		}
	}
	return cfg
}

find_project_aether_toml :: proc(allocator := context.allocator) -> string {
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

load_skills_section_from_file :: proc(
	cfg: ^Skills_Config,
	path: string,
	allocator := context.allocator,
) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	in_skills := false
	lines := strings.split_lines(string(data), context.temp_allocator)
	for line in lines {
		trim := strings.trim_space(line)
		if trim == "" || strings.has_prefix(trim, "#") {
			continue
		}
		if strings.has_prefix(trim, "[") {
			in_skills = strings.has_prefix(trim, "[skills]")
			continue
		}
		if !in_skills {
			continue
		}
		eq := strings.index_byte(trim, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(trim[:eq])
		val := strings.trim_space(trim[eq + 1:])
		key_l := strings.to_lower(key, context.temp_allocator)
		items := parse_toml_string_list(val, context.temp_allocator)
		switch key_l {
		case "paths":
			for it in items {
				exp := expand_tilde(it, context.temp_allocator)
				append_unique_str(&cfg.paths, exp, allocator)
			}
		case "ignore":
			for it in items {
				exp := expand_tilde(it, context.temp_allocator)
				append_unique_str(&cfg.ignore, exp, allocator)
			}
		case "disabled":
			for it in items {
				n := normalize_skill_name(it, context.temp_allocator)
				if n != "" {
					append_unique_str(&cfg.disabled, n, allocator)
				}
			}
		}
	}
}

// parse_toml_string_list: ["a", "b"] or a single quoted/unquoted string.
parse_toml_string_list :: proc(val: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	v := strings.trim_space(val)
	if strings.has_prefix(v, "[") && strings.has_suffix(v, "]") {
		inner := strings.trim_space(v[1:len(v) - 1])
		// split on commas not inside quotes — simple
		cur := strings.builder_make(context.temp_allocator)
		in_q := false
		qch: u8
		for i in 0 ..< len(inner) {
			ch := inner[i]
			if in_q {
				if ch == qch {
					in_q = false
				} else {
					strings.write_byte(&cur, ch)
				}
				continue
			}
			if ch == '"' || ch == '\'' {
				in_q = true
				qch = ch
				continue
			}
			if ch == ',' {
				item := strings.trim_space(strings.to_string(cur))
				if item != "" {
					append(&out, strings.clone(item, allocator))
				}
				strings.builder_reset(&cur)
				continue
			}
			strings.write_byte(&cur, ch)
		}
		item := strings.trim_space(strings.to_string(cur))
		if item != "" {
			append(&out, strings.clone(item, allocator))
		}
		return out[:]
	}
	// single value
	if len(v) >= 2 &&
	   ((v[0] == '"' && v[len(v) - 1] == '"') || (v[0] == '\'' && v[len(v) - 1] == '\'')) {
		v = v[1:len(v) - 1]
	}
	if v != "" {
		append(&out, strings.clone(v, allocator))
	}
	return out[:]
}

expand_tilde :: proc(path: string, allocator := context.allocator) -> string {
	if path == "" {
		return strings.clone("", allocator)
	}
	if path[0] != '~' {
		return strings.clone(path, allocator)
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return strings.clone(path, allocator)
	}
	if path == "~" {
		return strings.clone(home, allocator)
	}
	if len(path) > 1 && path[1] == '/' {
		return fmt.aprintf("%s%s", home, path[1:], allocator = allocator)
	}
	return strings.clone(path, allocator)
}

append_unique_str :: proc(list: ^[dynamic]string, s: string, allocator := context.allocator) {
	if s == "" {
		return
	}
	for x in list {
		if x == s {
			return
		}
	}
	append(list, strings.clone(s, allocator))
}

claude_skills_enabled :: proc() -> bool {
	// Prefer Aether env; accept Grok-style GROK_CLAUDE_SKILLS_ENABLED=false
	if v := os.get_env("AETHER_NO_CLAUDE_SKILLS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	if v := os.get_env("GROK_CLAUDE_SKILLS_ENABLED", context.temp_allocator); v != "" {
		if v == "0" || strings.equal_fold(v, "false") || strings.equal_fold(v, "off") {
			return false
		}
	}
	return true
}

cursor_skills_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_CURSOR_SKILLS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	if v := os.get_env("GROK_CURSOR_SKILLS_ENABLED", context.temp_allocator); v != "" {
		if v == "0" || strings.equal_fold(v, "false") || strings.equal_fold(v, "off") {
			return false
		}
	}
	return true
}

// is_cursor_vendor_default filters Cursor-shipped defaults that are not useful as skills.
is_cursor_vendor_default :: proc(name: string) -> bool {
	n := normalize_skill_name(name, context.temp_allocator)
	switch n {
	case "shell", "canvas", "statusline":
		return true
	}
	return false
}

is_name_disabled :: proc(cfg: Skills_Config, name: string) -> bool {
	n := normalize_skill_name(name, context.temp_allocator)
	for d in cfg.disabled {
		if d == n || d == name {
			return true
		}
	}
	return false
}

path_is_ignored :: proc(cfg: Skills_Config, path: string) -> bool {
	if path == "" || len(cfg.ignore) == 0 {
		return false
	}
	abs := path
	if a, err := filepath.abs(path, context.temp_allocator); err == nil {
		abs = a
	}
	for pref in cfg.ignore {
		pabs := pref
		if a, err := filepath.abs(pref, context.temp_allocator); err == nil {
			pabs = a
		}
		if abs == pabs || strings.has_prefix(abs, pabs) {
			// require boundary: equal or prefix + /
			if abs == pabs ||
			   (len(abs) > len(pabs) && (pabs[len(pabs) - 1] == '/' || abs[len(pabs)] == '/')) {
				return true
			}
		}
	}
	return false
}
