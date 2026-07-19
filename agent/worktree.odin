package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// Isolation_Mode for spawn_subagent.
Isolation_Mode :: enum {
	None,
	Worktree,
}

// worktree_enabled is true unless AETHER_NO_WORKTREE=1/true.
worktree_enabled :: proc() -> bool {
	v := os.get_env("AETHER_NO_WORKTREE", context.temp_allocator)
	if v == "1" || strings.equal_fold(v, "true") {
		return false
	}
	return true
}

// isolation_from_string parses isolation tool arg. ok=false on unknown non-empty value.
isolation_from_string :: proc(s: string) -> (Isolation_Mode, bool) {
	t := strings.trim_space(s)
	if t == "" ||
	   strings.equal_fold(t, "null") ||
	   strings.equal_fold(t, "none") ||
	   strings.equal_fold(t, "undefined") {
		return .None, true
	}
	if strings.equal_fold(t, "worktree") || strings.equal_fold(t, "work_tree") {
		return .Worktree, true
	}
	return .None, false
}

// worktree_base_dir returns AETHER_WORKTREE_DIR or ~/.grok/aether/worktrees (allocated).
worktree_base_dir :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_WORKTREE_DIR", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	home := core.grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "aether", "worktrees"}, allocator)
	return joined
}

// git_toplevel returns the git worktree root for cwd, or err.
git_toplevel :: proc(cwd: string, allocator := context.allocator) -> (path: string, err: string) {
	if cwd == "" {
		return "", strings.clone("error: workspace is empty", allocator)
	}
	state, stdout, stderr, perr := os.process_exec(
		{
			command     = {"git", "-C", cwd, "rev-parse", "--show-toplevel"},
			working_dir = cwd,
		},
		context.temp_allocator,
	)
	if perr != nil {
		return "", fmt.aprintf(
			"error: failed to run git (is git installed?): %v",
			perr,
			allocator = allocator,
		)
	}
	if state.exit_code != 0 {
		msg := strings.trim_space(string(stderr))
		if msg == "" {
			msg = strings.trim_space(string(stdout))
		}
		if msg == "" {
			msg = "not a git repository"
		}
		return "", fmt.aprintf("error: git toplevel: %s", msg, allocator = allocator)
	}
	root := strings.trim_space(string(stdout))
	if root == "" {
		return "", strings.clone("error: empty git toplevel", allocator)
	}
	return strings.clone(root, allocator), ""
}

// repo_slug_from_path makes a filesystem-safe short name from a path.
repo_slug_from_path :: proc(path: string, allocator := context.allocator) -> string {
	base := filepath.base(path)
	if base == "" || base == "." || base == "/" {
		base = "repo"
	}
	// Replace awkward chars
	b := strings.builder_make(allocator)
	for i in 0 ..< len(base) {
		ch := base[i]
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') ||
		   ch == '-' ||
		   ch == '_' ||
		   ch == '.' {
			strings.write_byte(&b, ch)
		} else {
			strings.write_byte(&b, '_')
		}
	}
	out := strings.to_string(b)
	if out == "" {
		return strings.clone("repo", allocator)
	}
	return out
}

// create_subagent_worktree adds a detached linked worktree for task_id under the worktree base.
// Returns absolute path to the new worktree (allocated) or err.
create_subagent_worktree :: proc(
	parent_cwd: string,
	task_id: string,
	allocator := context.allocator,
) -> (path: string, err: string) {
	if !worktree_enabled() {
		return "", strings.clone(
			"error: worktree isolation disabled (AETHER_NO_WORKTREE=1)",
			allocator,
		)
	}
	root, rerr := git_toplevel(parent_cwd, context.temp_allocator)
	if rerr != "" {
		return "", strings.clone(rerr, allocator)
	}
	base := worktree_base_dir(context.temp_allocator)
	if !core.ensure_dir(base) {
		return "", fmt.aprintf(
			"error: cannot create worktree base dir %s",
			base,
			allocator = allocator,
		)
	}
	slug := repo_slug_from_path(root, context.temp_allocator)
	// Sanitize task_id for path segment
	safe_id := repo_slug_from_path(task_id, context.temp_allocator)
	dir_name := fmt.tprintf("%s-%s", slug, safe_id)
	wt_path, _ := filepath.join({base, dir_name}, context.temp_allocator)
	// Absolute for tools
	abs_wt, aerr := filepath.abs(wt_path, allocator)
	if aerr != nil {
		abs_wt = strings.clone(wt_path, allocator)
	}
	// If path already exists, refuse rather than clobber
	if os.exists(abs_wt) {
		return "", fmt.aprintf(
			"error: worktree path already exists: %s",
			abs_wt,
			allocator = allocator,
		)
	}
	state, stdout, stderr, perr := os.process_exec(
		{
			command     = {"git", "-C", root, "worktree", "add", "--detach", abs_wt},
			working_dir = root,
		},
		context.temp_allocator,
	)
	if perr != nil {
		delete(abs_wt)
		return "", fmt.aprintf("error: git worktree add failed to start: %v", perr, allocator = allocator)
	}
	if state.exit_code != 0 {
		delete(abs_wt)
		msg := strings.trim_space(string(stderr))
		if msg == "" {
			msg = strings.trim_space(string(stdout))
		}
		return "", fmt.aprintf("error: git worktree add failed: %s", msg, allocator = allocator)
	}
	if !os.is_directory(abs_wt) {
		delete(abs_wt)
		return "", strings.clone("error: worktree path missing after git worktree add", allocator)
	}
	return abs_wt, ""
}
