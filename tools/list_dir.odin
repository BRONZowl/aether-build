// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

// list_dir — Grok-shaped directory listing.
// Reference: crates/.../grok_build/list_dir
// - Hide dotfiles/dotdirs
// - Respect .gitignore via `rg --files` allowlist when available
// - Tree format with nested expand under char budget
// - Large dirs summarized by extension breakdown

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

LIST_DIR_MAX_CHARS :: 10_000
LIST_DIR_TOP_K_EXTS :: 3
// Prefer expanding dirs with fewer immediate children first when budget is tight.
LIST_DIR_FAT_DIR_THRESHOLD :: 60

List_Entry_Kind :: enum {
	File,
	Dir,
}

List_Ext_Pair :: struct {
	ext:   string,
	count: int,
}

List_Node :: struct {
	name:     string, // file name or "name/" for dirs
	kind:     List_Entry_Kind,
	children: [dynamic]List_Node, // only for dirs when expanded in tree
	// subtree stats (files only) for collapse summary
	file_count: int,
	// extension counts packed as parallel arrays for small alloc
	exts:       [dynamic]string,
	ext_counts: [dynamic]int,
}

tool_list_dir :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	target := jstr(obj, "target_directory")
	if target == "" {
		target = jstr(obj, "path")
	}
	if target == "" {
		target = "."
	}

	abs, inside := resolve_in_workspace(workspace, target, context.temp_allocator)
	if !inside {
		return strings.clone("error: list_dir outside workspace is denied", allocator)
	}

	if !os.exists(abs) {
		return fmt.aprintf("error: path not found: %s", target, allocator = allocator)
	}
	if !os.is_directory(abs) {
		return fmt.aprintf(
			"error: %s is a file, not a directory (use read_file)",
			target,
			allocator = allocator,
		)
	}

	// Allowed files relative to abs (forward slashes). Empty map = no filter (rg failed).
	allow, use_allow := list_dir_rg_allowlist(abs, context.temp_allocator)

	root := list_dir_build_tree(abs, "", use_allow, &allow, context.temp_allocator)
	list_dir_sort_tree(&root)

	// Display path for header
	display := abs
	if t_abs, terr := filepath.abs(abs, context.temp_allocator); terr == nil {
		display = t_abs
	}

	body := list_dir_render(display, &root, LIST_DIR_MAX_CHARS, context.temp_allocator)
	return strings.clone(body, allocator)
}

// list_dir_rg_allowlist: relative paths under root that rg would list (gitignore-aware).
list_dir_rg_allowlist :: proc(
	root: string,
	allocator := context.allocator,
) -> (allow: map[string]bool, ok: bool) {
	args := []string{"rg", "--files", "--hidden", "--glob", "!.git/**", "--", root}
	state, stdout, _, err := os.process_exec(
		{command = args, working_dir = root},
		context.temp_allocator,
	)
	if err != nil || state.exit_code > 1 {
		return nil, false
	}
	allow = make(map[string]bool, allocator)
	root_prefix := root
	if !strings.has_suffix(root_prefix, "/") {
		root_prefix = fmt.tprintf("%s/", root)
	}
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		p := strings.trim_space(line)
		if p == "" {
			continue
		}
		// Make relative to root
		rel := p
		if strings.has_prefix(p, root_prefix) {
			rel = p[len(root_prefix):]
		} else if strings.has_prefix(p, root) && len(p) > len(root) &&
		   (p[len(root)] == '/' || p[len(root)] == '\\') {
			rel = p[len(root) + 1:]
		}
		rel, _ = strings.replace_all(rel, "\\", "/", context.temp_allocator)
		allow[strings.clone(rel, allocator)] = true
	}
	return allow, true
}

list_dir_is_empty_non_dot :: proc(abs_dir: string) -> bool {
	entries, rerr := os.read_all_directory_by_path(abs_dir, context.temp_allocator)
	if rerr != nil {
		return true
	}
	for e in entries {
		if e.name == "." || e.name == ".." {
			continue
		}
		if strings.has_prefix(e.name, ".") {
			continue
		}
		return false
	}
	return true
}

