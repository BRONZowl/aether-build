package agent

import "core:testing"
import "aether:core"

@(test)
test_effective_permission_mode_snapshot :: proc(t: ^testing.T) {
	opts := Turn_Options {
		permission_mode = .Ask,
	}
	testing.expect(t, effective_permission_mode(opts) == .Ask)
	opts.permission_mode = .Read_Only
	testing.expect(t, effective_permission_mode(opts) == .Read_Only)
}

@(test)
test_effective_permission_mode_live :: proc(t: ^testing.T) {
	live := core.Permission_Mode.Always_Approve
	opts := Turn_Options {
		permission_mode = .Ask,
		permission_live = &live,
	}
	testing.expect(t, effective_permission_mode(opts) == .Always_Approve)
	live = .Read_Only
	testing.expect(t, effective_permission_mode(opts) == .Read_Only, "live pointer updates")
}

@(test)
test_ask_rest_of_turn_active :: proc(t: ^testing.T) {
	opts := Turn_Options{}
	testing.expect(t, !ask_rest_of_turn_active(opts))
	flag := false
	opts.ask_turn_allow = &flag
	testing.expect(t, !ask_rest_of_turn_active(opts))
	flag = true
	testing.expect(t, ask_rest_of_turn_active(opts))
}

@(test)
test_tool_result_is_error :: proc(t: ^testing.T) {
	testing.expect(t, tool_result_is_error("error: denied"))
	testing.expect(t, tool_result_is_error("  error: tool x denied by user"))
	testing.expect(t, tool_result_is_error("Error: boom"))
	testing.expect(t, !tool_result_is_error("ok"))
	testing.expect(t, !tool_result_is_error("errors listed:\n1"))
	testing.expect(t, !tool_result_is_error(""))
}

@(test)
test_tool_status_label :: proc(t: ^testing.T) {
	testing.expect(t, tool_status_label("bash", "error: no") == "fail: bash")
	testing.expect(t, tool_status_label("read_file", "1| hi") == "done: read_file")
}
