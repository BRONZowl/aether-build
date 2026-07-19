package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_validate_skill_name :: proc(t: ^testing.T) {
	testing.expect(t, validate_skill_name("ab") == "")
	testing.expect(t, validate_skill_name("deploy-k8s") == "")
	testing.expect(t, validate_skill_name("a") != "")
	testing.expect(t, validate_skill_name("-bad") != "")
	testing.expect(t, validate_skill_name("Bad") != "")
	testing.expect(t, validate_skill_name("has space") != "")
}

@(test)
test_create_skill_user_scope :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-cs-", context.allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)

	prev := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	defer {
		if prev != "" {
			_ = os.set_env("GROK_HOME", prev)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}
	_ = os.unset_env("AETHER_NO_SKILLS")

	out := handle_create_skill_slash("my-skill user does useful things", dir, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "skill created"), "got: %s", out)
	path, _ := filepath.join({dir, "skills", "my-skill", "SKILL.md"}, context.temp_allocator)
	testing.expect(t, os.exists(path))
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	body := string(data)
	testing.expect(t, strings.contains(body, "name: my-skill"))
	testing.expect(t, strings.contains(body, "does useful things"))
}

@(test)
test_create_skill_reject_exists :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-cs2-", context.allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	prev := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	defer {
		if prev != "" {
			_ = os.set_env("GROK_HOME", prev)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}
	_ = handle_create_skill_slash("dup-skill user", dir, context.temp_allocator)
	out := handle_create_skill_slash("dup-skill user", dir, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "already exists"))
}