list_dir_build_tree :: proc(
	abs_dir: string,
	rel_prefix: string,
	use_allow: bool,
	allow: ^map[string]bool,
	allocator := context.allocator,
) -> List_Node {
	node: List_Node
	node.name = ""
	node.kind = .Dir
	node.children = make([dynamic]List_Node, 0, 16, allocator)
	node.exts = make([dynamic]string, 0, 8, allocator)
	node.ext_counts = make([dynamic]int, 0, 8, allocator)

	entries, rerr := os.read_all_directory_by_path(abs_dir, context.temp_allocator)
	if rerr != nil {
		return node
	}

	for e in entries {
		name := e.name
		if name == "." || name == ".." {
			continue
		}
		if strings.has_prefix(name, ".") {
			continue
		}

		child_rel: string
		if rel_prefix == "" {
			child_rel = name
		} else {
			child_rel = fmt.tprintf("%s/%s", rel_prefix, name)
		}
		child_rel, _ = strings.replace_all(child_rel, "\\", "/", context.temp_allocator)

		is_dir := e.type == .Directory
		child_abs, _ := filepath.join({abs_dir, name}, context.temp_allocator)

		if is_dir {
			// Fully gitignored trees: skip (would appear empty after filtering).
			// Truly empty non-dot dirs are still listed.
			if use_allow && !dir_has_allowed_descendant(child_rel, allow) {
				if !list_dir_is_empty_non_dot(child_abs) {
					continue
				}
			}
			sub := list_dir_build_tree(child_abs, child_rel, use_allow, allow, allocator)
			sub.name = fmt.tprintf("%s/", name)
			sub.kind = .Dir
			// roll up subtree file stats
			node.file_count += sub.file_count
			for i in 0 ..< len(sub.exts) {
				list_dir_add_ext(&node, sub.exts[i], sub.ext_counts[i], allocator)
			}
			append(&node.children, sub)
		} else {
			if use_allow && !allow[child_rel] {
				continue
			}
			ext := file_ext_key(name)
			leaf: List_Node
			leaf.name = strings.clone(name, allocator)
			leaf.kind = .File
			node.file_count += 1
			list_dir_add_ext(&node, ext, 1, allocator)
			append(&node.children, leaf)
		}
	}
	return node
}

dir_has_allowed_descendant :: proc(rel: string, allow: ^map[string]bool) -> bool {
	prefix := fmt.tprintf("%s/", rel)
	for k in allow {
		if strings.has_prefix(k, prefix) {
			return true
		}
	}
	return false
}

list_dir_add_ext :: proc(node: ^List_Node, ext: string, n: int, allocator := context.allocator) {
	for i in 0 ..< len(node.exts) {
		if node.exts[i] == ext {
			node.ext_counts[i] += n
			return
		}
	}
	append(&node.exts, strings.clone(ext, allocator))
	append(&node.ext_counts, n)
}

file_ext_key :: proc(name: string) -> string {
	ext := filepath.ext(name)
	if len(ext) > 1 && ext[0] == '.' {
		return strings.to_lower(ext[1:], context.temp_allocator)
	}
	return "no-ext"
}

list_dir_sort_tree :: proc(node: ^List_Node) {
	if len(node.children) > 1 {
		slice.sort_by(node.children[:], proc(a, b: List_Node) -> bool {
			return strings.to_lower(a.name, context.temp_allocator) <
				strings.to_lower(b.name, context.temp_allocator)
		})
	}
	for i in 0 ..< len(node.children) {
		if node.children[i].kind == .Dir {
			list_dir_sort_tree(&node.children[i])
		}
	}
}

