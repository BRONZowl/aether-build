package agent

import "core:strings"
import "core:testing"

@(test)
test_mcp_doctor_empty_config :: proc(t: ^testing.T) {
	// no mcp config in default test env — should not crash; may report no servers
	out := mcp_doctor_report("", false, true, context.temp_allocator)
	testing.expect(t, strings.contains(out, "mcp doctor"))
	testing.expect(t, strings.contains(out, "in-process"))
	// must not require host grok wording as primary failure
	testing.expect(t, !strings.contains(out, "AETHER_GROK_BIN"))
}

@(test)
test_mcp_list_config_runs :: proc(t: ^testing.T) {
	out := mcp_list_config(context.temp_allocator)
	testing.expect(t, strings.contains(out, "mcp config") || strings.contains(out, "configured"))
}

@(test)
test_mcp_help_mentions_in_process_doctor :: proc(t: ^testing.T) {
	out := handle_mcp_slash("help", false, true, context.temp_allocator)
	testing.expect(t, strings.contains(out, "doctor"))
	testing.expect(t, strings.contains(out, "in-process") || strings.contains(out, "no host"))
}
