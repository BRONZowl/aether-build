// Package tui — @path / path Tab autocomplete (B22 / Grok-shaped @-mentions).
// Minimal: directory listing + prefix match (no full fuzzy/rg). Opt out: none
// (only runs when Tab hits a path-like token).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tui

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

PATH_COMPLETE_MAX :: 40

// Path_Token describes a completable path fragment at the cursor.
Path_Token :: struct {
	start:     int, // byte index of token start (includes @ if present)
	end:       int, // cursor end
	is_at:     bool, // @-mention
	// path_part: text after optional @ (and optional leading ./)
	path_part: string, // slice of input (not owned)
}

// detect_path_token: @query (not email) or path-like token containing / or ./
detect_path_token :: proc(text: string, cursor: int) -> (tok: Path_Token, ok: bool) {
	cur := cursor
	if cur < 0 {
		cur = 0
	}
	if cur > len(text) {
		cur = len(text)
	}
	// find line start
	line_start := 0
	for i in 0 ..< cur {
		if text[i] == '\n' {
			line_start = i + 1
		}
	}
	// walk back over token chars (path-ish)
	// Token charset: alnum _ . / - + ~ and @ only at start
	i := cur
	for i > line_start {
		ch := text[i - 1]
		if ch == ' ' || ch == '\t' || ch == ',' || ch == ';' || ch == '"' || ch == '\'' {
			break
		}
		i -= 1
	}
	if i >= cur {
		return {}, false
	}
	frag := text[i:cur]
	// @-mention: starts with @, and @ not after alnum/_
	if frag[0] == '@' {
		if i > line_start {
			prev := text[i - 1]
			if (prev >= 'a' && prev <= 'z') ||
			   (prev >= 'A' && prev <= 'Z') ||
			   (prev >= '0' && prev <= '9') ||
			   prev == '_' {
				return {}, false // email-ish
			}
		}
		// no spaces inside (already guaranteed by walk)
		tok = Path_Token {
			start     = i,
			end       = cur,
			is_at     = true,
			path_part = frag[1:],
		}
		return tok, true
	}
	// bare path: must look path-like (has / or starts with . or ~)
	if strings.contains(frag, "/") ||
	   strings.has_prefix(frag, "./") ||
	   strings.has_prefix(frag, "../") ||
	   strings.has_prefix(frag, "~/") ||
	   frag == "." ||
	   frag == ".." {
		tok = Path_Token {
			start     = i,
			end       = cur,
			is_at     = false,
			path_part = frag,
		}
		return tok, true
	}
	return {}, false
}

// split_dir_base: "src/foo" → ("src", "foo"); "src/" → ("src", ""); "foo" → ("", "foo")
split_dir_base :: proc(path_part: string) -> (dir, base: string) {
	p := path_part
	// strip leading ~/ for listing under home later handled by resolve
	if p == "" {
		return "", ""
	}
	// dir mode if ends with /
	if strings.has_suffix(p, "/") {
		d := p[:len(p) - 1]
		return d, ""
	}
	if slash := strings.last_index_byte(p, '/'); slash >= 0 {
		return p[:slash], p[slash + 1:]
	}
	return "", p
}

// resolve_list_dir: absolute directory to list for path_part's dir component.
resolve_list_dir :: proc(
	cwd: string,
	dir_rel: string,
	allocator := context.allocator,
) -> string {
	ws := cwd if cwd != "" else "."
	if dir_rel == "" {
		return strings.clone(ws, allocator)
	}
	// ~/
	if strings.has_prefix(dir_rel, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			rest := dir_rel[2:]
			if rest == "" {
				return strings.clone(home, allocator)
			}
			joined, _ := filepath.join({home, rest}, allocator)
			return joined
		}
	}
	if os.is_absolute_path(dir_rel) {
		return strings.clone(dir_rel, allocator)
	}
	joined, _ := filepath.join({ws, dir_rel}, allocator)
	return joined
}

// collect_path_matches lists entries under dir matching base prefix.
// Returns display names (with trailing / for dirs) allocated into out (temp ok).
// skip_dot: hide .hidden unless base starts with .
collect_path_matches :: proc(
	list_dir: string,
	base_prefix: string,
	out: ^[dynamic]string,
	allocator := context.allocator,
) {
	clear(out)
	if list_dir == "" || !os.exists(list_dir) || !os.is_directory(list_dir) {
		return
	}
	fis, err := os.read_all_directory_by_path(list_dir, context.temp_allocator)
	if err != nil {
		return
	}
	show_dot := strings.has_prefix(base_prefix, ".")
	cands := make([dynamic]string, 0, 32, context.temp_allocator)
	for fi in fis {
		name := fi.name
		if name == "." || name == ".." {
			continue
		}
		if !show_dot && strings.has_prefix(name, ".") {
			continue
		}
		if base_prefix != "" && !strings.has_prefix(name, base_prefix) {
			continue
		}
		// mark dirs
		disp := name
		if fi.type == .Directory {
			disp = fmt.tprintf("%s/", name)
		}
		append(&cands, disp)
	}
	// sort for stable cycle
	slice.sort_by(cands[:], proc(a, b: string) -> bool {
		return a < b
	})
	n := len(cands)
	if n > PATH_COMPLETE_MAX {
		n = PATH_COMPLETE_MAX
	}
	for i in 0 ..< n {
		append(out, strings.clone(cands[i], allocator))
	}
}

