// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:testing"

@(test)
test_bracketed_paste_csi_params :: proc(t: ^testing.T) {
	testing.expect(t, is_bracketed_paste_start("200"))
	testing.expect(t, !is_bracketed_paste_start("201"))
	testing.expect(t, !is_bracketed_paste_start("5"))
	testing.expect(t, !is_bracketed_paste_start("200;1"))
	testing.expect(t, is_bracketed_paste_end("201"))
	testing.expect(t, !is_bracketed_paste_end("200"))
	testing.expect(t, !is_bracketed_paste_end(""))
}

@(test)
test_decode_csi_tilde_pg_and_paste_end :: proc(t: ^testing.T) {
	// non-paste tilde codes still work
	k := decode_csi_tilde("5")
	testing.expect(t, k.kind == .PgUp)
	k2 := decode_csi_tilde("6")
	testing.expect(t, k2.kind == .PgDn)
	// stray 201~ → Unknown (no payload)
	k3 := decode_csi_tilde("201")
	testing.expect(t, k3.kind == .Unknown)
}
