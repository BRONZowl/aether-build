package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:skills"

// maybe_start_skills discovers skills for cwd unless disabled.
// Returns the live registry pointer (also in skills global). After /skills reload,
// the live registry may differ from the original return value — always stop via
// maybe_stop_skills (uses the global).
maybe_start_skills :: proc(cwd: string, quiet: bool) -> ^skills.Skill_Registry {
	if v := os.get_env("AETHER_NO_SKILLS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		skills.set_registry(nil)
		return nil
	}
	reg := skills.start_registry(cwd, quiet)
	skills.set_registry(reg) // may be nil when empty
	return reg
}

// maybe_stop_skills frees the current global registry (not a stale host pointer).
maybe_stop_skills :: proc(_reg: ^skills.Skill_Registry) {
	r := skills.get_registry()
	if r == nil {
		return
	}
	skills.set_registry(nil)
	skills.stop_registry(r)
}

// reload_skills_for_cwd rediscovers skills (used by /skills reload).
reload_skills_for_cwd :: proc(cwd: string, quiet := true) -> string {
	old := skills.get_registry()
	if old != nil {
		skills.set_registry(nil)
		skills.stop_registry(old)
	}
	if v := os.get_env("AETHER_NO_SKILLS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return strings.clone("aether: skills disabled (AETHER_NO_SKILLS=1)")
	}
	reg := skills.start_registry(cwd, quiet)
	skills.set_registry(reg)
	if reg == nil {
		return strings.clone("aether: skills reloaded — none discovered")
	}
	return fmt.aprintf(
		"aether: skills reloaded\n%s",
		skills.format_list(reg, context.temp_allocator),
	)
}

skills_enabled_for_turn :: proc() -> bool {
	r := skills.get_registry()
	return r != nil && len(r.skills) > 0
}

skills_catalog_text :: proc(allocator := context.allocator) -> string {
	r := skills.get_registry()
	return skills.format_catalog(r, allocator)
}

skills_list_text :: proc(allocator := context.allocator) -> string {
	r := skills.get_registry()
	return skills.format_list(r, allocator)
}

skills_invoke_text :: proc(name, args: string, allocator := context.allocator) -> string {
	return skills.invoke_skill(skills.get_registry(), name, args, allocator)
}

skills_is_named :: proc(name: string) -> bool {
	return skills.find_by_name(skills.get_registry(), name) != nil
}
