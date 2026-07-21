// Package agent — first-turn memory context injection (A2.3).
// Simplified Grok first_turn_memory_reminder: file-backed MEMORY.md (+ optional keyword hits).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"
import "aether:tools"

MEMORY_INJECT_MARKER :: "## Memory context (auto-injected)"
MEMORY_INJECT_WS_CAP :: 6000
MEMORY_INJECT_GLOBAL_CAP :: 3000
MEMORY_INJECT_SEARCH_CAP :: 1500

// memory_inject_enabled is false when memory off or AETHER_NO_MEMORY_INJECT.
// Config [memory.initial_injection] enabled=false also disables (env wins).
memory_inject_enabled :: proc() -> bool {
	if !tools.memory_enabled() {
		return false
	}
	if v := os.get_env("AETHER_NO_MEMORY_INJECT", context.temp_allocator); v == "1" ||
	   v == "true" ||
	   v == "yes" ||
	   v == "on" {
		return false
	}
	if !core.flag_memory_inject() {
		return false
	}
	return true
}

// conversation_has_memory_context reports marker already present in system message.
conversation_has_memory_context :: proc(msgs: []Chat_Message) -> bool {
	for m in msgs {
		if m.role == .System && strings.contains(m.content, MEMORY_INJECT_MARKER) {
			return true
		}
	}
	return false
}

// is_greeting_or_short: short or classic greeting → generic inject query.
is_greeting_or_short :: proc(q: string) -> bool {
	t := strings.trim_space(q)
	if len(t) < 20 {
		return true
	}
	lower := strings.to_lower(t, context.temp_allocator)
	greets := []string{"hi", "hello", "hey", "yo", "sup", "good morning", "good evening"}
	for g in greets {
		if lower == g || strings.has_prefix(lower, fmt.tprintf("%s ", g)) ||
		   strings.has_prefix(lower, fmt.tprintf("%s!", g)) {
			return true
		}
	}
	return false
}

// read_global_memory_md reads {root}/MEMORY.md (allocated) or empty.
read_global_memory_md :: proc(allocator := context.allocator) -> string {
	root := tools.memory_root(context.temp_allocator)
	path, _ := filepath.join({root, "MEMORY.md"}, context.temp_allocator)
	if !os.exists(path) || os.is_directory(path) {
		return strings.clone("", allocator)
	}
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return strings.clone("", allocator)
	}
	return string(data)
}

// build_memory_injection_body builds markdown body (without marker header). Empty if nothing useful.
build_memory_injection_body :: proc(
	cwd: string,
	user_query: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	any := false

	ws := tools.memory_read_workspace_md(cwd, context.temp_allocator)
	if w := strings.trim_space(ws); w != "" && !is_scaffold_template(w) {
		strings.write_string(&b, "### Workspace MEMORY.md\n\n")
		if len(w) > MEMORY_INJECT_WS_CAP {
			strings.write_string(&b, w[:MEMORY_INJECT_WS_CAP])
			strings.write_string(&b, "\n…\n")
		} else {
			strings.write_string(&b, w)
			if !strings.has_suffix(w, "\n") {
				strings.write_byte(&b, '\n')
			}
		}
		any = true
	}

	gl := read_global_memory_md(context.temp_allocator)
	if g := strings.trim_space(gl); g != "" && !is_scaffold_template(g) {
		if any {
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "### Global MEMORY.md\n\n")
		if len(g) > MEMORY_INJECT_GLOBAL_CAP {
			strings.write_string(&b, g[:MEMORY_INJECT_GLOBAL_CAP])
			strings.write_string(&b, "\n…\n")
		} else {
			strings.write_string(&b, g)
			if !strings.has_suffix(g, "\n") {
				strings.write_byte(&b, '\n')
			}
		}
		any = true
	}

	// Optional keyword hits from session logs / other files when query is substantive.
	q := strings.trim_space(user_query)
	if !is_greeting_or_short(q) && len(q) >= 20 {
		args := fmt.tprintf(
			`{"query":"%s","max_results":2}`,
			json_escape(q, context.temp_allocator),
		)
		hit := tools.tool_memory_search(args, cwd, context.temp_allocator)
		if strings.contains(hit, "Found") && !strings.contains(hit, "No memory results") {
			if any {
				strings.write_string(&b, "\n")
			}
			strings.write_string(&b, "### Related memory search\n\n")
			snip := hit
			if len(snip) > MEMORY_INJECT_SEARCH_CAP {
				snip = snip[:MEMORY_INJECT_SEARCH_CAP]
			}
			strings.write_string(&b, snip)
			any = true
		}
	}

	if !any {
		return strings.clone("", allocator)
	}
	return strings.to_string(b)
}

// ensure_memory_injection_msgs appends memory block to the first system message once.
// latch: optional *bool (session.memory_injected); set true after attempt.
// Returns true if content was added.
ensure_memory_injection_msgs :: proc(
	msgs: ^[dynamic]Chat_Message,
	cwd: string,
	user_query: string,
	latch: ^bool = nil,
) -> bool {
	if msgs == nil || len(msgs) == 0 {
		return false
	}
	if !memory_inject_enabled() {
		return false
	}
	if conversation_has_memory_context(msgs[:]) {
		if latch != nil {
			latch^ = true
		}
		return false
	}
	if latch != nil && latch^ {
		return false
	}

	body := build_memory_injection_body(cwd, user_query, context.temp_allocator)
	if strings.trim_space(body) == "" {
		// Nothing useful — latch so we don't retry every turn.
		if latch != nil {
			latch^ = true
		}
		return false
	}

	sys_i := -1
	for m, i in msgs {
		if m.role == .System {
			sys_i = i
			break
		}
	}
	if sys_i < 0 {
		return false
	}

	block := fmt.tprintf("\n\n%s\n\n%s", MEMORY_INJECT_MARKER, body)
	old := msgs[sys_i].content
	msgs[sys_i].content = strings.concatenate({old, block}, context.allocator)
	delete(old)
	if latch != nil {
		latch^ = true
	}
	return true
}

// ensure_memory_injection session-aware wrapper.
ensure_memory_injection :: proc(
	msgs: ^[dynamic]Chat_Message,
	cwd: string,
	user_query: string,
	sess: ^Session = nil,
) -> bool {
	latch: ^bool = nil
	if sess != nil {
		latch = &sess.memory_injected
	}
	return ensure_memory_injection_msgs(msgs, cwd, user_query, latch)
}

// last_user_text returns the last user message content (or empty).
last_user_text :: proc(msgs: []Chat_Message) -> string {
	for i := len(msgs) - 1; i >= 0; i -= 1 {
		if msgs[i].role == .User {
			return msgs[i].content
		}
	}
	return ""
}
