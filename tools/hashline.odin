// Package tools — hashline pack (M5): content-only line anchors.
// Scheme: LINE:HASH where HASH is 3-char base36 FNV of whitespace-collapsed line.
// Tools: hashline_read, hashline_edit, hashline_grep.
// Reference: grok_build_hashline (content_only_v1 simplified).
package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

HASH_LEN :: 3
HASH_ALPHABET :: "abcdefghijklmnopqrstuvwxyz0123456789"

// normalize_line: collapse whitespace for hashing (Grok content-only style).
normalize_line :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	space := false
	started := false
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\r' {
			if started {
				space = true
			}
			continue
		}
		if space {
			strings.write_byte(&b, ' ')
			space = false
		}
		strings.write_byte(&b, c)
		started = true
	}
	return strings.to_string(b)
}

// line_hash_fnv: short base36 hash of normalized line (cloned; safe after return).
line_hash_fnv :: proc(line: string, allocator := context.temp_allocator) -> string {
	norm := normalize_line(line, context.temp_allocator)
	h: u32 = 2166136261
	for i in 0 ..< len(norm) {
		h ~= u32(norm[i])
		h *= 16777619
	}
	// map to HASH_LEN chars from alphabet (index via local so const string is addressable)
	alpha := HASH_ALPHABET
	out: [HASH_LEN]u8
	for i in 0 ..< HASH_LEN {
		out[i] = alpha[h % 36]
		h /= 36
	}
	return strings.clone(string(out[:]), allocator)
}

// format_hashline_line: "N:hash→content"
format_hashline_line :: proc(line_no: int, content: string, allocator := context.allocator) -> string {
	h := line_hash_fnv(content)
	return fmt.aprintf("%d:%s→%s", line_no, h, content, allocator = allocator)
}

// parse_anchor: "12:abc" or "12:abc:def" or "0:" or "EOF" → line (1-based; 0=BOF, -1=EOF)
parse_anchor :: proc(anchor: string) -> (line: int, local_hash: string, ok: bool) {
	a := strings.trim_space(anchor)
	if a == "" {
		return 0, "", false
	}
	if strings.equal_fold(a, "EOF") {
		return -1, "", true
	}
	if a == "0:" || a == "0" {
		return 0, "", true
	}
	// LINE:HASH or LINE:HASH:CTX
	colon := strings.index_byte(a, ':')
	if colon < 0 {
		// bare line number?
		n, nok := strconv.parse_int(a)
		if nok && n > 0 {
			return n, "", true
		}
		return 0, "", false
	}
	n, nok := strconv.parse_int(a[:colon])
	if !nok || n < 0 {
		return 0, "", false
	}
	rest := a[colon + 1 :]
	// take until next colon for local hash
	c2 := strings.index_byte(rest, ':')
	hash := rest
	if c2 >= 0 {
		hash = rest[:c2]
	}
	return n, hash, true
}

// validate_anchor against lines (1-based content array; lines[0] unused or line 1 at index 0)
// lines is 0-based slice of file lines without newlines.
validate_anchor :: proc(lines: []string, line_1: int, want_hash: string) -> string /* err */ {
	if line_1 == 0 || line_1 == -1 {
		return "" // BOF/EOF specials always ok for insert
	}
	if line_1 < 1 || line_1 > len(lines) {
		return fmt.tprintf("anchor line %d out of range (file has %d lines)", line_1, len(lines))
	}
	if want_hash == "" {
		return "" // line-only anchor
	}
	got := line_hash_fnv(lines[line_1 - 1])
	if got != want_hash {
		return fmt.tprintf(
			"stale anchor at line %d: expected hash %s, current %s→%s",
			line_1,
			want_hash,
			got,
			truncate_hl(lines[line_1 - 1], 80),
		)
	}
	return ""
}

truncate_hl :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	return fmt.tprintf("%s…", s[:n])
}

split_lines_keep :: proc(content: string, allocator := context.allocator) -> []string {
	// split on \n; preserve empty last if ends with newline? drop trailing empty after final \n
	parts := strings.split_lines(content, allocator)
	// strings.split_lines may leave trailing empty
	if len(parts) > 0 && parts[len(parts) - 1] == "" {
		// keep for empty files; if content ends with \n, last is empty — drop for hashline
		if len(content) > 0 && content[len(content) - 1] == '\n' {
			return parts[:len(parts) - 1]
		}
	}
	return parts
}

