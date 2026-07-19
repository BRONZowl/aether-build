// Package agent — /create-skill scaffold (M10).
// Writes ~/.grok/skills/<name>/SKILL.md or <cwd>/.grok/skills/<name>/SKILL.md
// then reloads the skills registry.
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// validate_skill_name: lowercase a-z, 0-9, hyphen; 2–64; start/end alnum.
validate_skill_name :: proc(name: string) -> string /* err */ {
	if len(name) < 2 || len(name) > 64 {
		return "name must be 2–64 characters"
	}
	for i in 0 ..< len(name) {
		c := name[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			return "name: lowercase letters, digits, hyphens only"
		}
	}
	first := name[0]
	last := name[len(name) - 1]
	if first == '-' || last == '-' {
		return "name must start and end with a letter or digit"
	}
	if !((first >= 'a' && first <= 'z') || (first >= '0' && first <= '9')) {
		return "name must start with a letter or digit"
	}
	return ""
}

// handle_create_skill_slash: /create-skill <name> [user|project] [description…]
handle_create_skill_slash :: proc(
	arg: string,
	cwd: string,
	allocator := context.allocator,
) -> string {
	a := strings.trim_space(arg)
	if a == "" || a == "help" || a == "?" {
		return strings.clone(
			"Usage: /create-skill <name> [user|project] [description…]\n" +
			"  name       lowercase a-z, 0-9, hyphens (2–64 chars)\n" +
			"  user       ~/.grok/skills/<name>/SKILL.md (default if not in git)\n" +
			"  project    <cwd>/.grok/skills/<name>/SKILL.md (default if in git repo)\n" +
			"  description  optional; used in frontmatter (default stub)\n" +
			"Reloads skills after create. Opt-out: AETHER_NO_SKILLS=1.",
			allocator,
		)
	}
	// parse tokens
	parts := strings.fields(a)
	if len(parts) == 0 {
		return handle_create_skill_slash("help", cwd, allocator)
	}
	name := parts[0]
	if err := validate_skill_name(name); err != "" {
		return fmt.aprintf("aether: create-skill: %s", err, allocator = allocator)
	}
	scope := ""
	desc_start := 1
	if len(parts) >= 2 {
		s := strings.to_lower(parts[1], context.temp_allocator)
		if s == "user" || s == "project" || s == "global" || s == "local" {
			scope = s
			if scope == "global" {
				scope = "user"
			}
			if scope == "local" {
				scope = "project"
			}
			desc_start = 2
		}
	}
	if scope == "" {
		// default: project if .git exists under cwd, else user
		git_dir, _ := filepath.join({cwd if cwd != "" else ".", ".git"}, context.temp_allocator)
		if os.exists(git_dir) {
			scope = "project"
		} else {
			scope = "user"
		}
	}
	desc := ""
	if desc_start < len(parts) {
		// rejoin remaining
		b := strings.builder_make(context.temp_allocator)
		for i in desc_start ..< len(parts) {
			if i > desc_start {
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, parts[i])
		}
		desc = strings.to_string(b)
	}
	if desc == "" {
		desc = fmt.tprintf(
			"Skill `%s`. Use when the user runs /%s or asks for this workflow.",
			name,
			name,
		)
	}

	skill_dir: string
	if scope == "user" {
		home := core.grok_home(context.temp_allocator)
		skill_dir, _ = filepath.join({home, "skills", name}, context.temp_allocator)
	} else {
		base := cwd if cwd != "" else "."
		skill_dir, _ = filepath.join({base, ".grok", "skills", name}, context.temp_allocator)
	}
	abs_dir, aerr := filepath.abs(skill_dir, context.temp_allocator)
	if aerr == nil {
		skill_dir = abs_dir
	}

	skill_md, _ := filepath.join({skill_dir, "SKILL.md"}, context.temp_allocator)
	if os.exists(skill_md) {
		return fmt.aprintf(
			"aether: skill already exists: %s\n(edit or pick another name)",
			skill_md,
			allocator = allocator,
		)
	}
	if !core.ensure_dir(skill_dir) {
		return fmt.aprintf("aether: could not create directory %s", skill_dir, allocator = allocator)
	}

	body := fmt.tprintf(
		"---\nname: %s\ndescription: >\n  %s\n---\n\n# %s\n\n## When to use\n\n%s\n\n## Steps\n\n1. Confirm the user intent matches this skill.\n2. Follow the procedure below (customize this body).\n3. Report results to the user.\n\n## Procedure\n\n_TODO: write actionable steps for the agent._\n",
		name,
		desc,
		name,
		desc,
	)
	if os.write_entire_file(skill_md, transmute([]byte)body) != nil {
		return fmt.aprintf("aether: failed to write %s", skill_md, allocator = allocator)
	}

	// reload skills
	reload := reload_skills_for_cwd(cwd, true)
	return fmt.aprintf(
		"aether: skill created\n  path: %s\n  slash: /%s\n  scope: %s\n%s",
		skill_md,
		name,
		scope,
		reload,
		allocator = allocator,
	)
}
