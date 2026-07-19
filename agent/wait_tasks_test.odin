package agent

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
test_wait_tasks_empty_ids :: proc(t: ^testing.T) {
	out := handle_wait_tasks(`{"task_ids":[]}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "task_ids required") || strings.contains(out, "error"))
}

@(test)
test_wait_tasks_too_many_ids :: proc(t: ^testing.T) {
	// 21 ids
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"task_ids":[`)
	for i in 0 ..< 21 {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, `"t%d"`, i)
	}
	strings.write_string(&b, `]}`)
	out := handle_wait_tasks(strings.to_string(b), context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "maximum") || strings.contains(out, "exceeds"))
}

@(test)
test_wait_tasks_not_found_snapshot :: proc(t: ^testing.T) {
	out := handle_wait_tasks(
		`{"task_ids":["no-such-task"],"timeout_ms":1}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "not_found") || strings.contains(out, "unknown"))
}

@(test)
test_get_task_output_poll_not_found :: proc(t: ^testing.T) {
	out := handle_get_task_output(`{"task_ids":["missing"]}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "not_found") || strings.contains(out, "unknown"))
}

@(test)
test_wait_tasks_default_timeout_applied :: proc(t: ^testing.T) {
	// With missing timeout_ms, wait_tasks still runs (default 30s) and returns not_found quickly
	out := handle_wait_tasks(`{"task_ids":["x"]}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "task_id: x") || strings.contains(out, "not_found"))
}
