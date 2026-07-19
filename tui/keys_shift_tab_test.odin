#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

// Shift+Tab under Kitty progressive enhancement arrives as CSI-u Tab+shift,
// not classic CSI Z. These decode tests lock that path (mode cycle depends on it).

@(test)
test_decode_csi_u_shift_tab :: proc(t: ^testing.T) {
	// ESC [ 9 ; 2 u
	k := decode_csi_u("9;2")
	testing.expect(t, k.kind == .Shift_Tab, "9;2u should be Shift_Tab")

	// mods 4 = shift+alt → still shift bit
	k2 := decode_csi_u("9;4")
	testing.expect(t, k2.kind == .Shift_Tab, "9;4u shift+alt → Shift_Tab")

	// bare Tab via CSI-u
	k3 := decode_csi_u("9")
	testing.expect(t, k3.kind == .Tab, "9u should be Tab")
	k4 := decode_csi_u("9;1")
	testing.expect(t, k4.kind == .Tab, "9;1u (no mods) should be Tab")
}

@(test)
test_decode_csi_tilde_shift_tab :: proc(t: ^testing.T) {
	// modifyOtherKeys: ESC [ 27 ; 2 ; 9 ~
	k := decode_csi_tilde("27;2;9")
	testing.expect(t, k.kind == .Shift_Tab, "27;2;9~ should be Shift_Tab")

	k2 := decode_csi_tilde("27;1;9")
	testing.expect(t, k2.kind == .Tab, "27;1;9~ bare Tab")
}

@(test)
test_peek_is_shift_tab_sequences :: proc(t: ^testing.T) {
	// classic CSI Z
	z := []u8{0x1b, '[', 'Z'}
	testing.expect(t, peek_is_shift_tab(z))

	// CSI 1;2 Z
	z2 := []u8{0x1b, '[', '1', ';', '2', 'Z'}
	testing.expect(t, peek_is_shift_tab(z2))

	// Kitty CSI-u Shift+Tab
	u := []u8{0x1b, '[', '9', ';', '2', 'u'}
	testing.expect(t, peek_is_shift_tab(u), "CSI-u 9;2u must count as Shift+Tab")

	// bare Tab CSI-u — not Shift+Tab
	u_tab := []u8{0x1b, '[', '9', 'u'}
	testing.expect(t, !peek_is_shift_tab(u_tab))

	// modifyOtherKeys
	mok := []u8{0x1b, '[', '2', '7', ';', '2', ';', '9', '~'}
	testing.expect(t, peek_is_shift_tab(mok), "27;2;9~ must count as Shift+Tab")
}
