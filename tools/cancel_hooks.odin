// Package tools — cooperative cancel/poll for long FG tools (bash, etc.).
// Set by agent.run_agent_turn so shell waits honor Ctrl+C.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package tools

// Tool_Poll_Handler mirrors agent mid-turn key poll (no import cycle).
Tool_Poll_Handler :: #type proc()

g_tool_cancel:  ^bool
g_tool_on_poll: Tool_Poll_Handler

// tool_set_cancel_hooks wires turn cancel into tools package (call at turn start).
tool_set_cancel_hooks :: proc(cancel: ^bool, on_poll: Tool_Poll_Handler) {
	g_tool_cancel = cancel
	g_tool_on_poll = on_poll
}

tool_clear_cancel_hooks :: proc() {
	g_tool_cancel = nil
	g_tool_on_poll = nil
}

// tool_should_cancel: poll UI then return true if cancel requested.
tool_should_cancel :: proc() -> bool {
	if g_tool_on_poll != nil {
		g_tool_on_poll()
	}
	return g_tool_cancel != nil && g_tool_cancel^
}
