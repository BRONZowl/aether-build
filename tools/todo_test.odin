package tools

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Serialize tests that touch the global todo registry.
g_todo_test_mu: sync.Mutex

@(test)
test_todo_status_round_trip :: proc(t: ^testing.T) {
	s, ok := todo_status_from_string("in_progress")
	testing.expect(t, ok && s == .In_Progress)
	testing.expect(t, todo_status_tag(.Completed) == "[completed]")
	testing.expect(t, todo_status_string(.Pending) == "pending")
}

@(test)
test_todo_write_replace_and_merge :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	todo_test_reset()
	defer todo_test_reset()

	out := tool_todo_write(
		`{"merge":false,"todos":[{"id":"1","content":"Task A","status":"pending"},{"id":"2","content":"Task B","status":"in_progress"}]}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Task A"))
	testing.expect(t, strings.contains(out, "Task B"))
	testing.expect(t, strings.contains(out, "[in_progress]"))

	// Merge: flip status only
	out2 := tool_todo_write(
		`{"merge":true,"todos":[{"id":"2","status":"completed"}]}`,
		context.allocator,
	)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "Task A"))
	testing.expect(t, strings.contains(out2, "Task B"))
	testing.expect(t, strings.contains(out2, "[completed]"))
	testing.expect(t, strings.contains(out2, "[pending]"))

	// Replace clears old
	out3 := tool_todo_write(
		`{"merge":false,"todos":[{"id":"x","content":"Only","status":"pending"}]}`,
		context.allocator,
	)
	defer delete(out3)
	testing.expect(t, strings.contains(out3, "Only"))
	testing.expect(t, !strings.contains(out3, "Task A"))
}

@(test)
test_todo_write_duplicate_id :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	todo_test_reset()
	defer todo_test_reset()

	out := tool_todo_write(
		`{"todos":[{"id":"a","content":"one"},{"id":"a","content":"two"}]}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Duplicate"))
}

@(test)
test_todo_write_auto_merge_status_only :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	todo_test_reset()
	defer todo_test_reset()

	seed := tool_todo_write(
		`{"merge":false,"todos":[{"id":"1","content":"Keep me","status":"in_progress"}]}`,
		context.allocator,
	)
	defer delete(seed)
	// merge:false but status-only update of existing id → auto-upgrade to merge
	out := tool_todo_write(
		`{"merge":false,"todos":[{"id":"1","status":"completed"}]}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Keep me"))
	testing.expect(t, strings.contains(out, "[completed]"))
}

@(test)
test_todo_write_disabled_env :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	prev := os.get_env("AETHER_NO_TODO_WRITE", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_TODO_WRITE")
		} else {
			_ = os.set_env("AETHER_NO_TODO_WRITE", prev)
		}
	}
	_ = os.set_env("AETHER_NO_TODO_WRITE", "1")
	testing.expect(t, !todo_write_enabled())
	out := tool_todo_write(`{"todos":[{"id":"1","content":"x"}]}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}

@(test)
test_todo_empty_summary :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	todo_test_reset()
	s := summarize_todo_state(context.allocator)
	defer delete(s)
	testing.expect(t, strings.contains(s, "No tasks"))
}

@(test)
test_todo_snapshot_restore_round_trip :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	todo_test_reset()
	defer todo_test_reset()
	// Other tests may set AETHER_NO_TODO_WRITE=1 on other threads
	prev := os.get_env("AETHER_NO_TODO_WRITE", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_TODO_WRITE")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_TODO_WRITE")
		} else {
			_ = os.set_env("AETHER_NO_TODO_WRITE", prev)
		}
	}

	out0 := tool_todo_write(
		`{"merge":false,"todos":[{"id":"a","content":"Alpha","status":"pending"},{"id":"b","content":"Beta","status":"completed"}]}`,
		context.allocator,
	)
	defer delete(out0)
	testing.expectf(t, strings.contains(out0, "Alpha"), "write: %s", out0)

	snap := todo_snapshot_json_array(context.allocator)
	defer delete(snap)
	testing.expectf(t, strings.contains(snap, `"id":"a"`), "snap: %s", snap)
	testing.expect(t, strings.contains(snap, "Alpha"))

	todo_clear()
	s0 := summarize_todo_state(context.allocator)
	defer delete(s0)
	testing.expect(t, strings.contains(s0, "No tasks"))

	err := todo_restore_from_json_text(snap)
	testing.expect(t, err == "")
	s1 := summarize_todo_state(context.allocator)
	defer delete(s1)
	testing.expect(t, strings.contains(s1, "Alpha"))
	testing.expect(t, strings.contains(s1, "Beta"))
	testing.expect(t, strings.contains(s1, "[pending]"))
	testing.expect(t, strings.contains(s1, "[completed]"))
	testing.expect(t, todo_open_count() == 1)
}

@(test)
test_todo_clear_and_open_count :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_todo_test_mu)
	defer sync.mutex_unlock(&g_todo_test_mu)
	todo_test_reset()
	defer todo_test_reset()

	testing.expect(t, todo_open_count() == 0)
	out := tool_todo_write(
		`{"merge":false,"todos":[{"id":"1","content":"A","status":"pending"},{"id":"2","content":"B","status":"in_progress"},{"id":"3","content":"C","status":"completed"},{"id":"4","content":"D","status":"cancelled"}]}`,
		context.allocator,
	)
	defer delete(out)
	// open = pending + in_progress only
	testing.expect(t, todo_open_count() == 2)
	todo_clear()
	testing.expect(t, todo_open_count() == 0)
	s := summarize_todo_state(context.allocator)
	defer delete(s)
	testing.expect(t, strings.contains(s, "No tasks"))
}
