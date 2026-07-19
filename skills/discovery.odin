package skills

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// collect_skill_roots returns skill package roots low→high priority (later wins on name).
// Order mirrors Grok: bundled/user vendor → user grok → walk ancestors (claude/cursor/agents/grok).
collect_skill_roots :: proc(
	cwd: string,
	with_claude: bool,
	with_cursor: bool,
	allocator := context.allocator,
) -> []string {
	roots := make([dynamic]string, 0, 32, allocator)

	home := core.grok_home(context.temp_allocator)
	append_root(&roots, fmt.tprintf("%s/bundled/skills", home), allocator)
	uhome, _ := os.user_home_dir(context.temp_allocator)
	if with_claude && uhome != "" {
		append_root(&roots, fmt.tprintf("%s/.claude/skills", uhome), allocator)
	}
	if with_cursor && uhome != "" {
		append_root(&roots, fmt.tprintf("%s/.cursor/skills", uhome), allocator)
	}
	append_root(&roots, fmt.tprintf("%s/skills", home), allocator)

	// M4: user plugins skills (~/.grok/plugins/*/skills)
	plugins_user, _ := filepath.join({home, "plugins"}, context.temp_allocator)
	append_plugin_skill_roots(&roots, plugins_user, allocator)

	// walk from cwd up
	dir := cwd if cwd != "" else "."
	abs, aerr := filepath.abs(dir, context.temp_allocator)
	if aerr == nil {
		dir = abs
	}
	chain: [dynamic]string
	chain.allocator = context.temp_allocator
	for _ in 0 ..< 8 {
		append(&chain, dir)
		parent := filepath.dir(dir)
		if parent == dir || parent == "" {
			break
		}
		dir = parent
	}
	// reverse: root first, cwd last (cwd highest priority)
	for i := len(chain) - 1; i >= 0; i -= 1 {
		d := chain[i]
		if with_claude {
			append_root(&roots, fmt.tprintf("%s/.claude/skills", d), allocator)
		}
		if with_cursor {
			append_root(&roots, fmt.tprintf("%s/.cursor/skills", d), allocator)
		}
		append_root(&roots, fmt.tprintf("%s/.agents/skills", d), allocator)
		append_root(&roots, fmt.tprintf("%s/.grok/skills", d), allocator)
		// M4: project plugins (only if folder trusted for that cwd level —
		// discovery always scans; hooks/plugins host gates project plugins
		// at list time; skills from untrusted project plugins still load if
		// present — gate skill scan by trust for project plugin root only)
		if core.project_scope_allowed(d) {
			pp, _ := filepath.join({d, ".grok", "plugins"}, context.temp_allocator)
			append_plugin_skill_roots(&roots, pp, allocator)
		}
	}

	return roots[:]
}

