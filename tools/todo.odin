// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

// todo_write — Grok Build TodoWriteTool port (product Full).
// Reference: crates/codegen/xai-grok-tools/.../todo/mod.rs
// Process list + session JSON durability (save/load with session file).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "aether:core"

Todo_Status :: enum {
	Pending,
	In_Progress,
	Completed,
	Cancelled,
}

Todo_Item :: struct {
	id:      string,
	content: string,
	status:  Todo_Status,
}

g_todo_mu:    sync.Mutex
g_todo_items: [dynamic]Todo_Item

// Keep registry on process heap so Odin's per-test rollback allocator cannot
// free the dynamic-array backing while g_todo_items still points at it.
todo_ensure_heap :: proc() {
	raw := (^runtime.Raw_Dynamic_Array)(&g_todo_items)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	old := g_todo_items
	g_todo_items = make([dynamic]Todo_Item, 0, max(8, len(old)), runtime.heap_allocator())
	for it in old {
		append(&g_todo_items, it)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

// todo_write_enabled: opt-out AETHER_NO_TODO_WRITE=1
todo_write_enabled :: proc() -> bool {
	return !core.feature_killed("AETHER_NO_TODO_WRITE")
}

todo_status_from_string :: proc(s: string) -> (Todo_Status, bool) {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "pending":
		return .Pending, true
	case "in_progress", "in-progress", "inprogress", "running":
		return .In_Progress, true
	case "completed", "complete", "done":
		return .Completed, true
	case "cancelled", "canceled":
		return .Cancelled, true
	}
	return .Pending, false
}

todo_status_tag :: proc(s: Todo_Status) -> string {
	switch s {
	case .Pending:
		return "[pending]"
	case .In_Progress:
		return "[in_progress]"
	case .Completed:
		return "[completed]"
	case .Cancelled:
		return "[cancelled]"
	}
	return "[pending]"
}

todo_status_string :: proc(s: Todo_Status) -> string {
	switch s {
	case .Pending:
		return "pending"
	case .In_Progress:
		return "in_progress"
	case .Completed:
		return "completed"
	case .Cancelled:
		return "cancelled"
	}
	return "pending"
}

// free_todo_items clears owned strings and empties the slice.
free_todo_items :: proc(items: ^[dynamic]Todo_Item) {
	for &it in items {
		delete(it.id)
		delete(it.content)
	}
	clear(items)
}

// todo_find_index returns index of id or -1 (caller holds lock).
todo_find_index :: proc(id: string) -> int {
	for it, i in g_todo_items {
		if it.id == id {
			return i
		}
	}
	return -1
}

// summarize_todo_state matches Grok summarize_todo_state for model output.
summarize_todo_state :: proc(allocator := context.allocator) -> string {
	sync.mutex_lock(&g_todo_mu)
	defer sync.mutex_unlock(&g_todo_mu)
	if len(g_todo_items) == 0 {
		return strings.clone("No tasks currently tracked.", allocator)
	}
	b := strings.builder_make(allocator)
	for it in g_todo_items {
		fmt.sbprintf(&b, "- %s %s: %s\n", todo_status_tag(it.status), it.id, it.content)
	}
	return strings.to_string(b)
}

// todo_clear empties the process-local list (slash /todos clear, /new).
todo_clear :: proc() {
	sync.mutex_lock(&g_todo_mu)
	todo_ensure_heap()
	free_todo_items(&g_todo_items)
	sync.mutex_unlock(&g_todo_mu)
}

// todo_open_count: pending + in_progress (for TUI chrome).
todo_open_count :: proc() -> int {
	sync.mutex_lock(&g_todo_mu)
	defer sync.mutex_unlock(&g_todo_mu)
	n := 0
	for it in g_todo_items {
		if it.status == .Pending || it.status == .In_Progress {
			n += 1
		}
	}
	return n
}

// Todo_Update is one item from the tool arguments.
Todo_Update :: struct {
	id:         string,
	content:    string, // empty = omitted
	has_status: bool,
	status:     Todo_Status,
}

// parse_todo_updates extracts todos[] from JSON args.
parse_todo_updates :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> (
	merge: bool,
	updates: [dynamic]Todo_Update,
	err: string,
) {
	merge = true // Grok default
	updates = make([dynamic]Todo_Update, 0, 8, allocator)

	obj, ok := json_obj(arguments_json)
	if !ok {
		return true, updates, "invalid JSON arguments"
	}

	if v, has := obj["merge"]; has {
		#partial switch t in v {
		case json.Boolean:
			merge = bool(t)
		case json.String:
			s := strings.to_lower(string(t), context.temp_allocator)
			if s == "false" || s == "0" || s == "no" {
				merge = false
			} else if s == "true" || s == "1" || s == "yes" {
				merge = true
			}
		}
	}

	arr_val, has_todos := obj["todos"]
	if !has_todos {
		return merge, updates, "todos array is required"
	}
	arr, is_arr := arr_val.(json.Array)
	if !is_arr {
		return merge, updates, "todos must be an array"
	}

	seen := make(map[string]bool, context.temp_allocator)
	for item in arr {
		to, is_obj := item.(json.Object)
		if !is_obj {
			return merge, updates, "each todo must be an object"
		}
		id := strings.trim_space(jstr(to, "id"))
		if id == "" {
			return merge, updates, "each todo requires a non-empty id"
		}
		if seen[id] {
			return merge, updates, fmt.tprintf(
				"Duplicate todo ID in request: %q. Each todo item must have a unique ID.",
				id,
			)
		}
		seen[id] = true

		content := ""
		if cv, has_c := to["content"]; has_c {
			if s, is_s := cv.(json.String); is_s {
				content = string(s)
			}
		}
		has_status := false
		st: Todo_Status = .Pending
		if sv, has_s := to["status"]; has_s {
			if s, is_s := sv.(json.String); is_s {
				parsed, pok := todo_status_from_string(string(s))
				if !pok {
					return merge, updates, fmt.tprintf("invalid status %q", string(s))
				}
				st = parsed
				has_status = true
			}
		}
		append(
			&updates,
			Todo_Update {
				id         = strings.clone(id, allocator),
				content    = strings.clone(content, allocator),
				has_status = has_status,
				status     = st,
			},
		)
	}
	return merge, updates, ""
}

