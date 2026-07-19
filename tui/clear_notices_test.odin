#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_state_clear_notices :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	state_add_notice(&st, "one")
	state_add_notice(&st, "two")
	testing.expect(t, len(st.notices) == 2)
	state_clear_notices(&st)
	testing.expect(t, len(st.notices) == 0)
}