// append_plugin_skill_roots: each child plugin's skills/ dir (or plugin root with packages).
append_plugin_skill_roots :: proc(
	roots: ^[dynamic]string,
	plugins_root: string,
	allocator := context.allocator,
) {
	if plugins_root == "" || !os.exists(plugins_root) || !os.is_directory(plugins_root) {
		return
	}
	fis, err := os.read_all_directory_by_path(plugins_root, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in fis {
		if fi.type != .Directory || strings.has_prefix(fi.name, ".") {
			continue
		}
		pdir, _ := filepath.join({plugins_root, fi.name}, context.temp_allocator)
		sk, _ := filepath.join({pdir, "skills"}, context.temp_allocator)
		if os.exists(sk) && os.is_directory(sk) {
			append_root(roots, sk, allocator)
		} else {
			// plugin root may contain skill packages directly
			append_root(roots, pdir, allocator)
		}
	}
}

// collect_command_roots returns commands/ dirs low→high priority.
collect_command_roots :: proc(
	cwd: string,
	with_claude: bool,
	with_cursor: bool,
	allocator := context.allocator,
) -> []string {
	roots := make([dynamic]string, 0, 24, allocator)
	home := core.grok_home(context.temp_allocator)
	append_root(&roots, fmt.tprintf("%s/commands", home), allocator)
	uhome, _ := os.user_home_dir(context.temp_allocator)
	if with_claude && uhome != "" {
		append_root(&roots, fmt.tprintf("%s/.claude/commands", uhome), allocator)
	}
	if with_cursor && uhome != "" {
		append_root(&roots, fmt.tprintf("%s/.cursor/commands", uhome), allocator)
	}

	dir := cwd if cwd != "" else "."
	abs, aerr := filepath.abs(dir, context.temp_allocator)
	if aerr == nil {
		dir = abs
	}
	chain: [dynamic]string
	chain.allocator = context.temp_allocator
	for _ in 0 ..< 8 {
		append(&chain, dir)
		parent := filepath.dir(dir)
		if parent == dir || parent == "" {
			break
		}
		dir = parent
	}
	for i := len(chain) - 1; i >= 0; i -= 1 {
		d := chain[i]
		if with_claude {
			append_root(&roots, fmt.tprintf("%s/.claude/commands", d), allocator)
		}
		if with_cursor {
			append_root(&roots, fmt.tprintf("%s/.cursor/commands", d), allocator)
		}
		append_root(&roots, fmt.tprintf("%s/.agents/commands", d), allocator)
		append_root(&roots, fmt.tprintf("%s/.grok/commands", d), allocator)
	}
	return roots[:]
}

append_root :: proc(roots: ^[dynamic]string, path: string, allocator := context.allocator) {
	if path == "" || !os.exists(path) {
		return
	}
	if !os.is_directory(path) {
		return
	}
	for r in roots {
		if r == path {
			return
		}
	}
	append(roots, strings.clone(path, allocator))
}

// path_looks_like_cursor is true when the skill lives under a .cursor skills/commands tree.
path_looks_like_cursor :: proc(path: string) -> bool {
	p := strings.to_lower(path, context.temp_allocator)
	return strings.contains(p, "/.cursor/") || strings.has_prefix(p, ".cursor/")
}

// discover_skills walks roots + commands + config.paths; applies ignore/disabled.
discover_skills :: proc(
	cwd: string,
	cfg: Skills_Config,
	allocator := context.allocator,
) -> [dynamic]Parsed_Skill {
	out := make([dynamic]Parsed_Skill, 0, 32, allocator)
	with_claude := claude_skills_enabled()
	with_cursor := cursor_skills_enabled()

	roots := collect_skill_roots(cwd, with_claude, with_cursor, allocator)
	defer {
		for r in roots {
			delete(r)
		}
		delete(roots)
	}
	for root in roots {
		scan_skills_dir(root, 0, &out, allocator)
	}

	// Extra config paths (dirs or SKILL.md files)
	for p in cfg.paths {
		if p == "" {
			continue
		}
		if os.is_directory(p) {
			scan_skills_dir(p, 0, &out, allocator)
		} else if os.exists(p) {
			// single SKILL.md or file
			data, err := os.read_entire_file(p, context.temp_allocator)
			if err != nil {
				continue
			}
			base := filepath.stem(p)
			sk := parse_skill_md(string(data), base, p, allocator)
			delete(sk.dir)
			sk.dir = strings.clone(filepath.dir(p), allocator)
			upsert_skill_entry(&out, sk)
		}
	}

	// Commands after skills so package skills win name collisions
	cmd_roots := collect_command_roots(cwd, with_claude, with_cursor, allocator)
	defer {
		for r in cmd_roots {
			delete(r)
		}
		delete(cmd_roots)
	}
	for root in cmd_roots {
		scan_commands_dir(root, &out, allocator)
	}

	// Filter ignore + cursor vendor defaults + mark disabled
	filtered := make([dynamic]Parsed_Skill, 0, len(out), allocator)
	for &s in out {
		if path_is_ignored(cfg, s.path) || path_is_ignored(cfg, s.dir) {
			destroy_parsed_skill(&s)
			continue
		}
		if path_looks_like_cursor(s.path) && is_cursor_vendor_default(s.name) {
			destroy_parsed_skill(&s)
			continue
		}
		if is_name_disabled(cfg, s.name) {
			s.disabled = true
		}
		append(&filtered, s)
	}
	delete(out)
	// Sort by name for stable /skills
	sort_skills_by_name(filtered[:])
	return filtered
}

// discover_skills_simple for tests without config
discover_skills_simple :: proc(cwd: string, allocator := context.allocator) -> [dynamic]Parsed_Skill {
	cfg: Skills_Config
	return discover_skills(cwd, cfg, allocator)
}

sort_skills_by_name :: proc(list: []Parsed_Skill) {
	// insertion sort
	for i in 1 ..< len(list) {
		j := i
		for j > 0 && list[j - 1].name > list[j].name {
			list[j - 1], list[j] = list[j], list[j - 1]
			j -= 1
		}
	}
}

find_skill_index :: proc(out: []Parsed_Skill, name: string) -> int {
	for s, i in out {
		if s.name == name {
			return i
		}
	}
	return -1
}

upsert_skill_entry :: proc(out: ^[dynamic]Parsed_Skill, sk: Parsed_Skill) {
	if idx := find_skill_index(out[:], sk.name); idx >= 0 {
		if out[idx].kind == .Skill && sk.kind == .Command {
			// keep existing skill package; drop command
			s := sk
			destroy_parsed_skill(&s)
			return
		}
		destroy_parsed_skill(&out[idx])
		out[idx] = sk
		return
	}
	append(out, sk)
}

scan_skills_dir :: proc(
	dir: string,
	depth: int,
	out: ^[dynamic]Parsed_Skill,
	allocator := context.allocator,
) {
	if depth > 3 {
		return
	}
	skill_md, _ := filepath.join({dir, "SKILL.md"}, context.temp_allocator)
	if os.exists(skill_md) && !os.is_directory(skill_md) {
		data, err := os.read_entire_file(skill_md, context.temp_allocator)
		if err != nil {
			return
		}
		base := filepath.base(dir)
		sk := parse_skill_md(string(data), base, skill_md, allocator)
		delete(sk.dir)
		sk.dir = strings.clone(dir, allocator)
		upsert_skill_entry(out, sk)
		return // don't recurse into skill package
	}

	fis, ferr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if ferr != nil {
		return
	}
	for fi in fis {
		name := fi.name
		if name == "" || name[0] == '.' {
			continue
		}
		sub, _ := filepath.join({dir, name}, context.temp_allocator)
		if os.is_directory(sub) {
			scan_skills_dir(sub, depth + 1, out, allocator)
		}
	}
}

scan_commands_dir :: proc(
	dir: string,
	out: ^[dynamic]Parsed_Skill,
	allocator := context.allocator,
) {
	fis, ferr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if ferr != nil {
		return
	}
	for fi in fis {
		name := fi.name
		if name == "" || name[0] == '.' {
			continue
		}
		if !strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".md") {
			continue
		}
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		if os.is_directory(path) {
			continue
		}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			continue
		}
		stem := filepath.stem(name)
		sk := parse_command_md(string(data), stem, path, dir, allocator)
		upsert_skill_entry(out, sk)
	}
}
