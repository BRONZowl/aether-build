// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:testing"

@(test)
test_slash_table_dispatches_docs_and_aliases :: proc(t: ^testing.T) {
	testing.expect(t, slash_table_has("/docs"))
	testing.expect(t, slash_table_has("/howto"))
	testing.expect(t, slash_table_has("/guides"))
	testing.expect(t, slash_table_has("/permissions"))
	testing.expect(t, slash_table_has("/perm"))
	// Session lifecycle stays out of the table
	testing.expect(t, !slash_table_has("/quit"))
	testing.expect(t, !slash_table_has("/new"))
}

@(test)
test_slash_table_docs_runs :: proc(t: ^testing.T) {
	act, ok := slash_table_dispatch("/docs", Slash_Ctx{arg = "help", out = nil})
	testing.expect(t, ok)
	testing.expect(t, act == .Continue)
	act, ok = slash_table_dispatch("/howto", Slash_Ctx{arg = "", out = nil})
	testing.expect(t, ok)
	testing.expect(t, act == .Continue)
}

@(test)
test_slash_table_unknown_falls_through :: proc(t: ^testing.T) {
	_, ok := slash_table_dispatch("/not-a-real-command-xyz", Slash_Ctx{})
	testing.expect(t, !ok)
}
