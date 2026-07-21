// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

tool_search_replace :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	file_path := jstr(obj, "file_path")
	if file_path == "" {
		return strings.clone("error: file_path is required", allocator)
	}
	old_string := jstr(obj, "old_string")
	// new_string may be empty
	new_string := jstr(obj, "new_string")
	// Need raw field — jstr returns "" if missing; if key exists with empty, same
	// For new_string empty is valid. If key missing, still "" — OK.
	replace_all := jbool(obj, "replace_all", false)

	abs, inside := resolve_in_workspace(workspace, file_path, context.temp_allocator)
	if !inside {
		return strings.clone("error: writes outside workspace are denied", allocator)
	}

	// Create / overwrite when old_string is empty
	if old_string == "" {
		file_rewind_push_before_mutation(abs, file_path, .Write)
		// Ensure parent dirs
		dir := filepath.dir(abs)
		if dir != "" && dir != "." {
			_ = os.make_directory_all(dir)
		}
		if err := os.write_entire_file(abs, transmute([]byte)new_string); err != nil {
			return fmt.aprintf("error: write failed: %v", err, allocator = allocator)
		}
		return fmt.aprintf("wrote %s (%d bytes)", file_path, len(new_string), allocator = allocator)
	}

	data, err := os.read_entire_file(abs, context.temp_allocator)
	if err != nil {
		return fmt.aprintf("error: cannot read %s: %v", file_path, err, allocator = allocator)
	}
	content := string(data)

	if replace_all {
		if !strings.contains(content, old_string) {
			return strings.clone("error: old_string not found", allocator)
		}
		// count occurrences
		count := 0
		search_from := 0
		for {
			idx := strings.index(content[search_from:], old_string)
			if idx < 0 {
				break
			}
			count += 1
			search_from += idx + len(old_string)
		}
		file_rewind_push_before_mutation(abs, file_path, .Edit)
		new_content, _ := strings.replace_all(content, old_string, new_string, context.temp_allocator)
		if werr := os.write_entire_file(abs, transmute([]byte)new_content); werr != nil {
			return fmt.aprintf("error: write failed: %v", werr, allocator = allocator)
		}
		return fmt.aprintf("replaced %d occurrence(s) in %s", count, file_path, allocator = allocator)
	}

	// Exact unique match first; then flexible unique (newlines / case) — B6.
	idx, mlen, how, ferr := find_old_string_span(content, old_string)
	if ferr != "" {
		return strings.clone(ferr, allocator)
	}
	file_rewind_push_before_mutation(abs, file_path, .Edit)
	new_content := strings.concatenate(
		{content[:idx], new_string, content[idx + mlen:]},
		context.temp_allocator,
	)
	if werr := os.write_entire_file(abs, transmute([]byte)new_content); werr != nil {
		return fmt.aprintf("error: write failed: %v", werr, allocator = allocator)
	}
	if how == "exact" {
		return fmt.aprintf("updated %s", file_path, allocator = allocator)
	}
	return fmt.aprintf("updated %s (%s match)", file_path, how, allocator = allocator)
}

// find_old_string_span locates a unique occurrence of old in content.
// Returns byte index + match length in original content, and match kind.
// On failure, err is a non-empty error: message (not allocated).
find_old_string_span :: proc(
	content: string,
	old_string: string,
) -> (
	idx: int,
	mlen: int,
	how: string,
	err: string,
) {
	// 1) exact
	i := strings.index(content, old_string)
	if i >= 0 {
		rest := content[i + len(old_string):]
		if strings.contains(rest, old_string) {
			return 0, 0, "", "error: old_string is not unique; set replace_all=true or provide more context"
		}
		return i, len(old_string), "exact", ""
	}

	// 2) newline-normalized exact (CRLF/CR → LF) unique, map back to original span
	c_nl := normalize_newlines(content, context.temp_allocator)
	o_nl := normalize_newlines(old_string, context.temp_allocator)
	if o_nl != old_string || c_nl != content {
		i2 := strings.index(c_nl, o_nl)
		if i2 >= 0 {
			rest := c_nl[i2 + len(o_nl):]
			if !strings.contains(rest, o_nl) {
				// Map LF indices to original byte range
				oi, ol, okm := map_nl_span_to_original(content, i2, len(o_nl))
				if okm {
					return oi, ol, "newline-normalized", ""
				}
			} else {
				return 0, 0, "", "error: old_string is not unique (after newline normalize); set replace_all=true or provide more context"
			}
		}
	}

	// 3) case-insensitive unique (ASCII), same length span
	i3, ok3 := find_unique_ascii_ci(content, old_string)
	if ok3 {
		return i3, len(old_string), "case-insensitive", ""
	}
	// distinguish not found vs not unique for CI
	if count_ascii_ci(content, old_string) > 1 {
		return 0, 0, "", "error: old_string is not unique (case-insensitive); set replace_all=true or provide more context"
	}

	// 4) whitespace-collapsed unique (runs of space/tab/newline → single space)
	c_ws, c_map := collapse_ws_with_map(content, context.temp_allocator)
	o_ws, _ := collapse_ws_with_map(old_string, context.temp_allocator)
	if o_ws != "" && (o_ws != old_string || c_ws != content) {
		i4 := strings.index(c_ws, o_ws)
		if i4 >= 0 {
			rest := c_ws[i4 + len(o_ws):]
			if strings.contains(rest, o_ws) {
				return 0, 0, "", "error: old_string is not unique (whitespace-collapsed); set replace_all=true or provide more context"
			}
			oi, ol, okm := map_collapsed_span_to_original(c_map, len(content), i4, len(o_ws))
			if okm {
				return oi, ol, "whitespace-collapsed", ""
			}
		}
	}

	return 0, 0, "", "error: old_string not found (tried exact, newline-normalized, case-insensitive, whitespace-collapsed)"
}

