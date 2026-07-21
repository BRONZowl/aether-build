package tools

import "core:strings"
import "core:testing"
import "core:time"

g_test_cancel_flag: bool
g_test_poll_n:      int

g_test_poll_cancel :: proc() {
	g_test_poll_n += 1
	// After ~150ms of polls request cancel
	if g_test_poll_n >= 12 {
		g_test_cancel_flag = true
	}
}

@(test)
test_tool_cancel_hooks_bash_sleep :: proc(t: ^testing.T) {
	g_test_cancel_flag = false
	g_test_poll_n = 0
	tool_set_cancel_hooks(&g_test_cancel_flag, g_test_poll_cancel)
	defer tool_clear_cancel_hooks()

	start := time.now()
	out := tool_run_terminal_cmd(
		`{"command":"sleep 30","timeout":120000}`,
		".",
		context.allocator,
	)
	elapsed := time.since(start)
	defer delete(out)

	testing.expect(t, strings.contains(out, "cancelled"), out)
	// Must not wait full 30s
	testing.expect(t, elapsed < 10 * time.Second)
}
