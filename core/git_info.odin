// Lightweight git location info for TUI chrome (Grok-shaped status bar).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Cache TTL between filesystem probes (paint path must stay cheap).
GIT_BRANCH_TTL_NS :: i64(5_000_000_000)

g_git_cwd: string // owned
g_git_branch: string // owned; "" = not a repo / unknown
g_git_ns: i64

// git_branch_cached returns branch shorthand for cwd ("" if not a repo).
// Result is owned by the cache; copy if you need to retain past next probe.
// Safe to call from the TUI paint path — only re-reads .git/HEAD after TTL.
git_branch_cached :: proc(cwd: string) -> string {
	path := cwd if cwd != "" else "."
	now := time.now()._nsec
	if g_git_cwd == path && (now - g_git_ns) < GIT_BRANCH_TTL_NS {
		return g_git_branch
	}
	branch := git_branch_read(path, context.temp_allocator)
	delete(g_git_cwd)
	delete(g_git_branch)
	g_git_cwd = strings.clone(path)
	g_git_branch = strings.clone(branch)
	g_git_ns = now
	return g_git_branch
}

// git_branch_read walks up from start looking for .git/HEAD (or worktree gitdir).
// Returns branch name, "detached", or "" if not in a repo. Allocated with allocator.
git_branch_read :: proc(start: string, allocator := context.allocator) -> string {
	dir := start if start != "" else "."
	abs, aerr := filepath.abs(dir, context.temp_allocator)
	if aerr != nil {
		abs = dir
	}
	cur := abs
	for i in 0 ..< 48 {
		git_path, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		head_path := ""
		if os.is_dir(git_path) {
			head_path, _ = filepath.join({git_path, "HEAD"}, context.temp_allocator)
		} else if os.exists(git_path) && !os.is_dir(git_path) {
			// worktree: .git file contains "gitdir: <path>"
			data, rerr := os.read_entire_file(git_path, context.temp_allocator)
			if rerr == nil {
				line := strings.trim_space(string(data))
				if strings.has_prefix(line, "gitdir:") {
					gd := strings.trim_space(line[len("gitdir:"):])
					if !filepath.is_abs(gd) {
						gd, _ = filepath.join({cur, gd}, context.temp_allocator)
					}
					head_path, _ = filepath.join({gd, "HEAD"}, context.temp_allocator)
				}
			}
		}
		if head_path != "" && os.exists(head_path) {
			return parse_git_head_file(head_path, allocator)
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "" {
			break
		}
		cur = parent
		_ = i
	}
	return strings.clone("", allocator)
}

parse_git_head_file :: proc(path: string, allocator := context.allocator) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return strings.clone("", allocator)
	}
	line := strings.trim_space(string(data))
	// ref: refs/heads/main
	if strings.has_prefix(line, "ref:") {
		ref := strings.trim_space(line[len("ref:"):])
		if strings.has_prefix(ref, "refs/heads/") {
			return strings.clone(ref[len("refs/heads/"):], allocator)
		}
		// other ref types
		if i := strings.last_index_byte(ref, '/'); i >= 0 && i + 1 < len(ref) {
			return strings.clone(ref[i + 1:], allocator)
		}
		return strings.clone(ref, allocator)
	}
	// detached HEAD — full hash; show short
	if len(line) >= 7 {
		return strings.clone(line[:7], allocator)
	}
	if line != "" {
		return strings.clone(line, allocator)
	}
	return strings.clone("detached", allocator)
}

// format_cwd_display collapses $HOME → ~ for chrome (Grok-shaped).
// Result allocated with allocator.
format_cwd_display :: proc(cwd: string, allocator := context.allocator) -> string {
	path := cwd if cwd != "" else "."
	abs, aerr := filepath.abs(path, context.temp_allocator)
	if aerr == nil {
		path = abs
	}
	home, herr := os.user_home_dir(context.temp_allocator)
	if herr == nil && home != "" {
		if path == home {
			return strings.clone("~", allocator)
		}
		// home-relative path: ~/…
		if len(path) > len(home) && path[:len(home)] == home && path[len(home)] == '/' {
			return strings.concatenate({"~", path[len(home):]}, allocator)
		}
	}
	return strings.clone(path, allocator)
}