@(private)
normalize_newlines :: proc(s: string, allocator := context.allocator) -> string {
	if !strings.contains(s, "\r") {
		return s
	}
	b := strings.builder_make_len_cap(0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\r' {
			if i + 1 < len(s) && s[i + 1] == '\n' {
				i += 1
			}
			strings.write_byte(&b, '\n')
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// map_nl_span_to_original: LF-normalized index/len → original content [start,end).
@(private)
map_nl_span_to_original :: proc(
	original: string,
	nl_idx: int,
	nl_len: int,
) -> (
	start: int,
	length: int,
	ok: bool,
) {
	// Walk original counting LF-normalized positions
	nli := 0
	start = -1
	for i := 0; i < len(original); i += 1 {
		if nli == nl_idx && start < 0 {
			start = i
		}
		if start >= 0 && nli == nl_idx + nl_len {
			return start, i - start, true
		}
		if original[i] == '\r' {
			if i + 1 < len(original) && original[i + 1] == '\n' {
				i += 1
			}
			nli += 1
		} else {
			nli += 1
		}
	}
	if start >= 0 && nli == nl_idx + nl_len {
		return start, len(original) - start, true
	}
	return 0, 0, false
}

@(private)
ascii_lower :: proc(b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

@(private)
find_unique_ascii_ci :: proc(content: string, old: string) -> (idx: int, ok: bool) {
	if old == "" || len(old) > len(content) {
		return 0, false
	}
	found := -1
	for i := 0; i + len(old) <= len(content); i += 1 {
		match := true
		for j := 0; j < len(old); j += 1 {
			if ascii_lower(content[i + j]) != ascii_lower(old[j]) {
				match = false
				break
			}
		}
		if match {
			if found >= 0 {
				return 0, false // not unique
			}
			found = i
		}
	}
	if found < 0 {
		return 0, false
	}
	return found, true
}

@(private)
count_ascii_ci :: proc(content: string, old: string) -> int {
	if old == "" || len(old) > len(content) {
		return 0
	}
	n := 0
	for i := 0; i + len(old) <= len(content); i += 1 {
		match := true
		for j := 0; j < len(old); j += 1 {
			if ascii_lower(content[i + j]) != ascii_lower(old[j]) {
				match = false
				break
			}
		}
		if match {
			n += 1
		}
	}
	return n
}

@(private)
is_ws_byte :: proc(b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

// collapse_ws_with_map: runs of whitespace → single space; map[i] = original index of norm[i].
@(private)
collapse_ws_with_map :: proc(
	s: string,
	allocator := context.allocator,
) -> (
	norm: string,
	orig_map: []int,
) {
	if s == "" {
		return "", nil
	}
	b := strings.builder_make_len_cap(0, len(s), allocator)
	mp := make([dynamic]int, 0, len(s), allocator)
	in_ws := false
	for i := 0; i < len(s); i += 1 {
		if is_ws_byte(s[i]) {
			if !in_ws {
				strings.write_byte(&b, ' ')
				append(&mp, i)
				in_ws = true
			}
		} else {
			strings.write_byte(&b, s[i])
			append(&mp, i)
			in_ws = false
		}
	}
	// trim leading/trailing single spaces from collapsed form for stabler matches
	n := strings.to_string(b)
	start := 0
	end := len(n)
	if end > 0 && n[0] == ' ' {
		start = 1
	}
	if end > start && n[end - 1] == ' ' {
		end -= 1
	}
	if start == 0 && end == len(n) {
		return n, mp[:]
	}
	if start >= end {
		return "", nil
	}
	sub := n[start:end]
	sub_map := make([]int, end - start, allocator)
	for j := 0; j < len(sub_map); j += 1 {
		sub_map[j] = mp[start + j]
	}
	return sub, sub_map
}

// map_collapsed_span_to_original maps [ci, ci+cl) in collapsed space to original bytes.
// orig_map[i] = original index of collapsed char i. End exclusive is next map entry
// (covers full collapsed whitespace runs) or last+1 at EOF.
@(private)
map_collapsed_span_to_original :: proc(
	orig_map: []int,
	orig_len: int,
	ci: int,
	cl: int,
) -> (
	start: int,
	length: int,
	ok: bool,
) {
	if cl <= 0 || ci < 0 || ci + cl > len(orig_map) {
		return 0, 0, false
	}
	start = orig_map[ci]
	end: int
	if ci + cl < len(orig_map) {
		// Next collapsed char's original index — includes any ws run represented by one space
		end = orig_map[ci + cl]
	} else {
		end = orig_map[ci + cl - 1] + 1
		if end > orig_len {
			end = orig_len
		}
	}
	if end <= start || start < 0 || end > orig_len {
		return 0, 0, false
	}
	return start, end - start, true
}