free_todo_updates :: proc(updates: ^[dynamic]Todo_Update) {
	for &u in updates {
		delete(u.id)
		delete(u.content)
	}
	delete(updates^)
	updates^ = {}
}

// apply_replace: merge=false — full list replacement (Grok apply_replace).
apply_replace :: proc(updates: []Todo_Update) {
	todo_ensure_heap()
	free_todo_items(&g_todo_items)
	for u in updates {
		content := u.content
		if content == "" {
			content = u.id
		}
		status := u.status
		if !u.has_status {
			status = .Pending
		}
		append(
			&g_todo_items,
			Todo_Item {
				id      = strings.clone(u.id, context.allocator),
				content = strings.clone(content, context.allocator),
				status  = status,
			},
		)
	}
}

// apply_merge: merge=true — update by id or append (Grok apply_merge).
apply_merge :: proc(updates: []Todo_Update) {
	todo_ensure_heap()
	for u in updates {
		idx := todo_find_index(u.id)
		if idx >= 0 {
			if u.content != "" {
				delete(g_todo_items[idx].content)
				g_todo_items[idx].content = strings.clone(u.content, context.allocator)
			}
			if u.has_status {
				g_todo_items[idx].status = u.status
			}
			continue
		}
		// new item
		content := u.content
		if content == "" {
			content = u.id
		}
		status := u.status
		if !u.has_status {
			status = .Pending
		}
		append(
			&g_todo_items,
			Todo_Item {
				id      = strings.clone(u.id, context.allocator),
				content = strings.clone(content, context.allocator),
				status  = status,
			},
		)
	}
}

