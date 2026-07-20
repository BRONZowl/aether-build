#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_prompt_queue_push_pop_drop :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	testing.expect(t, prompt_queue_len(&st) == 0)
	testing.expect(t, prompt_queue_push(&st, "  first  "))
	testing.expect(t, prompt_queue_push(&st, "second"))
	testing.expect(t, prompt_queue_len(&st) == 2)
	testing.expect(t, !prompt_queue_push(&st, "   "))

	p, ok := prompt_queue_pop_front(&st)
	testing.expect(t, ok)
	testing.expect(t, p == "first")
	delete(p)
	testing.expect(t, prompt_queue_len(&st) == 1)

	testing.expect(t, prompt_queue_drop(&st, 0))
	testing.expect(t, prompt_queue_len(&st) == 0)

	for i in 0 ..< MAX_PROMPT_QUEUE {
		testing.expect(t, prompt_queue_push(&st, "x"))
	}
	testing.expect(t, !prompt_queue_push(&st, "overflow"))
	prompt_queue_clear(&st)
	testing.expect(t, prompt_queue_len(&st) == 0)
}

@(test)
test_overlay_kind_priority :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	testing.expect(t, overlay_kind(&st) == .None)
	st.queue_pane_active = true
	testing.expect(t, overlay_kind(&st) == .Queue)
	st.ask_active = true
	testing.expect(t, overlay_kind(&st) == .Ask)
}
