package tui

import "core:strings"
import "core:testing"

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
