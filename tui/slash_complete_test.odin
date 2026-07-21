// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tui

import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_slash_token_prefix :: proc(t: ^testing.T) {
	p, ok := slash_token_prefix("/he", 3)
	testing.expect(t, ok && p == "/he")
	_, ok2 := slash_token_prefix("hello", 5)
	testing.expect(t, !ok2)
	_, ok3 := slash_token_prefix("/diff full", 10)
	testing.expect(t, !ok3, "space ends token")
	// multiline: only last line
	p4, ok4 := slash_token_prefix("note\n/mod", 9)
	testing.expect(t, ok4 && p4 == "/mod", p4)
	p5, ok5 := slash_token_prefix("/", 1)
	testing.expect(t, ok5 && p5 == "/")
}

@(test)
test_collect_slash_matches_and_lcp :: proc(t: ^testing.T) {
	ms := make([dynamic]string, 0, 8, context.temp_allocator)
	collect_slash_matches("/comp", &ms)
	testing.expect(t, len(ms) >= 2, "compact + compact-mode")
	lcp := common_slash_prefix(ms[:])
	testing.expect(t, strings.has_prefix(lcp, "/comp"))
	clear(&ms)
	collect_slash_matches("/diff", &ms)
	testing.expect(t, len(ms) == 1)
	testing.expect(t, ms[0] == "/diff")
	clear(&ms)
	collect_slash_matches("/zzz", &ms)
	testing.expect(t, len(ms) == 0)
}

@(test)
test_collect_slash_bare_primaries_only :: proc(t: ^testing.T) {
	ms := make([dynamic]string, 0, 64, context.temp_allocator)
	collect_slash_matches("/", &ms)
	testing.expect(t, len(ms) > 10)
	// Grok-facing primaries present
	has_quit, has_settings, has_mcps, has_context := false, false, false, false
	// Pure aliases must not appear on bare /
	has_exit_alias, has_config_alias, has_q, has_perm := false, false, false, false
	for m in ms {
		if m == "/quit" do has_quit = true
		if m == "/settings" do has_settings = true
		if m == "/mcps" do has_mcps = true
		if m == "/context" do has_context = true
		if m == "/exit" do has_exit_alias = true
		if m == "/config" do has_config_alias = true
		if m == "/q" do has_q = true
		if m == "/perm" do has_perm = true
	}
	testing.expect(t, has_quit, "primary /quit")
	testing.expect(t, has_settings, "primary /settings")
	testing.expect(t, has_mcps, "primary /mcps")
	testing.expect(t, has_context, "primary /context")
	testing.expect(t, !has_exit_alias, "bare / must not list /exit alias")
	testing.expect(t, !has_config_alias, "bare / must not list /config alias")
	testing.expect(t, !has_q, "bare / must not list /q")
	testing.expect(t, !has_perm, "bare / must not list /perm")
}

@(test)
test_collect_slash_no_redundant_session_rows :: proc(t: ^testing.T) {
	// /session and /sessions are aliases, not separate bare-/ rows
	ms := make([dynamic]string, 0, 64, context.temp_allocator)
	collect_slash_matches("/", &ms)
	has_session, has_sessions, has_info, has_resume := false, false, false, false
	for m in ms {
		if m == "/session" do has_session = true
		if m == "/sessions" do has_sessions = true
		if m == "/session-info" do has_info = true
		if m == "/resume" do has_resume = true
	}
	testing.expect(t, has_info, "primary /session-info")
	testing.expect(t, has_resume, "primary /resume")
	testing.expect(t, !has_session, "alias /session must not appear on bare /")
	testing.expect(t, !has_sessions, "alias /sessions must not appear on bare /")
	// Grok: /clear is alias of /new — not a separate menu row
	has_clear := false
	for m in ms {
		if m == "/clear" do has_clear = true
	}
	testing.expect(t, !has_clear, "alias /clear must not appear on bare /")
	// typing "/session" must not list both /session and /session-info
	clear(&ms)
	collect_slash_matches("/session", &ms)
	n_sessionish := 0
	for m in ms {
		if m == "/session" || m == "/session-info" {
			n_sessionish += 1
		}
	}
	testing.expect(t, n_sessionish == 1, "one row for session command family")
	// primary preferred when it also matches the prefix
	found_primary := false
	for m in ms {
		if m == "/session-info" {
			found_primary = true
		}
	}
	testing.expect(t, found_primary, "prefer primary /session-info over alias /session")
}

@(test)
test_collect_slash_alias_only_prefix_one_row :: proc(t: ^testing.T) {
	// /exit is only an alias of /quit — one row, not both
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	collect_slash_matches("/ex", &ms)
	n := 0
	for m in ms {
		if m == "/exit" || m == "/quit" {
			n += 1
		}
	}
	testing.expect(t, n == 1, "alias-only prefix yields one command row")
	// should surface the matching alias for insert fidelity
	has_exit := false
	for m in ms {
		if m == "/exit" {
			has_exit = true
		}
	}
	testing.expect(t, has_exit, "/ex → /exit alias row")
}