join_lines :: proc(lines: []string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, line)
	}
	if len(lines) > 0 {
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// --- tools ---

tool_hashline_read :: proc(
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
		file_path = jstr(obj, "target_file")
	}
	if file_path == "" {
		return strings.clone("error: file_path is required", allocator)
	}
	offset := jint(obj, "offset", 1)
	limit := jint(obj, "limit", DEFAULT_READ_LIMIT)
	if limit <= 0 {
		limit = DEFAULT_READ_LIMIT
	}

	abs, inside := resolve_in_workspace(workspace, file_path, context.temp_allocator)
	if !inside {
		return strings.clone("error: path outside workspace", allocator)
	}
	data, err := os.read_entire_file(abs, context.temp_allocator)
	if err != nil {
		return fmt.aprintf("error: cannot read %s: %v", file_path, err, allocator = allocator)
	}
	lines := split_lines_keep(string(data), context.temp_allocator)
	// offset 1-based
	start := offset
	if start < 1 {
		start = 1
	}
	if start > len(lines) + 1 {
		return fmt.aprintf("error: offset %d past end (%d lines)", offset, len(lines), allocator = allocator)
	}
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "hashline_read %s  scheme=content_only_v1  lines=%d\n", file_path, len(lines))
	n := 0
	for i := start; i <= len(lines) && n < limit; i += 1 {
		fmt.sbprintf(&b, "%s\n", format_hashline_line(i, lines[i - 1], context.temp_allocator))
		n += 1
	}
	if start + n - 1 < len(lines) {
		fmt.sbprintf(&b, "… (%d more lines; use offset/limit)\n", len(lines) - (start + n - 1))
	}
	return strings.to_string(b)
}

tool_hashline_grep :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	pattern := jstr(obj, "pattern")
	if pattern == "" {
		return strings.clone("error: pattern is required", allocator)
	}
	path := jstr(obj, "path")
	if path == "" {
		path = "."
	}
	// Reuse grep then reformat? Simpler: run tool_grep then leave; better reformat file matches.
	// For MVP: call tool_grep and prefix note
	raw := tool_grep(arguments_json, workspace, context.temp_allocator)
	if strings.has_prefix(raw, "error:") {
		return strings.clone(raw, allocator)
	}
	// Enrich: for each path:line: prefix with hash if we can read
	// Keep grep output and add header
	return fmt.aprintf(
		"hashline_grep (scheme=content_only_v1) — use anchors from hashline_read for edits\n%s",
		raw,
		allocator = allocator,
	)
}

