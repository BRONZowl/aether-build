// Global durable prompt history for Up/Down recall (B23 / Grok-shaped).
// File: $GROK_HOME/aether/prompt-history.jsonl — one JSON string per line.
// Opt out: AETHER_NO_PROMPT_HISTORY=1
package core

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

PROMPT_HISTORY_MAX :: 200
PROMPT_HISTORY_MAX_ENTRY :: 8 * 1024

prompt_history_enabled :: proc() -> bool {
	v := os.get_env("AETHER_NO_PROMPT_HISTORY", context.temp_allocator)
	return !(v == "1" || strings.equal_fold(v, "true") || strings.equal_fold(v, "yes") || strings.equal_fold(v, "on"))
}

// prompt_history_path: AETHER_PROMPT_HISTORY_PATH or $GROK_HOME/aether/prompt-history.jsonl.
prompt_history_path :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_PROMPT_HISTORY_PATH", context.temp_allocator); v != "" {
		parent := filepath.dir(v)
		if parent != "" {
			_ = ensure_dir(parent)
		}
		return strings.clone(v, allocator)
	}
	home := grok_home(context.temp_allocator)
	dir, _ := filepath.join({home, "aether"}, context.temp_allocator)
	_ = ensure_dir(dir)
	p, _ := filepath.join({home, "aether", "prompt-history.jsonl"}, allocator)
	return p
}

// load_prompt_history_from reads path (owned strings, oldest-first, capped).
load_prompt_history_from :: proc(path: string, allocator := context.allocator) -> []string {
	if path == "" || !os.exists(path) {
		return nil
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	tmp := make([dynamic]string, 0, 64, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		t := strings.trim_space(line)
		if t == "" {
			continue
		}
		val, perr := json.parse(
			transmute([]byte)t,
			json.DEFAULT_SPECIFICATION,
			false,
			context.temp_allocator,
		)
		if perr != nil {
			if len(t) > PROMPT_HISTORY_MAX_ENTRY {
				t = t[:PROMPT_HISTORY_MAX_ENTRY]
			}
			append(&tmp, t)
			continue
		}
		if s, ok := val.(json.String); ok {
			st := string(s)
			if st == "" {
				continue
			}
			if len(st) > PROMPT_HISTORY_MAX_ENTRY {
				st = st[:PROMPT_HISTORY_MAX_ENTRY]
			}
			append(&tmp, st)
		}
	}
	n := len(tmp)
	start := 0
	if n > PROMPT_HISTORY_MAX {
		start = n - PROMPT_HISTORY_MAX
	}
	count := n - start
	out := make([]string, count, allocator)
	for i in 0 ..< count {
		out[i] = strings.clone(tmp[start + i], allocator)
	}
	return out
}

// load_prompt_history uses configured path (respects opt-out).
load_prompt_history :: proc(allocator := context.allocator) -> []string {
	if !prompt_history_enabled() {
		return nil
	}
	path := prompt_history_path(context.temp_allocator)
	return load_prompt_history_from(path, allocator)
}

destroy_prompt_history_list :: proc(list: []string) {
	for s in list {
		delete(s)
	}
	delete(list)
}

// append_prompt_history_to appends to an explicit path (tests / callers).
// Skips empty / consecutive duplicates. Always rewrites that path only.
append_prompt_history_to :: proc(path, prompt: string) -> string {
	if path == "" {
		return "empty path"
	}
	p := strings.trim_space(prompt)
	if p == "" {
		return ""
	}
	if len(p) > PROMPT_HISTORY_MAX_ENTRY {
		p = p[:PROMPT_HISTORY_MAX_ENTRY]
	}
	existing := load_prompt_history_from(path, context.allocator)
	defer destroy_prompt_history_list(existing)
	if len(existing) > 0 && existing[len(existing) - 1] == p {
		return "" // consecutive dup
	}
	list := make([dynamic]string, 0, PROMPT_HISTORY_MAX + 1, context.temp_allocator)
	for e in existing {
		append(&list, e)
	}
	append(&list, p)
	start := 0
	if len(list) > PROMPT_HISTORY_MAX {
		start = len(list) - PROMPT_HISTORY_MAX
	}
	// ensure parent dir
	parent := filepath.dir(path)
	if parent != "" {
		_ = ensure_dir(parent)
	}
	return write_prompt_history_lines(path, list[start:])
}

// append_prompt_history uses configured path (respects opt-out).
append_prompt_history :: proc(prompt: string) -> string {
	if !prompt_history_enabled() {
		return ""
	}
	path := prompt_history_path(context.temp_allocator)
	return append_prompt_history_to(path, prompt)
}

// json_quote_string: minimal JSON string encode.
json_quote_string :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"', '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, ch)
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

write_prompt_history_lines :: proc(path: string, lines: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for p in lines {
		enc := json_quote_string(p, context.temp_allocator)
		strings.write_string(&b, enc)
		strings.write_byte(&b, '\n')
	}
	body := strings.to_string(b)
	if werr := os.write_entire_file(path, transmute([]byte)body); werr != nil {
		return fmt.tprintf("write failed: %v", werr)
	}
	return ""
}
