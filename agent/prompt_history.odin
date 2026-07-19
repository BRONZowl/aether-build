// Prompt history helpers for /history slash (Grok-shaped recall).
package agent

import "core:fmt"
import "core:strconv"
import "core:strings"

// collect_user_prompts returns session user messages newest-first (owned clones).
// Caller must delete each string and the slice.
collect_user_prompts :: proc(
	msgs: []Chat_Message,
	allocator := context.allocator,
) -> []string {
	tmp := make([dynamic]string, 0, 16, context.temp_allocator)
	for m in msgs {
		if m.role == .User {
			t := strings.trim_space(m.content)
			if t != "" {
				append(&tmp, t)
			}
		}
	}
	// reverse to newest first
	n := len(tmp)
	out := make([]string, n, allocator)
	for i := 0; i < n; i += 1 {
		out[i] = strings.clone(tmp[n - 1 - i], allocator)
	}
	return out
}

destroy_string_list :: proc(list: []string) {
	for s in list {
		delete(s)
	}
	delete(list)
}

// filter_prompts keeps items containing query (case-insensitive). query empty → all.
// Returns owned subset clones; caller destroy_string_list.
filter_prompts :: proc(
	prompts: []string,
	query: string,
	allocator := context.allocator,
) -> []string {
	q := strings.trim_space(query)
	if q == "" {
		out := make([]string, len(prompts), allocator)
		for p, i in prompts {
			out[i] = strings.clone(p, allocator)
		}
		return out
	}
	ql := strings.to_lower(q, context.temp_allocator)
	tmp := make([dynamic]string, 0, len(prompts), context.temp_allocator)
	for p in prompts {
		pl := strings.to_lower(p, context.temp_allocator)
		if strings.contains(pl, ql) {
			append(&tmp, p)
		}
	}
	out := make([]string, len(tmp), allocator)
	for p, i in tmp {
		out[i] = strings.clone(p, allocator)
	}
	return out
}

// format_history_list: numbered newest-first, truncated one-liners.
format_history_list :: proc(
	prompts: []string,
	max_items := 20,
	line_max := 100,
	allocator := context.allocator,
) -> string {
	if len(prompts) == 0 {
		return strings.clone("aether: no user prompts in this session", allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "aether: prompt history (newest first; /history <n> to show full):\n")
	limit := min(len(prompts), max_items)
	for i := 0; i < limit; i += 1 {
		line := prompts[i]
		// first line only
		if nl := strings.index_byte(line, '\n'); nl >= 0 {
			line = line[:nl]
		}
		if len(line) > line_max {
			line = fmt.tprintf("%s…", line[:line_max - 1])
		}
		strings.write_string(&b, fmt.tprintf("  %d. %s\n", i + 1, line))
	}
	if len(prompts) > max_items {
		strings.write_string(
			&b,
			fmt.tprintf("  … %d more (filter: /history <text>)\n", len(prompts) - max_items),
		)
	}
	return strings.to_string(b)
}

// parse_history_index: "3" → 3 ok; else false.
parse_history_index :: proc(arg: string) -> (n: int, ok: bool) {
	a := strings.trim_space(arg)
	if a == "" {
		return 0, false
	}
	// pure digits only
	for i in 0 ..< len(a) {
		if a[i] < '0' || a[i] > '9' {
			return 0, false
		}
	}
	v, okp := strconv.parse_int(a, 10)
	if !okp || v < 1 {
		return 0, false
	}
	return v, true
}
