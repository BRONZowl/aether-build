#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_csi_arrow_shift :: proc(t: ^testing.T) {
	testing.expect(t, !csi_arrow_shift(""))
	testing.expect(t, !csi_arrow_shift("1"))
	testing.expect(t, csi_arrow_shift("1;2")) // shift
	testing.expect(t, !csi_arrow_shift("1;3")) // alt only
	testing.expect(t, csi_arrow_shift("1;4")) // shift+alt
	testing.expect(t, !csi_arrow_shift("1;5")) // ctrl
	testing.expect(t, csi_arrow_shift("1;6")) // shift+ctrl
}

@(test)
test_scrollback_find_kind :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	state_add_block(&st, .User, "u0")
	state_add_block(&st, .Assistant, "a0")
	state_add_block(&st, .Tool, "t0", "bash")
	state_add_block(&st, .User, "u1")
	state_add_block(&st, .Assistant, "a1")

	// next user from -1 → 0
	testing.expect(t, scrollback_find_kind(&st, -1, 1, .User) == 0)
	// next user from 0 → 3
	testing.expect(t, scrollback_find_kind(&st, 0, 1, .User) == 3)
	// next user from 3 → none
	testing.expect(t, scrollback_find_kind(&st, 3, 1, .User) == -1)
	// prev user from len → 3
	testing.expect(t, scrollback_find_kind(&st, len(st.blocks), -1, .User) == 3)
	// prev assistant from 4 → 1
	testing.expect(t, scrollback_find_kind(&st, 4, -1, .Assistant) == 1)
	// tool from -1
	testing.expect(t, scrollback_find_kind(&st, -1, 1, .Tool) == 2)
	// empty dir
	testing.expect(t, scrollback_find_kind(&st, 0, 0, .User) == -1)
}

@(test)
test_scrollback_move_sel_kind :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)

	state_add_block(&st, .User, "u0")
	state_add_block(&st, .Assistant, "a0")
	state_add_block(&st, .User, "u1")
	state_add_block(&st, .Assistant, "a1")
	// indices: 0U 1A 2U 3A

	// no selection + next user → first user
	st.selected_block = -1
	testing.expect(t, scrollback_move_sel_kind(&st, 1, .User))
	testing.expect(t, st.selected_block == 0)

	// next user → 2
	testing.expect(t, scrollback_move_sel_kind(&st, 1, .User))
	testing.expect(t, st.selected_block == 2)

	// next user stuck
	testing.expect(t, !scrollback_move_sel_kind(&st, 1, .User))
	testing.expect(t, st.selected_block == 2)

	// prev user → 0
	testing.expect(t, scrollback_move_sel_kind(&st, -1, .User))
	testing.expect(t, st.selected_block == 0)

	// prev user stuck
	testing.expect(t, !scrollback_move_sel_kind(&st, -1, .User))

	// next assistant from 0 → 1
	testing.expect(t, scrollback_move_sel_kind(&st, 1, .Assistant))
	testing.expect(t, st.selected_block == 1)

	// next assistant → 3
	testing.expect(t, scrollback_move_sel_kind(&st, 1, .Assistant))
	testing.expect(t, st.selected_block == 3)

	// no selection + prev → last match
	st.selected_block = -1
	testing.expect(t, scrollback_move_sel_kind(&st, -1, .User))
	testing.expect(t, st.selected_block == 2)
}

@(test)
test_scrollback_move_sel_kind_empty :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.selected_block = 3
	testing.expect(t, !scrollback_move_sel_kind(&st, 1, .User))
	testing.expect(t, st.selected_block == -1)
}
