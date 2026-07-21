// Package agent — context window usage estimate + /context slash (B1.1).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

DEFAULT_CONTEXT_WINDOW :: 131_072

// default_context_window from AETHER_CONTEXT_WINDOW or DEFAULT_CONTEXT_WINDOW.
default_context_window :: proc() -> int {
	if v := os.get_env("AETHER_CONTEXT_WINDOW", context.temp_allocator); v != "" {
		if n, ok := strconv.parse_int(v); ok && n > 0 {
			return n
		}
	}
	return DEFAULT_CONTEXT_WINDOW
}

// estimate_message_chars sums content + tool call argument lengths.
estimate_message_chars :: proc(msgs: []Chat_Message) -> int {
	n := 0
	for m in msgs {
		n += len(m.content)
		n += len(m.tool_call_id)
		for tc in m.tool_calls {
			n += len(tc.id) + len(tc.name) + len(tc.arguments)
		}
	}
	return n
}

// estimate_tokens: chars/4 (cheap heuristic; min 0).
estimate_tokens :: proc(chars: int) -> int {
	if chars <= 0 {
		return 0
	}
	return (chars + 3) / 4
}

// context_usage_pct used/window as 0–100.
context_usage_pct :: proc(used, window: int) -> int {
	if window <= 0 {
		return 0
	}
	if used <= 0 {
		return 0
	}
	pct := (used * 100) / window
	if pct > 100 {
		return 100
	}
	return pct
}

// usage_bar renders a fixed-width ASCII bar (width 24).
usage_bar :: proc(pct: int, allocator := context.allocator) -> string {
	w := 24
	filled := (pct * w) / 100
	if filled > w {
		filled = w
	}
	if filled < 0 {
		filled = 0
	}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for i in 0 ..< w {
		if i < filled {
			strings.write_byte(&b, '#')
		} else {
			strings.write_byte(&b, '-')
		}
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// count_roles tallies system/user/assistant/tool.
count_roles :: proc(msgs: []Chat_Message) -> (sys, user, asst, tool: int) {
	for m in msgs {
		switch m.role {
		case .System:
			sys += 1
		case .User:
			user += 1
		case .Assistant:
			asst += 1
		case .Tool:
			tool += 1
		}
	}
	return
}

// format_context_status builds /context multi-line output.
format_context_status :: proc(sess: ^Session, allocator := context.allocator) -> string {
	if sess == nil {
		return strings.clone("aether: no session", allocator)
	}
	chars := estimate_message_chars(sess.msgs[:])
	toks := estimate_tokens(chars)
	window := default_context_window()
	pct := context_usage_pct(toks, window)
	bar := usage_bar(pct, context.temp_allocator)
	sys, user, asst, tool := count_roles(sess.msgs[:])

	plan := "off"
	if plan_mode_is_active() {
		plan = "active"
	} else if plan_mode_is_pending() {
		plan = "pending"
	} else if plan_mode_is_exit_pending() {
		plan = "exit_pending"
	} else if sess.plan_mode {
		plan = "active"
	}

	inject := "pending"
	if !memory_inject_enabled() {
		inject = "disabled"
	} else if sess.memory_injected || conversation_has_memory_context(sess.msgs[:]) {
		inject = "done"
	}

	return fmt.aprintf(
		"context window:  %d (est.)\nused (est.):     %d tokens (~%d chars)\nusage:           %d%%  %s\nmessages:        %d (system %d, user %d, asst %d, tool %d)\nmodel:           %s\ncwd:             %s\nsession:         %s\nplan:            %s\nmemory inject:   %s\ntokenizer:       chars/4 heuristic (AETHER_CONTEXT_WINDOW to override window)",
		window,
		toks,
		chars,
		pct,
		bar,
		len(sess.msgs),
		sys,
		user,
		asst,
		tool,
		sess.model if sess.model != "" else "(default)",
		sess.cwd if sess.cwd != "" else "(none)",
		sess.id,
		plan,
		inject,
		allocator = allocator,
	)
}

// handle_context_slash implements /context [help].
handle_context_slash :: proc(
	sess: ^Session,
	arg: string,
	allocator := context.allocator,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /context\nShow estimated context window usage and session stats.\n" +
			"Token estimate = total message chars / 4.\n" +
			"Override window: AETHER_CONTEXT_WINDOW=N",
			allocator,
		)
	}
	return format_context_status(sess, allocator)
}
