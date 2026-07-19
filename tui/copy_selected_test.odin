#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_copy_selected_block_nothing :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	// no selection
	msg := copy_selected_block(&st, false)
	testing.expect(t, msg == "nothing selected", msg)
}

@(test)
test_copy_selected_block_empty_text :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	state_add_block(&st, .User, "")
	// empty clone still has empty text
	st.selected_block = 0
	// empty block: copy_selected may say empty or try clipboard
	// with empty string returns "empty block"
	// but state_add_block with "" still creates block
	if len(st.blocks) > 0 {
		// force empty
		delete(st.blocks[0].text)
		st.blocks[0].text = ""
	}
	msg := copy_selected_block(&st, false)
	testing.expect(t, msg == "empty block", msg)
}