list_dir_render :: proc(
	display_root: string,
	root: ^List_Node,
	max_chars: int,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "- %s/\n", display_root)

	budget := max_chars - strings.builder_len(b)
	if budget < 64 {
		budget = 64
	}
	truncated := list_dir_render_children(&b, root, 1, &budget, true)
	if truncated {
		strings.write_string(
			&b,
			"\nNote: this directory is too large to list fully. Try list_dir on a narrower path, or use grep / glob.\n",
		)
	}
	return strings.to_string(b)
}

list_dir_render_children :: proc(
	b: ^strings.Builder,
	node: ^List_Node,
	depth: int,
	budget: ^int,
	expand: bool,
) -> (truncated: bool) {
	indent, _ := strings.repeat("  ", depth, context.temp_allocator)
	truncated = false

	for i in 0 ..< len(node.children) {
		child := &node.children[i]
		line: string
		if child.kind == .File {
			line = fmt.tprintf("%s- %s\n", indent, child.name)
		} else {
			line = fmt.tprintf("%s- %s\n", indent, child.name)
		}
		if len(line) > budget^ {
			truncated = true
			// remaining siblings not shown
			return true
		}
		strings.write_string(b, line)
		budget^ -= len(line)

		if child.kind == .Dir {
			// Expand if budget remains and not a fat leaf at deep level
			should_expand := expand && budget^ > 200
			// Fat directories at depth >= 1: prefer summary when many files
			if should_expand &&
			   child.file_count >= LIST_DIR_FAT_DIR_THRESHOLD &&
			   depth >= 1 {
				// summarize instead of full expand
				sum := list_dir_summary_line(indent, child, LIST_DIR_TOP_K_EXTS)
				if len(sum) <= budget^ {
					strings.write_string(b, sum)
					budget^ -= len(sum)
				} else {
					truncated = true
				}
				continue
			}
			if should_expand && len(child.children) > 0 {
				if list_dir_render_children(b, child, depth + 1, budget, true) {
					truncated = true
					return true
				}
			} else if child.file_count > 0 && !should_expand {
				sum := list_dir_summary_line(indent, child, LIST_DIR_TOP_K_EXTS)
				if len(sum) <= budget^ {
					strings.write_string(b, sum)
					budget^ -= len(sum)
				} else {
					truncated = true
					return true
				}
			}
		}
	}
	return truncated
}

list_dir_summary_line :: proc(parent_indent: string, node: ^List_Node, top_k: int) -> string {
	// parent_indent is for the dir line; summary is one level deeper
	indent := fmt.tprintf("%s  ", parent_indent)
	if node.file_count == 0 {
		return ""
	}
	// sort ext by count desc
	pairs := make([dynamic]List_Ext_Pair, 0, len(node.exts), context.temp_allocator)
	for i in 0 ..< len(node.exts) {
		append(&pairs, List_Ext_Pair{ext = node.exts[i], count = node.ext_counts[i]})
	}
	slice.sort_by(pairs[:], proc(a, b: List_Ext_Pair) -> bool {
		if a.count != b.count {
			return a.count > b.count
		}
		return a.ext < b.ext
	})
	parts := make([dynamic]string, 0, top_k, context.temp_allocator)
	top_sum := 0
	n := min(top_k, len(pairs))
	for i in 0 ..< n {
		top_sum += pairs[i].count
		if pairs[i].ext == "no-ext" {
			append(&parts, fmt.tprintf("%d *no-ext", pairs[i].count))
		} else {
			append(&parts, fmt.tprintf("%d *.%s", pairs[i].count, pairs[i].ext))
		}
	}
	ellipsis := ""
	if top_sum < node.file_count {
		ellipsis = ", ..."
	}
	file_word := "files"
	if node.file_count == 1 {
		file_word = "file"
	}
	joined, _ := strings.join(parts[:], ", ", context.temp_allocator)
	return fmt.tprintf(
		"%s[%d %s in subtree: %s%s]\n",
		indent,
		node.file_count,
		file_word,
		joined,
		ellipsis,
	)
}
