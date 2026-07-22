// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:testing"
import "aether:core"

@(test)
test_slash_table_dispatches_docs_and_aliases :: proc(t: ^testing.T) {
	testing.expect(t, slash_table_has("/docs"))
	testing.expect(t, slash_table_has("/howto"))
	testing.expect(t, slash_table_has("/guides"))
	testing.expect(t, slash_table_has("/permissions"))
	testing.expect(t, slash_table_has("/perm"))
	testing.expect(t, slash_table_has("/help"))
	testing.expect(t, slash_table_has("/?"))
	testing.expect(t, slash_table_has("/compact"))
	testing.expect(t, slash_table_has("/vim-mode"))
	testing.expect(t, slash_table_has("/todos"))
	// Session lifecycle stays out of the table
	testing.expect(t, !slash_table_has("/quit"))
	testing.expect(t, !slash_table_has("/new"))
	testing.expect(t, !slash_table_has("/model"))
	testing.expect(t, !slash_table_has("/resume"))
}

@(test)
test_slash_table_docs_runs :: proc(t: ^testing.T) {
	act, ok := slash_table_dispatch("/docs", Slash_Ctx{arg = "help", out = nil})
	testing.expect(t, ok)
	testing.expect(t, act == .Continue)
	act, ok = slash_table_dispatch("/howto", Slash_Ctx{arg = "", out = nil})
	testing.expect(t, ok)
	testing.expect(t, act == .Continue)
	act, ok = slash_table_dispatch("/help", Slash_Ctx{arg = "", out = nil})
	testing.expect(t, ok)
	testing.expect(t, act == .Continue)
	act, ok = slash_table_dispatch("/effort", Slash_Ctx{arg = "status", out = nil})
	testing.expect(t, ok)
	testing.expect(t, act == .Continue)
}

@(test)
test_slash_table_unknown_falls_through :: proc(t: ^testing.T) {
	_, ok := slash_table_dispatch("/not-a-real-command-xyz", Slash_Ctx{})
	testing.expect(t, !ok)
}

// P3.2: every catalog primary + alias is either table-dispatched or known lifecycle.
// Lifecycle specials stay in run_slash switch by design.
SLASH_LIFECYCLE_SPECIALS := [?]string {
	"/quit", "/exit", "/q",
	"/new", "/clear", "/home", "/welcome",
	"/always-approve", "/yolo", "/auto",
	"/model", "/m",
	"/copy",
	"/history",
	"/theme", "/t",
	"/plan",
	"/login",
	"/cd",
	"/skills", "/skill",
	"/session-info", "/session",
	"/resume", "/sessions",
	"/rename", "/title",
	"/fork",
	"/export", "/import",
	"/undo-file", "/rewind-file",
	"/rewind",
	"/save", "/load",
}

slash_is_lifecycle_special :: proc(name: string) -> bool {
	for s in SLASH_LIFECYCLE_SPECIALS {
		if s == name {
			return true
		}
	}
	return false
}

@(test)
test_slash_catalog_names_covered :: proc(t: ^testing.T) {
	// Every catalog primary and alias must be table-dispatched or lifecycle special.
	for e in core.SLASH_CATALOG {
		if e.primary != "" {
			ok := slash_table_has(e.primary) || slash_is_lifecycle_special(e.primary)
			testing.expectf(t, ok, "catalog primary %s not in table or lifecycle list", e.primary)
		}
		for a in e.aliases {
			ok := slash_table_has(a) || slash_is_lifecycle_special(a)
			testing.expectf(t, ok, "catalog alias %s not in table or lifecycle list", a)
		}
	}
}
