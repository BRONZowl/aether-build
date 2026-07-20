// Package skills — SKILL.md discovery and invocation (product shell).
package skills

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

Skill_Registry :: struct {
	skills: [dynamic]Parsed_Skill,
}

g_registry: ^Skill_Registry

set_registry :: proc(r: ^Skill_Registry) {
	g_registry = r
}

get_registry :: proc() -> ^Skill_Registry {
	return g_registry
}

// Live registry always uses the process heap so it outlives unit-test tracking
// allocators (context.allocator). Tests that install a registry must still call
// maybe_stop_skills / stop_registry, but accidental survival no longer dangles.
skills_heap :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// start_registry discovers skills for cwd. Returns nil if disabled or empty.
// Always allocates the registry on the process heap (see skills_heap).
start_registry :: proc(cwd: string, quiet: bool, allocator := context.allocator) -> ^Skill_Registry {
	_ = allocator // API compat; live registry ignores test/tracking allocators
	ha := skills_heap()
	if v := os.get_env("AETHER_NO_SKILLS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return nil
	}
	cfg := load_skills_config(ha)
	defer destroy_skills_config(&cfg, ha)
	list := discover_skills(cwd, cfg, ha)
	if len(list) == 0 {
		delete(list)
		return nil
	}
	reg := new(Skill_Registry, ha)
	reg.skills = list
	// Discovery is silent by default (Grok-quiet headless). Opt in:
	// AETHER_VERBOSE_SKILLS=1 or caller quiet=false with AETHER_VERBOSE=1.
	_ = quiet
	if v := os.get_env("AETHER_VERBOSE_SKILLS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") ||
	   strings.equal_fold(v, "yes") {
		n_dis := 0
		n_cmd := 0
		for s in reg.skills {
			if s.disabled {
				n_dis += 1
			}
			if s.kind == .Command {
				n_cmd += 1
			}
		}
		fmt.eprintf(
			"aether: skills: %d discovered (%d commands, %d disabled)\n",
			len(reg.skills),
			n_cmd,
			n_dis,
		)
	}
	return reg
}

stop_registry :: proc(reg: ^Skill_Registry) {
	if reg == nil {
		return
	}
	ha := skills_heap()
	for &s in reg.skills {
		destroy_parsed_skill(&s, ha)
	}
	delete(reg.skills)
	free(reg, ha)
}

find_by_name :: proc(reg: ^Skill_Registry, name: string) -> ^Parsed_Skill {
	if reg == nil {
		return nil
	}
	n := normalize_skill_name(name, context.temp_allocator)
	for &s in reg.skills {
		if s.name == n || s.name == name {
			return &s
		}
	}
	return nil
}

// format_catalog for system prompt (max 40 skills; excludes disabled).
format_catalog :: proc(reg: ^Skill_Registry, allocator := context.allocator) -> string {
	if reg == nil || len(reg.skills) == 0 {
		return strings.clone("", allocator)
	}
	// count enabled
	enabled_n := 0
	for s in reg.skills {
		if !s.disabled {
			enabled_n += 1
		}
	}
	if enabled_n == 0 {
		return strings.clone("", allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "\n\n## Available skills\n")
	strings.write_string(
		&b,
		"Invoke with the `skill` tool (skill name) or user slash `/skill <name>`. Load a skill before following its procedure. Commands from commands/*.md are included.\n",
	)
	shown := 0
	for s in reg.skills {
		if s.disabled {
			continue
		}
		if shown >= 40 {
			break
		}
		desc := s.description
		if len(desc) > 160 {
			desc = fmt.tprintf("%s…", desc[:157])
		}
		tag := ""
		if s.kind == .Command {
			tag = " (command)"
		}
		strings.write_string(&b, fmt.tprintf("- **%s**%s: %s\n", s.name, tag, desc))
		shown += 1
	}
	if enabled_n > shown {
		strings.write_string(
			&b,
			fmt.tprintf("…and %d more (use /skills to list).\n", enabled_n - shown),
		)
	}
	return strings.to_string(b)
}

// format_list for /skills slash (includes disabled + command markers).
format_list :: proc(reg: ^Skill_Registry, allocator := context.allocator) -> string {
	if reg == nil || len(reg.skills) == 0 {
		return strings.clone("skills: none discovered", allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, fmt.tprintf("skills: %d\n", len(reg.skills)))
	for s in reg.skills {
		desc := s.description
		if len(desc) > 100 {
			desc = fmt.tprintf("%s…", desc[:97])
		}
		mark := ""
		if s.kind == .Command {
			mark = " [cmd]"
		}
		if s.disabled {
			mark = fmt.tprintf("%s (disabled)", mark)
		}
		strings.write_string(&b, fmt.tprintf("  /%s%s  %s\n", s.name, mark, desc))
	}
	return strings.to_string(b)
}

// invoke_skill loads body for tool or slash.
// for_model: when true, disabled skills are denied.
invoke_skill :: proc(
	reg: ^Skill_Registry,
	name: string,
	args: string,
	allocator := context.allocator,
	for_model := false,
) -> string {
	sk := find_by_name(reg, name)
	if sk == nil {
		return fmt.aprintf(
			"error: unknown skill %q — use /skills to list",
			name,
			allocator = allocator,
		)
	}
	if for_model && sk.disabled {
		return fmt.aprintf(
			"error: skill %q is disabled (user may still invoke via /%s)",
			sk.name,
			sk.name,
			allocator = allocator,
		)
	}
	body, err := load_skill_body(sk.path, 80_000, allocator)
	if err != "" {
		return fmt.aprintf("error: %s", err, allocator = allocator)
	}
	label := "Skill"
	if sk.kind == .Command {
		label = "Command"
	}
	if args != "" {
		return fmt.aprintf(
			"# %s: %s\n\nUser args: %s\n\n---\n\n%s",
			label,
			sk.name,
			args,
			body,
			allocator = allocator,
		)
	}
	return fmt.aprintf("# %s: %s\n\n%s", label, sk.name, body, allocator = allocator)
}

// handle_skill_tool parses JSON args for skill tool (model path → for_model).
handle_skill_tool :: proc(
	reg: ^Skill_Registry,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if reg == nil {
		return strings.clone("error: skills not enabled", allocator)
	}
	if len(reg.skills) == 0 {
		return strings.clone(
			"error: no skills discovered — add packages under ~/.grok/skills or project .grok/skills; see /skills",
			allocator,
		)
	}
	name := extract_json_str(arguments_json, "skill")
	if name == "" {
		name = extract_json_str(arguments_json, "name")
	}
	if name == "" {
		return strings.clone("error: skill name is required", allocator)
	}
	args := extract_json_str(arguments_json, "args")
	if args == "" {
		args = extract_json_str(arguments_json, "arguments")
	}
	return invoke_skill(reg, name, args, allocator, true)
}

extract_json_str :: proc(raw: string, key: string) -> string {
	pat := fmt.tprintf("\"%s\"", key)
	i := strings.index(raw, pat)
	if i < 0 {
		return ""
	}
	rest := raw[i + len(pat):]
	for len(rest) > 0 && rest[0] != ':' {
		rest = rest[1:]
	}
	if len(rest) == 0 {
		return ""
	}
	rest = rest[1:]
	for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] != '"' {
		return ""
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
			return strings.to_string(b)
		}
		strings.write_byte(&b, ch)
	}
	return ""
}