tool_hashline_edit :: proc(
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
	abs, inside := resolve_in_workspace(workspace, file_path, context.temp_allocator)
	if !inside {
		return strings.clone("error: writes outside workspace are denied", allocator)
	}

	// Simple single-edit form: op, anchor, content [, end_anchor]
	// Or full write: op=write content=...
	op := strings.to_lower(jstr(obj, "op"), context.temp_allocator)
	if op == "" {
		// if content only and no anchor → write?
		if jstr(obj, "anchor") == "" && jstr(obj, "content") != "" {
			op = "write"
		} else {
			op = "replace"
		}
	}
	content := jstr(obj, "content") // may be empty
	anchor := jstr(obj, "anchor")
	end_anchor := jstr(obj, "end_anchor")

	if op == "write" {
		file_rewind_push_before_mutation(abs, file_path, .Write)
		dir := filepath.dir(abs)
		if dir != "" && dir != "." {
			_ = os.make_directory_all(dir)
		}
		if werr := os.write_entire_file(abs, transmute([]byte)content); werr != nil {
			return fmt.aprintf("error: write failed: %v", werr, allocator = allocator)
		}
		lines := split_lines_keep(content, context.temp_allocator)
		return fmt.aprintf(
			"hashline_edit write ok  %s  (%d lines)\n%s",
			file_path,
			len(lines),
			snippet_hashlines(lines, 1, min(20, len(lines)), context.temp_allocator),
			allocator = allocator,
		)
	}

	data, err := os.read_entire_file(abs, context.temp_allocator)
	if err != nil {
		// create if replace with empty file?
		if os.exists(abs) {
			return fmt.aprintf("error: cannot read %s: %v", file_path, err, allocator = allocator)
		}
		data = {}
	}
	lines_dyn := make([dynamic]string, 0, 64, context.temp_allocator)
	{
		ls := split_lines_keep(string(data), context.temp_allocator)
		for l in ls {
			append(&lines_dyn, l)
		}
	}

	line_1, hash, aok := parse_anchor(anchor)
	if !aok {
		return fmt.aprintf("error: invalid anchor %q", anchor, allocator = allocator)
	}
	if verr := validate_anchor(lines_dyn[:], line_1, hash); verr != "" {
		// show fresh anchors around target
		fresh := snippet_hashlines(lines_dyn[:], max(1, line_1 - 2), min(len(lines_dyn), line_1 + 2), context.temp_allocator)
		return fmt.aprintf("error: %s\nfresh anchors:\n%s", verr, fresh, allocator = allocator)
	}

	new_lines := make([dynamic]string, 0, len(lines_dyn) + 8, context.temp_allocator)
	content_lines := split_lines_keep(content, context.temp_allocator)
	// if content has no trailing newline intent, split_lines_keep is fine

	switch op {
	case "replace":
		end_1 := line_1
		if end_anchor != "" {
			el, eh, eok := parse_anchor(end_anchor)
			if !eok {
				return fmt.aprintf("error: invalid end_anchor %q", end_anchor, allocator = allocator)
			}
			if verr := validate_anchor(lines_dyn[:], el, eh); verr != "" {
				return fmt.aprintf("error: end_anchor: %s", verr, allocator = allocator)
			}
			end_1 = el
		}
		if line_1 < 1 {
			return strings.clone("error: replace requires a line anchor (not 0:/EOF alone)", allocator)
		}
		if end_1 < line_1 {
			return strings.clone("error: end_anchor before anchor", allocator)
		}
		// copy before
		for i in 0 ..< line_1 - 1 {
			append(&new_lines, lines_dyn[i])
		}
		for cl in content_lines {
			append(&new_lines, cl)
		}
		for i in end_1 ..< len(lines_dyn) {
			append(&new_lines, lines_dyn[i])
		}
	case "insert_after":
		// 0: = beginning, EOF = end, else after line
		insert_at := 0 // index in 0-based where new content is inserted (before this index)
		if line_1 == 0 {
			insert_at = 0
		} else if line_1 == -1 {
			insert_at = len(lines_dyn)
		} else {
			insert_at = line_1 // after line_1 means index line_1 in 0-based
		}
		for i in 0 ..< insert_at {
			append(&new_lines, lines_dyn[i])
		}
		for cl in content_lines {
			append(&new_lines, cl)
		}
		for i in insert_at ..< len(lines_dyn) {
			append(&new_lines, lines_dyn[i])
		}
	case:
		return fmt.aprintf("error: unknown op %q (replace|insert_after|write)", op, allocator = allocator)
	}

	file_rewind_push_before_mutation(abs, file_path, .Edit)
	out_body := join_lines(new_lines[:], context.temp_allocator)
	if werr := os.write_entire_file(abs, transmute([]byte)out_body); werr != nil {
		return fmt.aprintf("error: write failed: %v", werr, allocator = allocator)
	}
	// snippet around edit
	snip_start := max(1, line_1 - 1)
	if snip_start < 1 {
		snip_start = 1
	}
	return fmt.aprintf(
		"hashline_edit %s ok\n%s",
		op,
		snippet_hashlines(new_lines[:], snip_start, min(len(new_lines), snip_start + 12), context.temp_allocator),
		allocator = allocator,
	)
}

snippet_hashlines :: proc(lines: []string, from_1, to_1: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	f := from_1
	if f < 1 {
		f = 1
	}
	t := to_1
	if t > len(lines) {
		t = len(lines)
	}
	for i := f; i <= t; i += 1 {
		fmt.sbprintf(&b, "%s\n", format_hashline_line(i, lines[i - 1], context.temp_allocator))
	}
	return strings.to_string(b)
}

// Schema fragments for hashline pack
HASHLINE_TOOLS_JSON :: `,` +
	`{"type":"function","function":{"name":"hashline_read","description":"Read a file with hashline anchors (LINE:HASH→content). Use anchors with hashline_edit. Prefer over read_file when hashline pack is active.","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"target_file":{"type":"string"},"offset":{"type":"integer","description":"1-based start line"},"limit":{"type":"integer"}},"required":["file_path"]}}},` +
	`{"type":"function","function":{"name":"hashline_edit","description":"Edit using hashline anchors from hashline_read. ops: replace (anchor[,end_anchor],content), insert_after (anchor,content; 0: BOF, EOF end), write (full content).","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"op":{"type":"string","description":"replace|insert_after|write"},"anchor":{"type":"string","description":"LINE:HASH or 0: or EOF"},"end_anchor":{"type":"string"},"content":{"type":"string"}},"required":["file_path"]}}},` +
	`{"type":"function","function":{"name":"hashline_grep","description":"Search file contents (ripgrep); pair with hashline_read for anchors before editing.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"-i":{"type":"boolean"},"head_limit":{"type":"integer"}},"required":["pattern"]}}}`
