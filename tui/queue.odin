// Package tui — mid-turn prompt queue (Grok /queue parity).
// While streaming: type into composer; Enter enqueues. Empty Enter force-sends
// top item (cancels current turn, then runs queue head). After each turn ends,
// auto-drain the next queued prompt.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"

MAX_PROMPT_QUEUE :: 32

// prompt_queue_init / destroy owned strings.
prompt_queue_init :: proc(s: ^App_State) {
	s.prompt_queue = make([dynamic]string, 0, 8)
	s.queue_pane_active = false
	s.queue_force_send = false
	s.queue_sel = 0
}

prompt_queue_destroy :: proc(s: ^App_State) {
	prompt_queue_clear(s)
	delete(s.prompt_queue)
	s.queue_pane_active = false
}

prompt_queue_clear :: proc(s: ^App_State) {
	for p in s.prompt_queue {
		delete(p)
	}
	clear(&s.prompt_queue)
	s.queue_sel = 0
	s.queue_force_send = false
}

prompt_queue_len :: proc(s: ^App_State) -> int {
	return len(s.prompt_queue)
}

// prompt_queue_push clones text onto the queue. Returns false if full/empty.
prompt_queue_push :: proc(s: ^App_State, text: string) -> bool {
	t := strings.trim_space(text)
	if t == "" {
		return false
	}
	if len(s.prompt_queue) >= MAX_PROMPT_QUEUE {
		return false
	}
	append(&s.prompt_queue, strings.clone(t))
	return true
}

// prompt_queue_pop_front takes ownership of the first item (caller deletes).
prompt_queue_pop_front :: proc(s: ^App_State) -> (string, bool) {
	if len(s.prompt_queue) == 0 {
		return "", false
	}
	p := s.prompt_queue[0]
	ordered_remove(&s.prompt_queue, 0)
	if s.queue_sel > 0 {
		s.queue_sel -= 1
	}
	if s.queue_sel >= len(s.prompt_queue) {
		s.queue_sel = max(0, len(s.prompt_queue) - 1)
	}
	return p, true
}

// prompt_queue_drop removes selected index (queue pane / /queue drop N).
prompt_queue_drop :: proc(s: ^App_State, idx: int) -> bool {
	if idx < 0 || idx >= len(s.prompt_queue) {
		return false
	}
	delete(s.prompt_queue[idx])
	ordered_remove(&s.prompt_queue, idx)
	if s.queue_sel >= len(s.prompt_queue) {
		s.queue_sel = max(0, len(s.prompt_queue) - 1)
	}
	return true
}

// prompt_queue_format_list for /queue slash and pane.
prompt_queue_format_list :: proc(s: ^App_State, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## queue\n")
	if len(s.prompt_queue) == 0 {
		strings.write_string(
			&b,
			"No prompts queued.\n" +
			"While the agent is working: type a follow-up and press Enter to queue it.\n" +
			"Empty Enter (mid-turn) force-sends the top item after cancelling the current turn.\n",
		)
		return strings.to_string(b)
	}
	fmt.sbprintf(&b, "%d queued (FIFO; #1 sends next):\n", len(s.prompt_queue))
	for i in 0 ..< len(s.prompt_queue) {
		t := s.prompt_queue[i]
		if len(t) > 100 {
			t = fmt.tprintf("%s…", t[:97])
		}
		mark := " " if i != s.queue_sel else ">"
		fmt.sbprintf(&b, " %s %d. %s\n", mark, i + 1, t)
	}
	strings.write_string(
		&b,
		"\n  /queue drop N  remove item  ·  /queue clear  ·  empty Enter mid-turn = force-send #1\n",
	)
	return strings.to_string(b)
}

queue_pane_open :: proc(s: ^App_State) {
	s.queue_pane_active = true
	if s.queue_sel >= len(s.prompt_queue) {
		s.queue_sel = max(0, len(s.prompt_queue) - 1)
	}
	state_set_status(s, "queue")
}

queue_pane_close :: proc(s: ^App_State) {
	s.queue_pane_active = false
	state_set_status(s, "ready")
}

// handle_queue_pane_key: list navigation + drop.
handle_queue_pane_key :: proc(st: ^App_State, key: Key) -> bool {
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		queue_pane_close(st)
		return true
	case .Up, .Ctrl_K:
		if st.queue_sel > 0 {
			st.queue_sel -= 1
		}
		return true
	case .Down, .Ctrl_J:
		if st.queue_sel + 1 < len(st.prompt_queue) {
			st.queue_sel += 1
		}
		return true
	case .Char:
		if key.ch == 'd' || key.ch == 'D' || key.ch == 'x' || key.ch == 'X' {
			if prompt_queue_drop(st, st.queue_sel) {
				state_set_status(st, fmt.tprintf("queue %d left", len(st.prompt_queue)))
			}
			return true
		}
		if key.ch == 'c' || key.ch == 'C' {
			prompt_queue_clear(st)
			state_set_status(st, "queue cleared")
			return true
		}
	case .Backspace:
		if prompt_queue_drop(st, st.queue_sel) {
			state_set_status(st, fmt.tprintf("queue %d left", len(st.prompt_queue)))
		}
		return true
	}
	return false
}