// collect_workspace_path_matches: B24 — rg --files under cwd, filter by query.
// Prefer basename prefix, then path contains (case-insensitive). Relative paths.
// Falls back silently if rg missing (caller may use dir listing).
collect_workspace_path_matches :: proc(
	cwd: string,
	query: string,
	out: ^[dynamic]string,
	allocator := context.allocator,
) -> bool {
	clear(out)
	ws := cwd if cwd != "" else "."
	if !os.exists(ws) || !os.is_directory(ws) {
		return false
	}
	q := strings.trim_space(query)
	q_l := strings.to_lower(q, context.temp_allocator)

	args := make([dynamic]string, 0, 10, context.temp_allocator)
	append(&args, "rg")
	append(&args, "--files")
	append(&args, "--hidden")
	append(&args, "--glob", "!.git/*")
	append(&args, "--glob", "!**/node_modules/**")
	append(&args, "--glob", "!**/target/**")
	// limit scan somewhat via path
	append(&args, "--", ws)

	state, stdout, _, err := os.process_exec(
		{command = args[:], working_dir = ws},
		context.temp_allocator,
	)
	if err != nil {
		return false
	}
	if state.exit_code > 1 {
		return false
	}
	out_s := string(stdout)
	if len(out_s) > 2_000_000 {
		out_s = out_s[:2_000_000]
	}

	// abs prefix for stripping to relative
	abs_ws, aerr := filepath.abs(ws, context.temp_allocator)
	if aerr != nil {
		abs_ws = ws
	}
	// normalize trailing slash for strip
	prefix := abs_ws
	if !strings.has_suffix(prefix, "/") {
		prefix = fmt.tprintf("%s/", abs_ws)
	}

	prefix_hits := make([dynamic]string, 0, 32, context.temp_allocator)
	contain_hits := make([dynamic]string, 0, 32, context.temp_allocator)

	for line in strings.split_lines(out_s, context.temp_allocator) {
		p := strings.trim_space(line)
		if p == "" {
			continue
		}
		// to relative
		rel := p
		if strings.has_prefix(p, prefix) {
			rel = p[len(prefix):]
		} else if strings.has_prefix(p, abs_ws) && len(p) > len(abs_ws) && p[len(abs_ws)] == '/' {
			rel = p[len(abs_ws) + 1:]
		}
		// skip empty
		if rel == "" {
			continue
		}
		base := filepath.base(rel)
		base_l := strings.to_lower(base, context.temp_allocator)
		rel_l := strings.to_lower(rel, context.temp_allocator)
		if q == "" {
			append(&prefix_hits, rel)
			if len(prefix_hits) >= PATH_COMPLETE_MAX {
				break
			}
			continue
		}
		if strings.has_prefix(base_l, q_l) || strings.has_prefix(rel_l, q_l) {
			append(&prefix_hits, rel)
		} else if strings.contains(base_l, q_l) || strings.contains(rel_l, q_l) {
			append(&contain_hits, rel)
		}
	}

	// sort each bucket
	slice.sort_by(prefix_hits[:], proc(a, b: string) -> bool {return a < b})
	slice.sort_by(contain_hits[:], proc(a, b: string) -> bool {return a < b})

	// merge: prefix first
	for r in prefix_hits {
		if len(out) >= PATH_COMPLETE_MAX {
			break
		}
		append(out, strings.clone(r, allocator))
	}
	for r in contain_hits {
		if len(out) >= PATH_COMPLETE_MAX {
			break
		}
		// dedupe
		dup := false
		for e in out {
			if e == r {
				dup = true
				break
			}
		}
		if !dup {
			append(out, strings.clone(r, allocator))
		}
	}
	return len(out) > 0 || err == nil // rg ran ok even if zero matches
}

// build_completion_insert: reconstruct token text for a chosen entry name.
// dir_rel is path_part's dir without trailing slash; entry is "file" or "dir/".
build_completion_insert :: proc(
	is_at: bool,
	dir_rel: string,
	entry: string,
	allocator := context.allocator,
) -> string {
	path: string
	if dir_rel == "" {
		path = entry
	} else {
		path = fmt.tprintf("%s/%s", dir_rel, entry)
	}
	if is_at {
		return fmt.aprintf("@%s", path, allocator = allocator)
	}
	return strings.clone(path, allocator)
}

// common_path_prefix: LCP of match display entries only (basename part).
common_path_prefix :: proc(matches: []string) -> string {
	if len(matches) == 0 {
		return ""
	}
	if len(matches) == 1 {
		return matches[0]
	}
	base := matches[0]
	n := len(base)
	for m in matches[1:] {
		i := 0
		for i < n && i < len(m) && base[i] == m[i] {
			i += 1
		}
		n = i
		if n == 0 {
			return ""
		}
	}
	return base[:n]
}

