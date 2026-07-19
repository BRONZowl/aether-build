// Project rules discovery (Grok AGENTS.md / vendor rules dirs) for system prompt inject.
// Opt out all: AETHER_NO_PROJECT_RULES=1
// Opt out Claude paths: AETHER_NO_CLAUDE_RULES=1 (also respects AETHER_NO_CLAUDE_SKILLS=1)
// Opt out Cursor paths: AETHER_NO_CURSOR_RULES=1 (also respects AETHER_NO_CURSOR_SKILLS=1)
package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

PROJECT_RULES_MAX_BYTES :: 48_000
PROJECT_RULES_FILE_MAX :: 24_000

PROJECT_RULE_BASENAMES :: []string {
	"AGENTS.md",
	"Agents.md",
	"AGENT.md",
	"CLAUDE.md",
	"Claude.md",
	"CLAUDE.local.md",
}

// Nested under .claude/ at each dir (Claude Code layout).
CLAUDE_NESTED_BASENAMES :: []string {
	"CLAUDE.md",
	"CLAUDE.local.md",
}

project_rules_enabled :: proc() -> bool {
	v := os.get_env("AETHER_NO_PROJECT_RULES", context.temp_allocator)
	if v == "1" || strings.equal_fold(v, "true") {
		return false
	}
	return true
}

claude_rules_enabled :: proc() -> bool {
	for key in ([]string{"AETHER_NO_CLAUDE_RULES", "AETHER_NO_CLAUDE_SKILLS"}) {
		v := os.get_env(key, context.temp_allocator)
		if v == "1" || strings.equal_fold(v, "true") {
			return false
		}
	}
	return true
}

cursor_rules_enabled :: proc() -> bool {
	for key in ([]string{"AETHER_NO_CURSOR_RULES", "AETHER_NO_CURSOR_SKILLS"}) {
		v := os.get_env(key, context.temp_allocator)
		if v == "1" || strings.equal_fold(v, "true") {
			return false
		}
	}
	return true
}

Rule_File :: struct {
	path:    string,
	content: string,
}

destroy_rule_files :: proc(files: []Rule_File) {
	for f in files {
		delete(f.path)
		delete(f.content)
	}
	delete(files)
}

// discover_project_rules: global homes then repo root→cwd (or cwd only).
// Order: ~/.grok → ~/.claude → ~/.cursor → (root…cwd) each with named files + vendor rules dirs.
// Caller owns via destroy_rule_files.
discover_project_rules :: proc(cwd: string, allocator := context.allocator) -> []Rule_File {
	if !project_rules_enabled() || strings.trim_space(cwd) == "" {
		return nil
	}

	out := make([dynamic]Rule_File, 0, 8, allocator)
	seen := make(map[string]bool, 16, context.temp_allocator)

	// --- global homes ---
	home := core.grok_home(context.temp_allocator)
	if home != "" {
		collect_named_rules(home, &out, &seen, allocator)
		rd, _ := filepath.join({home, "rules"}, context.temp_allocator)
		collect_md_dir(rd, &out, &seen, allocator)
	}

	uhome, uerr := os.user_home_dir(context.temp_allocator)
	if uerr == nil && uhome != "" {
		if claude_rules_enabled() {
			ch, _ := filepath.join({uhome, ".claude"}, context.temp_allocator)
			collect_named_rules(ch, &out, &seen, allocator)
			crd, _ := filepath.join({ch, "rules"}, context.temp_allocator)
			collect_md_dir(crd, &out, &seen, allocator)
		}
		if cursor_rules_enabled() {
			cu, _ := filepath.join({uhome, ".cursor"}, context.temp_allocator)
			collect_named_rules(cu, &out, &seen, allocator)
			urd, _ := filepath.join({cu, "rules"}, context.temp_allocator)
			collect_md_dir(urd, &out, &seen, allocator)
		}
	}

	// --- root → cwd chain ---
	dirs := path_chain_root_to_cwd(cwd, context.allocator)
	defer {
		for d in dirs {
			delete(d)
		}
		delete(dirs)
	}
	for dir in dirs {
		collect_dir_level_rules(dir, &out, &seen, allocator)
	}

	return out[:]
}

// collect_dir_level_rules: named files + .grok/rules + optional .claude/.cursor nests.
@(private)
collect_dir_level_rules :: proc(
	dir: string,
	out: ^[dynamic]Rule_File,
	seen: ^map[string]bool,
	allocator := context.allocator,
) {
	collect_named_rules(dir, out, seen, allocator)

	gdir, _ := filepath.join({dir, ".grok", "rules"}, context.temp_allocator)
	collect_md_dir(gdir, out, seen, allocator)

	if claude_rules_enabled() {
		// <dir>/.claude/CLAUDE.md (+ local) and <dir>/.claude/rules/*.md
		cbase, _ := filepath.join({dir, ".claude"}, context.temp_allocator)
		for name in CLAUDE_NESTED_BASENAMES {
			p, _ := filepath.join({cbase, name}, context.temp_allocator)
			try_add_file(p, out, seen, allocator)
		}
		crd, _ := filepath.join({cbase, "rules"}, context.temp_allocator)
		collect_md_dir(crd, out, seen, allocator)
	}

	if cursor_rules_enabled() {
		// <dir>/.cursor/rules/*.md (+ optional named files in .cursor/)
		cbase, _ := filepath.join({dir, ".cursor"}, context.temp_allocator)
		collect_named_rules(cbase, out, seen, allocator)
		urd, _ := filepath.join({cbase, "rules"}, context.temp_allocator)
		collect_md_dir(urd, out, seen, allocator)
	}
}

