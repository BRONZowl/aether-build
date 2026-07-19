package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_parse_and_discover_persona :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-pe-", context.allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)

	prev := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	_ = os.unset_env("AETHER_NO_PERSONAS")
	defer {
		if prev != "" {
			_ = os.set_env("GROK_HOME", prev)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}

	pdir, _ := filepath.join({dir, "personas"}, context.temp_allocator)
	_ = os.make_directory_all(pdir)
	path, _ := filepath.join({pdir, "researcher.md"}, context.temp_allocator)
	body :=
		"---\nname: researcher\ndescription: deep research\n---\n\nAlways cite file paths.\nPrefer read over guess.\n"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)

	list := discover_personas(dir, context.allocator)
	defer destroy_personas(list)
	testing.expect(t, len(list) >= 1)
	p := find_persona(list, "researcher")
	testing.expect(t, p != nil)
	if p != nil {
		testing.expect(t, strings.contains(p.instructions, "cite file paths"))
		testing.expect(t, strings.contains(p.description, "deep research"))
	}

	instr, perr := persona_instructions_for("researcher", dir, context.allocator)
	defer delete(instr)
	testing.expectf(t, perr == "", "err: %s", perr)
	testing.expect(t, strings.contains(instr, "Prefer read"))

	_, missing := persona_instructions_for("nope", dir, context.temp_allocator)
	testing.expect(t, missing != "")
}

@(test)
test_subagent_system_prompt_includes_persona :: proc(t: ^testing.T) {
	sys := subagent_system_prompt(
		.Explore,
		"/ws",
		"",
		context.allocator,
		"Always be terse.",
	)
	defer delete(sys)
	testing.expect(t, strings.contains(sys, "explore subagent"))
	testing.expect(t, strings.contains(sys, "Persona instructions"))
	testing.expect(t, strings.contains(sys, "Always be terse"))
}