// has_id_in_state (caller holds lock).
todo_has_id :: proc(id: string) -> bool {
	return todo_find_index(id) >= 0
}

// tool_todo_write is the model-facing tool implementation.
tool_todo_write :: proc(arguments_json: string, allocator := context.allocator) -> string {
	if !todo_write_enabled() {
		return strings.clone("error: todo_write disabled (AETHER_NO_TODO_WRITE=1)", allocator)
	}

	merge, updates, err := parse_todo_updates(arguments_json, context.allocator)
	if err != "" {
		free_todo_updates(&updates)
		if strings.has_prefix(err, "Duplicate") {
			return strings.clone(err, allocator)
		}
		return fmt.aprintf("error: %s", err, allocator = allocator)
	}
	defer free_todo_updates(&updates)

	sync.mutex_lock(&g_todo_mu)
	// Auto-upgrade to merge when model forgot merge:true but only flips status on existing ids
	// (Grok effective_merge heuristic).
	effective_merge := merge
	if !merge && len(g_todo_items) > 0 && len(updates) > 0 {
		all_status_only := true
		for u in updates {
			if u.content != "" || !todo_has_id(u.id) {
				all_status_only = false
				break
			}
		}
		if all_status_only {
			effective_merge = true
		}
	}
	if effective_merge {
		apply_merge(updates[:])
	} else {
		apply_replace(updates[:])
	}
	sync.mutex_unlock(&g_todo_mu)

	return summarize_todo_state(allocator)
}

// todo_json_escape for session embedding (shared core helper).
todo_json_escape :: proc(s: string, allocator := context.allocator) -> string {
	return core.json_string_escape(s, allocator)
}

// todo_snapshot_json_array: `[{...},...]` for session JSON (caller embeds under "todos").
todo_snapshot_json_array :: proc(allocator := context.allocator) -> string {
	sync.mutex_lock(&g_todo_mu)
	defer sync.mutex_unlock(&g_todo_mu)
	todo_ensure_heap()
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for it, i in g_todo_items {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		// Avoid fmt `{` directives — hand-build JSON object
		strings.write_string(&b, `{"id":"`)
		strings.write_string(&b, todo_json_escape(it.id, context.temp_allocator))
		strings.write_string(&b, `","content":"`)
		strings.write_string(&b, todo_json_escape(it.content, context.temp_allocator))
		strings.write_string(&b, `","status":"`)
		strings.write_string(&b, todo_status_string(it.status))
		strings.write_string(&b, `"}`)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// todo_restore_from_json_array replaces process list from a session "todos" array.
todo_restore_from_json_array :: proc(arr: json.Array) {
	sync.mutex_lock(&g_todo_mu)
	defer sync.mutex_unlock(&g_todo_mu)
	todo_ensure_heap()
	free_todo_items(&g_todo_items)
	heap := runtime.heap_allocator()
	for item in arr {
		obj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		id := strings.trim_space(jstr(obj, "id"))
		if id == "" {
			continue
		}
		content := jstr(obj, "content")
		if content == "" {
			content = id
		}
		st: Todo_Status = .Pending
		if sv, has := obj["status"]; has {
			if s, is_s := sv.(json.String); is_s {
				if p, ok := todo_status_from_string(string(s)); ok {
					st = p
				}
			}
		}
		append(
			&g_todo_items,
			Todo_Item {
				id      = strings.clone(id, heap),
				content = strings.clone(content, heap),
				status  = st,
			},
		)
	}
}

// todo_restore_from_json_text parses a full array string (tests / helpers).
todo_restore_from_json_text :: proc(json_text: string) -> string /* err */ {
	val, err := json.parse(
		transmute([]byte)json_text,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return "invalid todos JSON"
	}
	arr, ok := val.(json.Array)
	if !ok {
		return "todos must be array"
	}
	todo_restore_from_json_array(arr)
	return ""
}

// todo_test_reset clears global state (tests only).
todo_test_reset :: proc() {
	todo_clear()
}
