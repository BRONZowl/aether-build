package skills

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_normalize_skill_name :: proc(t: ^testing.T) {
	testing.expect(t, normalize_skill_name("Hello World", context.temp_allocator) == "hello-world")
	testing.expect(t, normalize_skill_name("foo_bar", context.temp_allocator) == "foo-bar")
	testing.expect(t, normalize_skill_name("OK", context.temp_allocator) == "ok")
}

@(test)
test_parse_frontmatter :: proc(t: ^testing.T) {
	raw :=
		"---\n" +
		"name: my-skill\n" +
		"description: Does a thing when you ask.\n" +
		"---\n" +
		"\n# Body\n\nHello world.\n"
	sk := parse_skill_md(raw, "dir-name", "/tmp/x/SKILL.md", context.temp_allocator)
	testing.expect(t, sk.name == "my-skill", sk.name)
	testing.expect(t, strings.contains(sk.description, "Does a thing"), sk.description)
}

@(test)
test_parse_no_frontmatter :: proc(t: ^testing.T) {
	raw := "# Title\n\nFirst paragraph here.\n\nSecond.\n"
	sk := parse_skill_md(raw, "from-dir", "/p/SKILL.md", context.temp_allocator)
	testing.expect(t, sk.name == "from-dir", sk.name)
	testing.expect(t, strings.contains(sk.description, "First paragraph"), sk.description)
}

@(test)
test_discover_temp_tree :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-skills-test-%d", os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)

	skill_dir := fmt.tprintf("%s/.grok/skills/alpha", root)
	_ = os.make_directory_all(skill_dir)
	body := "---\nname: alpha\ndescription: Alpha skill for tests\n---\n\n# Alpha\n"
	path := fmt.tprintf("%s/SKILL.md", skill_dir)
	_ = os.write_entire_file(path, transmute([]byte)body)

	list := discover_skills_simple(root, context.allocator)
	defer {
		for &s in list {
			destroy_parsed_skill(&s)
		}
		delete(list)
	}
	testing.expectf(t, len(list) >= 1, "len=%d", len(list))
	found := false
	for s in list {
		if s.name == "alpha" {
			found = true
			testing.expect(t, strings.contains(s.description, "Alpha skill"))
			testing.expect(t, s.kind == .Skill)
		}
	}
	testing.expect(t, found, "alpha skill")
}

@(test)
test_discover_command_md :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-cmd-test-%d", os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)
	cmd_dir := fmt.tprintf("%s/.grok/commands", root)
	_ = os.make_directory_all(cmd_dir)
	path := fmt.tprintf("%s/commit.md", cmd_dir)
	_ = os.write_entire_file(path, transmute([]byte)string("# Commit helper\n\nDo the commit.\n"))

	list := discover_skills_simple(root, context.allocator)
	defer {
		for &s in list {
			destroy_parsed_skill(&s)
		}
		delete(list)
	}
	found := false
	for s in list {
		if s.name == "commit" {
			found = true
			testing.expect(t, s.kind == .Command)
			testing.expect(t, strings.contains(s.description, "Commit"))
		}
	}
	testing.expect(t, found, "commit command")
}

@(test)
test_disabled_blocks_model_not_user :: proc(t: ^testing.T) {
	reg := Skill_Registry {
		skills = make([dynamic]Parsed_Skill, 0, 1, context.allocator),
	}
	defer {
		for &s in reg.skills {
			destroy_parsed_skill(&s)
		}
		delete(reg.skills)
	}
	// Write a temp body file
	path := fmt.tprintf("/tmp/aether-skill-body-%d.md", os.get_pid())
	_ = os.write_entire_file(path, transmute([]byte)string("body text\n"))
	defer os.remove(path)
	append(
		&reg.skills,
		Parsed_Skill {
			name        = strings.clone("secret", context.allocator),
			description = strings.clone("d", context.allocator),
			path        = strings.clone(path, context.allocator),
			dir         = strings.clone("/tmp", context.allocator),
			kind        = .Skill,
			disabled    = true,
		},
	)
	model := invoke_skill(&reg, "secret", "", context.allocator, true)
	defer delete(model)
	testing.expect(t, strings.contains(model, "disabled"))
	user := invoke_skill(&reg, "secret", "", context.allocator, false)
	defer delete(user)
	testing.expect(t, strings.contains(user, "body text"))
	cat := format_catalog(&reg, context.allocator)
	defer delete(cat)
	testing.expect(t, !strings.contains(cat, "secret"))
}