@(test)
test_collect_slash_bare_grok_order :: proc(t: ^testing.T) {
	// Grok builtin_commands() starts: quit, help, … new, fork, compact, copy, find, …
	ms := make([dynamic]string, 0, 64, context.temp_allocator)
	collect_slash_matches("/", &ms)
	testing.expect(t, len(ms) >= 10)
	testing.expect(t, ms[0] == "/quit", ms[0])
	testing.expect(t, ms[1] == "/help", ms[1])
	// find positions of a few shared cmds and assert relative order
	idx :: proc(list: []string, name: string) -> int {
		for i in 0 ..< len(list) {
			if list[i] == name {
				return i
			}
		}
		return -1
	}
	iq := idx(ms[:], "/quit")
	ih := idx(ms[:], "/help")
	in_ := idx(ms[:], "/new")
	ifork := idx(ms[:], "/fork")
	icompact := idx(ms[:], "/compact")
	icopy := idx(ms[:], "/copy")
	ifind := idx(ms[:], "/find")
	imodel := idx(ms[:], "/model")
	imcps := idx(ms[:], "/mcps")
	isettings := idx(ms[:], "/settings")
	testing.expect(t, iq >= 0 && ih > iq)
	testing.expect(t, in_ > ih)
	testing.expect(t, ifork > in_)
	testing.expect(t, icompact > ifork)
	testing.expect(t, icopy > icompact)
	testing.expect(t, ifind > icopy)
	testing.expect(t, imodel > ifind)
	testing.expect(t, imcps > imodel)
	testing.expect(t, isettings > imcps)
}

@(test)
test_collect_slash_match_rows_have_desc :: proc(t: ^testing.T) {
	rows := make([dynamic]core.Slash_Match, 0, 16, context.temp_allocator)
	collect_slash_match_rows("/quit", &rows)
	testing.expect(t, len(rows) >= 1)
	found := false
	for r in rows {
		if r.name == "/quit" {
			found = true
			testing.expect(t, r.desc != "", "Grok-style description required")
			testing.expect(
				t,
				strings.contains(r.desc, "Quit") || strings.contains(r.desc, "quit"),
				r.desc,
			)
		}
	}
	testing.expect(t, found)
	// bare / rows also carry descriptions
	clear(&rows)
	collect_slash_match_rows("/", &rows)
	testing.expect(t, len(rows) > 5)
	for r in rows[:min(5, len(rows))] {
		testing.expectf(t, r.desc != "", "%s missing desc", r.name)
	}
}

@(test)
test_collect_slash_alias_prefix :: proc(t: ^testing.T) {
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	collect_slash_matches("/ex", &ms)
	found_exit := false
	for m in ms {
		if m == "/exit" do found_exit = true
	}
	testing.expect(t, found_exit, "/ex should match alias /exit")
	clear(&ms)
	collect_slash_matches("/mcp", &ms)
	// /mcps primary + /mcp alias
	has_mcps, has_mcp := false, false
	for m in ms {
		if m == "/mcps" do has_mcps = true
		if m == "/mcp" do has_mcp = true
	}
	testing.expect(t, has_mcps || has_mcp)
}

@(test)
test_try_slash_tab_complete_unique :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	input_set_text(&st, "/dif")
	st.cursor = len(st.input)
	testing.expect(t, try_slash_tab_complete(&st))
	got := input_text(&st)
	testing.expectf(t, strings.has_prefix(got, "/diff"), "got %q", got)
	// trailing space for unique
	testing.expect(t, strings.has_suffix(got, " ") || got == "/diff ")
}

@(test)
test_try_slash_tab_complete_no_slash :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	input_set_text(&st, "hello")
	st.cursor = len(st.input)
	testing.expect(t, !try_slash_tab_complete(&st))
}

@(test)
test_slash_menu_matches_live :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.focus = .Prompt
	input_set_text(&st, "/he")
	st.cursor = len(st.input)
	ms := make([dynamic]string, 0, 16, context.temp_allocator)
	testing.expect(t, slash_menu_matches(&st, &ms))
	testing.expect(t, len(ms) >= 1)
	// help should be in list
	found := false
	for m in ms {
		if m == "/help" {
			found = true
			break
		}
	}
	testing.expect(t, found)
	testing.expect(t, slash_menu_height(&st, 40, 1) >= 2)
}

@(test)
test_slash_menu_navigate_and_accept :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.focus = .Prompt
	input_set_text(&st, "/")
	st.cursor = 1
	testing.expect(t, slash_menu_navigate(&st, 1))
	testing.expect(t, st.slash_menu_sel >= 0)
	testing.expect(t, slash_menu_accept(&st))
	got := input_text(&st)
	testing.expect(t, strings.has_prefix(got, "/"))
	testing.expect(t, strings.contains(got, " ") || len(got) > 1)
}

@(test)
test_slash_menu_dismiss_clears_token :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.focus = .Prompt
	input_set_text(&st, "note\n/hel")
	st.cursor = len(st.input)
	testing.expect(t, slash_menu_dismiss(&st))
	got := input_text(&st)
	testing.expect(t, got == "note\n", got)
	// no longer a slash token
	ms := make([dynamic]string, 0, 4, context.temp_allocator)
	testing.expect(t, !slash_menu_matches(&st, &ms))
}
