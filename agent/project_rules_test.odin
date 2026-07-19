package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_discover_project_rules_agents_md :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-rules-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	// nested path with AGENTS.md
	sub, _ := filepath.join({dir, "src"}, context.temp_allocator)
	_ = os.make_directory_all(sub)
	root_agents, _ := filepath.join({dir, "AGENTS.md"}, context.temp_allocator)
	sub_agents, _ := filepath.join({sub, "AGENTS.md"}, context.temp_allocator)
	_ = os.write_entire_file(root_agents, transmute([]byte)string("# Root\nUse TypeScript.\n"))
	_ = os.write_entire_file(sub_agents, transmute([]byte)string("# Nested\nPrefer hooks.\n"))
	// init git so chain root→cwd works
	{
		_, _, _, _ = os.process_exec(
			{command = {"git", "init"}, working_dir = dir},
			context.temp_allocator,
		)
	}

	prev := os.get_env("AETHER_NO_PROJECT_RULES", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_PROJECT_RULES")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_PROJECT_RULES", prev)
		}
	}

	files := discover_project_rules(sub, context.allocator)
	defer destroy_rule_files(files)
	testing.expect(t, len(files) >= 2, "should find root + nested AGENTS.md")

	sec := format_project_rules_section(sub, context.allocator)
	defer delete(sec)
	testing.expect(t, strings.contains(sec, "Project rules"))
	testing.expect(t, strings.contains(sec, "TypeScript") || strings.contains(sec, "Root"))
	testing.expect(t, strings.contains(sec, "Prefer hooks") || strings.contains(sec, "Nested"))

	// opt-out
	_ = os.set_env("AETHER_NO_PROJECT_RULES", "1")
	sec2 := format_project_rules_section(sub, context.allocator)
	testing.expect(t, sec2 == "")
	_ = os.unset_env("AETHER_NO_PROJECT_RULES")
}

@(test)
test_discover_claude_cursor_rules_dirs :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-rules-vendor-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	// .claude/CLAUDE.md + .claude/rules/foo.md + .cursor/rules/bar.md
	cdir, _ := filepath.join({dir, ".claude"}, context.temp_allocator)
	crules, _ := filepath.join({cdir, "rules"}, context.temp_allocator)
	udir, _ := filepath.join({dir, ".cursor", "rules"}, context.temp_allocator)
	_ = os.make_directory_all(crules)
	_ = os.make_directory_all(udir)

	claude_md, _ := filepath.join({cdir, "CLAUDE.md"}, context.temp_allocator)
	claude_rule, _ := filepath.join({crules, "style.md"}, context.temp_allocator)
	cursor_rule, _ := filepath.join({udir, "cursor.md"}, context.temp_allocator)
	_ = os.write_entire_file(claude_md, transmute([]byte)string("Claude project memory.\n"))
	_ = os.write_entire_file(claude_rule, transmute([]byte)string("Claude rules style.\n"))
	_ = os.write_entire_file(cursor_rule, transmute([]byte)string("Cursor rules tip.\n"))

	_, _, _, _ = os.process_exec(
		{command = {"git", "init"}, working_dir = dir},
		context.temp_allocator,
	)

	_ = os.unset_env("AETHER_NO_PROJECT_RULES")
	_ = os.unset_env("AETHER_NO_CLAUDE_RULES")
	_ = os.unset_env("AETHER_NO_CLAUDE_SKILLS")
	_ = os.unset_env("AETHER_NO_CURSOR_RULES")
	_ = os.unset_env("AETHER_NO_CURSOR_SKILLS")

	files := discover_project_rules(dir, context.allocator)
	defer destroy_rule_files(files)
	joined := ""
	for f in files {
		joined = fmt.tprintf("%s\n%s\n%s", joined, f.path, f.content)
	}
	testing.expect(t, strings.contains(joined, "Claude project memory"))
	testing.expect(t, strings.contains(joined, "Claude rules style"))
	testing.expect(t, strings.contains(joined, "Cursor rules tip"))

	// Claude off → no claude paths
	_ = os.set_env("AETHER_NO_CLAUDE_RULES", "1")
	files2 := discover_project_rules(dir, context.allocator)
	defer destroy_rule_files(files2)
	j2 := ""
	for f in files2 {
		j2 = fmt.tprintf("%s\n%s", j2, f.content)
	}
	testing.expect(t, !strings.contains(j2, "Claude project memory"))
	testing.expect(t, strings.contains(j2, "Cursor rules tip"))
	_ = os.unset_env("AETHER_NO_CLAUDE_RULES")
}

@(test)
test_prompt_history_collect_filter :: proc(t: ^testing.T) {
	msgs := []Chat_Message {
		{role = .System, content = "sys"},
		{role = .User, content = "alpha one"},
		{role = .Assistant, content = "ok"},
		{role = .User, content = "beta two"},
		{role = .User, content = "alpha three"},
	}
	all := collect_user_prompts(msgs, context.allocator)
	defer destroy_string_list(all)
	testing.expect(t, len(all) == 3)
	testing.expect(t, all[0] == "alpha three") // newest first
	testing.expect(t, all[2] == "alpha one")

	filt := filter_prompts(all, "alpha", context.allocator)
	defer destroy_string_list(filt)
	testing.expect(t, len(filt) == 2)

	n, ok := parse_history_index("2")
	testing.expect(t, ok && n == 2)
	_, ok2 := parse_history_index("nope")
	testing.expect(t, !ok2)
}