@(test)
test_ignore_and_disabled_config :: proc(t: ^testing.T) {
	cfg := Skills_Config {
		paths    = make([dynamic]string, 0, 0, context.allocator),
		ignore   = make([dynamic]string, 0, 1, context.allocator),
		disabled = make([dynamic]string, 0, 1, context.allocator),
	}
	defer destroy_skills_config(&cfg)
	append(&cfg.disabled, strings.clone("secret", context.allocator))
	testing.expect(t, is_name_disabled(cfg, "secret"))
	testing.expect(t, is_name_disabled(cfg, "Secret"))
	testing.expect(t, !is_name_disabled(cfg, "other"))
}

@(test)
test_parse_toml_string_list :: proc(t: ^testing.T) {
	items := parse_toml_string_list(`["a", "b"]`, context.allocator)
	defer {
		for it in items {
			delete(it)
		}
		delete(items)
	}
	testing.expect(t, len(items) == 2)
	testing.expect(t, items[0] == "a")
	testing.expect(t, items[1] == "b")
}

@(test)
test_skill_wins_over_command_name :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-skill-win-%d", os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)
	// skill package named review
	sd := fmt.tprintf("%s/.grok/skills/review", root)
	_ = os.make_directory_all(sd)
	_ = os.write_entire_file(
		fmt.tprintf("%s/SKILL.md", sd),
		transmute([]byte)string("---\nname: review\ndescription: package skill\n---\n\n# pkg\n"),
	)
	// command with same name
	cd := fmt.tprintf("%s/.grok/commands", root)
	_ = os.make_directory_all(cd)
	_ = os.write_entire_file(
		fmt.tprintf("%s/review.md", cd),
		transmute([]byte)string("# cmd review\n"),
	)
	list := discover_skills_simple(root, context.allocator)
	defer {
		for &s in list {
			destroy_parsed_skill(&s)
		}
		delete(list)
	}
	count := 0
	for s in list {
		if s.name == "review" {
			count += 1
			testing.expect(t, s.kind == .Skill)
			testing.expect(t, strings.contains(s.description, "package"))
		}
	}
	testing.expect(t, count == 1)
}

@(test)
test_cursor_skills_and_vendor_filter :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-cursor-skills-%d", os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)

	// useful cursor skill
	custom := fmt.tprintf("%s/.cursor/skills/my-cursor", root)
	_ = os.make_directory_all(custom)
	_ = os.write_entire_file(
		fmt.tprintf("%s/SKILL.md", custom),
		transmute([]byte)string(
			"---\nname: my-cursor\ndescription: Cursor-local skill\n---\n\n# ok\n",
		),
	)
	// vendor defaults that Grok filters
	vendor := [3]string{"shell", "canvas", "statusline"}
	for name in vendor {
		d := fmt.tprintf("%s/.cursor/skills/%s", root, name)
		_ = os.make_directory_all(d)
		_ = os.write_entire_file(
			fmt.tprintf("%s/SKILL.md", d),
			transmute([]byte)fmt.tprintf(
				"---\nname: %s\ndescription: vendor\n---\n\n# x\n",
				name,
			),
		)
	}
	// .agents/commands
	ac := fmt.tprintf("%s/.agents/commands", root)
	_ = os.make_directory_all(ac)
	_ = os.write_entire_file(
		fmt.tprintf("%s/agents-cmd.md", ac),
		transmute([]byte)string("# Agents command\n"),
	)

	list := discover_skills_simple(root, context.allocator)
	defer {
		for &s in list {
			destroy_parsed_skill(&s)
		}
		delete(list)
	}

	has_cursor := false
	has_agents := false
	for s in list {
		testing.expect(t, s.name != "shell")
		testing.expect(t, s.name != "canvas")
		testing.expect(t, s.name != "statusline")
		if s.name == "my-cursor" {
			has_cursor = true
		}
		if s.name == "agents-cmd" {
			has_agents = true
			testing.expect(t, s.kind == .Command)
		}
	}
	testing.expect(t, has_cursor)
	testing.expect(t, has_agents)
	testing.expect(t, is_cursor_vendor_default("shell"))
	testing.expect(t, !is_cursor_vendor_default("my-cursor"))
}
