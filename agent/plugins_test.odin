// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_discover_and_add_plugin :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-pl-", context.allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)

	prev := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	_ = os.unset_env("AETHER_NO_PLUGINS")
	defer {
		if prev != "" {
			_ = os.set_env("GROK_HOME", prev)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}

	// source plugin with skills
	src, _ := filepath.join({dir, "src-plugin"}, context.temp_allocator)
	sk, _ := filepath.join({src, "skills", "hello"}, context.temp_allocator)
	_ = os.make_directory_all(sk)
	sm, _ := filepath.join({sk, "SKILL.md"}, context.temp_allocator)
	body := "---\nname: hello-plugin\ndescription: test\n---\n\n# Hello\n"
	testing.expect(t, os.write_entire_file(sm, transmute([]byte)body) == nil)
	manifest, _ := filepath.join({src, "plugin.json"}, context.temp_allocator)
	man_body := `{"name":"src-plugin","description":"demo plugin","version":"0.1.0"}`
	testing.expect(t, os.write_entire_file(manifest, transmute([]byte)man_body) == nil)

	aerr := plugins_add(src, dir)
	testing.expectf(t, aerr == "", "add: %s", aerr)

	list := discover_plugins(dir, context.allocator)
	defer destroy_plugin_list(list)
	testing.expectf(t, len(list) >= 1, "expected plugins, got %d", len(list))
	found := false
	for p in list {
		if p.name == "src-plugin" {
			found = true
			testing.expect(t, p.has_skills)
			testing.expect(t, strings.contains(p.description, "demo"))
		}
	}
	testing.expect(t, found)

	out := format_plugins_list(dir, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "src-plugin"))

	rerr := plugins_remove("src-plugin")
	testing.expectf(t, rerr == "", "remove: %s", rerr)
}

@(test)
test_plugins_disabled :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_PLUGINS", context.temp_allocator)
	_ = os.set_env("AETHER_NO_PLUGINS", "1")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_PLUGINS", prev)
		} else {
			_ = os.unset_env("AETHER_NO_PLUGINS")
		}
	}
	testing.expect(t, !plugins_enabled())
	out := format_plugins_list(".", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "DISABLED"))
}