// apply_path_token_replace replaces text[start:end] with insert; sets cursor.
apply_path_token_replace :: proc(s: ^App_State, start, end: int, insert: string) -> bool {
	text := input_text(s)
	if start < 0 || end < start || end > len(text) {
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, text[:start])
	strings.write_string(&b, insert)
	strings.write_string(&b, text[end:])
	new_text := strings.to_string(b)
	input_set_text(s, new_text)
	s.cursor = start + len(insert)
	return true
}

// free_path_match_list frees owned match strings from collect_path_matches when using context.allocator
free_string_list :: proc(list: []string) {
	for s in list {
		delete(s)
	}
	delete(list)
}

// try_path_tab_complete: Tab handler for @path / path tokens. cwd is workspace.
// Reuses slash_comp_* cycle fields with "path:" prefix tag in slash_comp_prefix.
try_path_tab_complete :: proc(s: ^App_State, cwd: string) -> bool {
	if s == nil || s.focus != .Prompt {
		return false
	}
	text := input_text(s)
	tok, ok := detect_path_token(text, s.cursor)
	if !ok {
		return false
	}

	dir_rel, base := split_dir_base(tok.path_part)
	// B24: no dir component → workspace-wide rg --files; else list that directory
	workspace_mode := dir_rel == ""
	matches := make([dynamic]string, 0, 16, context.allocator)
	defer {
		for m in matches {
			delete(m)
		}
		delete(matches)
	}
	if workspace_mode {
		_ = collect_workspace_path_matches(cwd, base, &matches, context.allocator)
		if len(matches) == 0 {
			// fallback: cwd listing only
			list_dir := resolve_list_dir(cwd, "", context.temp_allocator)
			collect_path_matches(list_dir, base, &matches, context.allocator)
		}
	} else {
		list_dir := resolve_list_dir(cwd, dir_rel, context.temp_allocator)
		collect_path_matches(list_dir, base, &matches, context.allocator)
	}
	if len(matches) == 0 {
		state_set_status(s, fmt.tprintf("no path match for %s", tok.path_part if tok.path_part != "" else "@"))
		return true
	}

	// For workspace hits, entry is full relative path → insert with empty dir_rel
	ins_dir := "" if workspace_mode else dir_rel

	// cycle key includes mode + path_part
	key := fmt.tprintf("path:%s", text[tok.start:tok.end])
	if s.slash_comp_prefix != key {
		if s.slash_comp_prefix != "" {
			delete(s.slash_comp_prefix)
		}
		s.slash_comp_prefix = strings.clone(key)
		s.slash_comp_idx = 0
		// expand LCP if longer than typed base/query
		lcp := common_path_prefix(matches[:])
		// workspace: lcp is full path; dir mode: lcp is basename
		typed_len := len(base)
		if workspace_mode {
			typed_len = len(tok.path_part)
		}
		if len(lcp) > typed_len {
			ins := build_completion_insert(tok.is_at, ins_dir, lcp, context.temp_allocator)
			_ = apply_path_token_replace(s, tok.start, tok.end, ins)
			// refresh key after expansion
			delete(s.slash_comp_prefix)
			text2 := input_text(s)
			tok2, ok2 := detect_path_token(text2, s.cursor)
			if ok2 {
				s.slash_comp_prefix = strings.clone(fmt.tprintf("path:%s", text2[tok2.start:tok2.end]))
			} else {
				s.slash_comp_prefix = strings.clone(key)
			}
			if len(matches) == 1 {
				unique := matches[0]
				add_sp := !strings.has_suffix(unique, "/")
				ins2 := build_completion_insert(tok.is_at, ins_dir, unique, context.temp_allocator)
				if add_sp {
					ins2 = fmt.tprintf("%s ", ins2)
				}
				text3 := input_text(s)
				tok3, ok3 := detect_path_token(text3, s.cursor)
				if ok3 {
					_ = apply_path_token_replace(s, tok3.start, tok3.end, ins2)
				}
				state_set_status(s, unique)
			} else {
				state_set_status(
					s,
					fmt.tprintf("%d paths · Tab cycle · %s…", len(matches), lcp),
				)
			}
			return true
		}
	}

	// cycle
	idx := s.slash_comp_idx % len(matches)
	chosen := matches[idx]
	s.slash_comp_idx = (idx + 1) % len(matches)
	add_sp := !strings.has_suffix(chosen, "/")
	ins := build_completion_insert(tok.is_at, ins_dir, chosen, context.temp_allocator)
	if add_sp {
		full := fmt.tprintf("%s ", ins)
		_ = apply_path_token_replace(s, tok.start, tok.end, full)
	} else {
		_ = apply_path_token_replace(s, tok.start, tok.end, ins)
	}
	state_set_status(s, fmt.tprintf("%s  (%d/%d)", chosen, idx + 1, len(matches)))
	return true
}
