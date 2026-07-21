// Package tools — cooperative cancel/poll for long FG tools (bash, etc.).
// Set by agent.run_agent_turn so shell waits honor Ctrl+C.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package tools

import "core:fmt"
import "core:strings"

// Tool_Poll_Handler mirrors agent mid-turn key poll (no import cycle).
Tool_Poll_Handler :: #type proc()
// Tool_Status_Handler optional status-bar updates during long tools.
Tool_Status_Handler :: #type proc(text: string)

g_tool_cancel:    ^bool
g_tool_on_poll:   Tool_Poll_Handler
g_tool_on_status: Tool_Status_Handler

// tool_set_cancel_hooks wires turn cancel into tools package (call at turn start).
tool_set_cancel_hooks :: proc(
	cancel: ^bool,
	on_poll: Tool_Poll_Handler,
	on_status: Tool_Status_Handler = nil,
) {
	g_tool_cancel = cancel
	g_tool_on_poll = on_poll
	g_tool_on_status = on_status
}

tool_clear_cancel_hooks :: proc() {
	g_tool_cancel = nil
	g_tool_on_poll = nil
	g_tool_on_status = nil
}

// tool_should_cancel: poll UI then return true if cancel requested.
tool_should_cancel :: proc() -> bool {
	if g_tool_on_poll != nil {
		g_tool_on_poll()
	}
	return g_tool_cancel != nil && g_tool_cancel^
}

// tool_emit_status: optional mid-tool status (e.g. shell still running).
tool_emit_status :: proc(text: string) {
	if g_tool_on_status != nil && text != "" {
		g_tool_on_status(text)
	}
}

// truncate_cmd: short one-line command for status / hang log.
truncate_cmd :: proc(cmd: string, n: int) -> string {
	t := strings.trim_space(cmd)
	if len(t) <= n {
		return t
	}
	if n <= 1 {
		return "…"
	}
	return fmt.tprintf("%s…", t[:n - 1])
}