// format_project_rules_section builds markdown for the system prompt (owned).
// Empty string if nothing loaded.
format_project_rules_section :: proc(cwd: string, allocator := context.allocator) -> string {
	files := discover_project_rules(cwd, allocator)
	if len(files) == 0 {
		return ""
	}
	defer destroy_rule_files(files)

	b := strings.builder_make(allocator)
	strings.write_string(&b, "\n\n## Project rules\n\n")
	strings.write_string(
		&b,
		"The following project instruction files apply (deeper paths override earlier ones):\n",
	)
	total := 0
	for f in files {
		if total >= PROJECT_RULES_MAX_BYTES {
			strings.write_string(&b, "\n…(further project rules truncated)\n")
			break
		}
		strings.write_string(&b, "\n### ")
		strings.write_string(&b, f.path)
		strings.write_string(&b, "\n\n")
		body := f.content
		if len(body) > PROJECT_RULES_FILE_MAX {
			body = body[:PROJECT_RULES_FILE_MAX]
			strings.write_string(&b, body)
			strings.write_string(&b, "\n…(file truncated)\n")
			total += PROJECT_RULES_FILE_MAX
		} else {
			strings.write_string(&b, body)
			if !strings.has_suffix(body, "\n") {
				strings.write_byte(&b, '\n')
			}
			total += len(body)
		}
	}
	return strings.to_string(b)
}

// --- internals ---

@(private)
path_chain_root_to_cwd :: proc(cwd: string, allocator := context.allocator) -> []string {
	clean, _ := filepath.clean(cwd, context.temp_allocator)
	root, gerr := git_toplevel(cwd, context.temp_allocator)
	stack := make([dynamic]string, 0, 8, context.temp_allocator)

	if gerr != "" || root == "" {
		// cwd only
		out := make([]string, 1, allocator)
		out[0] = strings.clone(clean, allocator)
		return out
	}

	root_c, _ := filepath.clean(root, context.temp_allocator)
	cur := clean
	for {
		append(&stack, cur)
		if cur == root_c {
			break
		}
		parent := filepath.dir(cur)
		if parent == "" || parent == cur {
			break
		}
		// left the repo?
		if !path_is_under(parent, root_c) && parent != root_c {
			break
		}
		cur = parent
	}

	// stack: cwd … root → reverse to root … cwd
	n := len(stack)
	out := make([]string, n, allocator)
	for i := 0; i < n; i += 1 {
		out[i] = strings.clone(stack[n - 1 - i], allocator)
	}
	return out
}

@(private)
path_is_under :: proc(path: string, root: string) -> bool {
	if path == root {
		return true
	}
	// root/ prefix
	if strings.has_prefix(path, root) {
		if len(path) > len(root) && (path[len(root)] == '/' || path[len(root)] == '\\') {
			return true
		}
	}
	return false
}

@(private)
collect_named_rules :: proc(
	dir: string,
	out: ^[dynamic]Rule_File,
	seen: ^map[string]bool,
	allocator := context.allocator,
) {
	for name in PROJECT_RULE_BASENAMES {
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		try_add_file(p, out, seen, allocator)
	}
}

@(private)
collect_md_dir :: proc(
	dir: string,
	out: ^[dynamic]Rule_File,
	seen: ^map[string]bool,
	allocator := context.allocator,
) {
	if dir == "" || !os.is_dir(dir) {
		return
	}
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in entries {
		if fi.type == .Directory {
			continue
		}
		name := fi.name
		if !strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".md") {
			continue
		}
		p, _ := filepath.join({dir, name}, context.temp_allocator)
		try_add_file(p, out, seen, allocator)
	}
}

@(private)
try_add_file :: proc(
	path: string,
	out: ^[dynamic]Rule_File,
	seen: ^map[string]bool,
	allocator := context.allocator,
) {
	if path == "" || !os.exists(path) || os.is_dir(path) {
		return
	}
	// dedupe by cleaned path
	key, _ := filepath.clean(path, context.temp_allocator)
	if seen[key] {
		return
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(data) == 0 {
		return
	}
	// skip empty/whitespace-only
	text := strings.trim_space(string(data))
	if text == "" {
		return
	}
	seen[key] = true
	append(
		out,
		Rule_File {
			path    = strings.clone(key, allocator),
			content = strings.clone(string(data), allocator),
		},
	)
}
